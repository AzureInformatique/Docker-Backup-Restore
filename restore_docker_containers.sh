#!/usr/bin/env bash
#
# Script de restauration de conteneurs Docker depuis les sauvegardes créées par backup_docker_containers.sh
#
# Usage : ./restore_docker_containers.sh <date_str> <container_name>
# Exemple : ./restore_docker_containers.sh 20240101_153000 myapp_container
#
# Prérequis :
# - jq installé (sudo apt-get install jq par exemple)
# - Utiliser sudo ou être root si nécessaire
# - Avoir accès au répertoire ./backups/ contenant les sauvegardes
#
# Hypothèses :
# - Les sauvegardes suivent la structure : ./backups/YYYYMMDD_HHMMSS_containerName/
# - Ce répertoire contient un fichier *_inspect.json, un *_image.tar, et un répertoire volumes/

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <date_str> <container_name>"
    echo "Exemple: $0 20240101_153000 myapp_container"
    exit 1
fi

DATE_STR="$1"
CONTAINER="$2"
BACKUP_ROOT="./backups"
BACKUP_DIR="${BACKUP_ROOT}/${DATE_STR}_${CONTAINER}"

if [ ! -d "${BACKUP_DIR}" ]; then
    echo "Le répertoire de sauvegarde ${BACKUP_DIR} n'existe pas."
    exit 1
fi

INSPECT_FILE=$(find "${BACKUP_DIR}" -name '*_inspect.json' | head -n 1)
IMAGE_FILE=$(find "${BACKUP_DIR}" -name '*_image.tar' | head -n 1)
VOLUMES_DIR="${BACKUP_DIR}/volumes"

if [ -z "${INSPECT_FILE}" ] || [ ! -f "${INSPECT_FILE}" ]; then
    echo "Fichier *_inspect.json introuvable dans ${BACKUP_DIR}."
    exit 1
fi

if [ -z "${IMAGE_FILE}" ] || [ ! -f "${IMAGE_FILE}" ]; then
    echo "Fichier *_image.tar introuvable dans ${BACKUP_DIR}."
    exit 1
fi

# Le nom du conteneur dans l'inspect
INSPECT_CONTAINER_NAME=$(jq -r '.[0].Name' "${INSPECT_FILE}")
INSPECT_CONTAINER_NAME="${INSPECT_CONTAINER_NAME#/}" # Retirer le / au début du nom si présent

if [ "${INSPECT_CONTAINER_NAME}" != "${CONTAINER}" ]; then
    echo "Avertissement : Le nom du conteneur dans l'inspect (${INSPECT_CONTAINER_NAME}) ne correspond pas à celui demandé (${CONTAINER})."
    echo "On continue avec ${INSPECT_CONTAINER_NAME}, mais vérifiez vos sauvegardes."
fi

CONTAINER_NAME="${INSPECT_CONTAINER_NAME}"
IMAGE_ID=$(jq -r '.[0].Image' "${INSPECT_FILE}")

echo "==> Restauration du conteneur : ${CONTAINER_NAME}"
echo "    Répertoire de sauvegarde : ${BACKUP_DIR}"

# 1. Restauration de l'image
echo "==> Restauration de l'image depuis ${IMAGE_FILE}"
LOAD_OUTPUT=$(docker load -i "${IMAGE_FILE}")
NEW_IMAGE_ID=$(echo "${LOAD_OUTPUT}" | awk -F': ' '/Loaded image ID/ {print $2}')
if [ -z "${NEW_IMAGE_ID}" ]; then
    NEW_IMAGE_ID=$(echo "${LOAD_OUTPUT}" | awk -F': ' '/Loaded image/ {print $2}')
fi
if [ -z "${NEW_IMAGE_ID}" ]; then
    echo "Impossible de déterminer l'ID ou le nom de l'image chargée."
    exit 1
fi

echo "    Image restaurée : ${NEW_IMAGE_ID}"

RESTORED_IMAGE_NAME="restored_image:${CONTAINER_NAME}"
docker tag "${NEW_IMAGE_ID}" "${RESTORED_IMAGE_NAME}"
echo "    Image retaggée en : ${RESTORED_IMAGE_NAME}"

# 2. Restauration des volumes
echo "==> Restauration des volumes"
MOUNTS=$(jq -r '.[0].Mounts[] | "\(.Type)::\(.Name)::\(.Source)::\(.Destination)"' "${INSPECT_FILE}" || true)

if [ -d "${VOLUMES_DIR}" ]; then
    for MOUNT_INFO in $MOUNTS; do
        TYPE=$(echo "$MOUNT_INFO" | awk -F'::' '{print $1}')
        NAME=$(echo "$MOUNT_INFO" | awk -F'::' '{print $2}')
        SOURCE=$(echo "$MOUNT_INFO" | awk -F'::' '{print $3}')
        DEST=$(echo "$MOUNT_INFO" | awk -F'::' '{print $4}')

        if [ "$TYPE" = "volume" ] && [ -n "$NAME" ]; then
            ARCHIVE="${VOLUMES_DIR}/${NAME}.tar.gz"
            if [ -f "${ARCHIVE}" ]; then
                echo "    -> Restauration du volume nommé : ${NAME}"
                docker volume create "${NAME}" > /dev/null
                VOLUME_PATH="/var/lib/docker/volumes/${NAME}/_data"
                if [ -d "$VOLUME_PATH" ]; then
                    tar -xzf "${ARCHIVE}" -C "${VOLUME_PATH}"
                else
                    echo "    -> Chemin du volume introuvable: ${VOLUME_PATH}"
                fi
            else
                echo "    -> Aucune archive trouvée pour le volume ${NAME}"
            fi
        elif [ "$TYPE" = "bind" ] && [ -n "$SOURCE" ]; then
            BASENAME=$(basename "$SOURCE")
            ARCHIVE="${VOLUMES_DIR}/${BASENAME}.tar.gz"
            if [ -f "${ARCHIVE}" ]; then
                echo "    -> Restauration du bind mount : ${SOURCE}"
                mkdir -p "$(dirname "$SOURCE")"
                tar -xzf "${ARCHIVE}" -C "$(dirname "$SOURCE")"
            else
                echo "    -> Aucune archive trouvée pour le bind mount ${SOURCE}"
            fi
        fi
    done
else
    echo "    Aucun répertoire volumes/ trouvé. Pas de volumes à restaurer ?"
fi

# 3. Recréation du conteneur
echo "==> Recréation du conteneur ${CONTAINER_NAME}"

HOSTNAME=$(jq -r '.[0].Config.Hostname' "${INSPECT_FILE}")
ENV_VARS=$(jq -r '.[0].Config.Env[]?' "${INSPECT_FILE}")
CMD=$(jq -r '.[0].Config.Cmd | join(" ")' "${INSPECT_FILE}")
WORKING_DIR=$(jq -r '.[0].Config.WorkingDir' "${INSPECT_FILE}")
USER=$(jq -r '.[0].Config.User' "${INSPECT_FILE}")
PORTS=$(jq -r '.[0].Config.ExposedPorts | keys[]?' "${INSPECT_FILE}" || true)
MOUNTS_ARRAY=$(jq -r '.[0].Mounts[] | "\(.Type)::\(.Source)::\(.Destination)"' "${INSPECT_FILE}" || true)

DOCKER_RUN_CMD="docker create --name ${CONTAINER_NAME}"

if [ -n "${HOSTNAME}" ] && [ "${HOSTNAME}" != "null" ]; then
    DOCKER_RUN_CMD+=" --hostname ${HOSTNAME}"
fi

for VAR in ${ENV_VARS}; do
    DOCKER_RUN_CMD+=" -e ${VAR}"
done

# Les ports exposés dans Config.ExposedPorts ne donnent pas le mapping hôte, 
# juste le port interne. Pour le mapping, il faudrait aller dans HostConfig.PortBindings.
# Ici on se contente d'exposer les ports internes, sans binding explicite.
for PORT in ${PORTS}; do
    DOCKER_RUN_CMD+=" -p ${PORT%/*}"
done

# Restaurer les montages
for M in ${MOUNTS_ARRAY}; do
    M_TYPE=$(echo "$M" | awk -F'::' '{print $1}')
    M_SOURCE=$(echo "$M" | awk -F'::' '{print $2}')
    M_DEST=$(echo "$M" | awk -F'::' '{print $3}')
    if [ "$M_TYPE" = "volume" ]; then
        DOCKER_RUN_CMD+=" -v ${M_SOURCE}:${M_DEST}"
    elif [ "$M_TYPE" = "bind" ]; then
        DOCKER_RUN_CMD+=" -v ${M_SOURCE}:${M_DEST}"
    fi
done

if [ -n "${WORKING_DIR}" ] && [ "${WORKING_DIR}" != "null" ]; then
    DOCKER_RUN_CMD+=" -w ${WORKING_DIR}"
fi
if [ -n "${USER}" ] && [ "${USER}" != "null" ] && [ "${USER}" != "" ]; then
    DOCKER_RUN_CMD+=" -u ${USER}"
fi

DOCKER_RUN_CMD+=" ${RESTORED_IMAGE_NAME}"
if [ -n "${CMD}" ] && [ "${CMD}" != "null" ]; then
    DOCKER_RUN_CMD+=" ${CMD}"
fi

echo "    Commande de création : ${DOCKER_RUN_CMD}"
eval "${DOCKER_RUN_CMD}"

echo "==> Conteneur ${CONTAINER_NAME} recréé. Démarrez-le avec :"
echo "    docker start ${CONTAINER_NAME}"
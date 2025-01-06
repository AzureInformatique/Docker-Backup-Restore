#!/usr/bin/env bash
#
# Script de sauvegarde complète de conteneurs Docker : images, configuration, volumes.
# Usage: ./backup_docker_containers.sh container1 [container2 ...]
# Exemple: ./backup_docker_containers.sh myapp_container db_container
#
# Ce script crée une arborescence de sauvegarde comme suit:
# backups/
#   YYYYMMDD_HHMMSS_containerName/
#     container_inspect.json
#     container_image.tar
#     volumes/
#       volumeName_or_bindMountName.tar.gz
#
# Prérequis : accès root ou sudo, docker, tar

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 container_name [container_name2 ...]"
    exit 1
fi

DATE_STR=$(date +"%Y%m%d_%H%M%S")

# Répertoire racine de sauvegarde
BACKUP_ROOT="./backups"

mkdir -p "${BACKUP_ROOT}"

for CONTAINER in "$@"; do
    echo "==> Sauvegarde du conteneur: $CONTAINER"
    
    # Vérification de l'existence du conteneur
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        echo "Le conteneur ${CONTAINER} n'existe pas."
        continue
    fi
    
    # Création d'un répertoire de sauvegarde spécifique au conteneur
    BACKUP_DIR="${BACKUP_ROOT}/${DATE_STR}_${CONTAINER}"
    mkdir -p "${BACKUP_DIR}"

    # Sauvegarde de la configuration du conteneur
    echo "  -> Sauvegarde de la configuration (inspect)"
    docker inspect "${CONTAINER}" > "${BACKUP_DIR}/${CONTAINER}_inspect.json"

    # Sauvegarde de l'image du conteneur (on commit l'état actuel, puis on save)
    echo "  -> Sauvegarde de l'image"
    TMP_IMAGE_NAME="backup_tmp_${CONTAINER}_${DATE_STR}"
    docker commit "${CONTAINER}" "${TMP_IMAGE_NAME}" > /dev/null
    docker save -o "${BACKUP_DIR}/${CONTAINER}_image.tar" "${TMP_IMAGE_NAME}" 
    docker rmi "${TMP_IMAGE_NAME}" > /dev/null
    
    # Sauvegarde des volumes
    echo "  -> Recherche et sauvegarde des volumes"
    VOLUME_DIR="${BACKUP_DIR}/volumes"
    mkdir -p "${VOLUME_DIR}"

    # Récupération des informations du conteneur
    MOUNTS=$(docker inspect -f '{{range .Mounts}}{{printf "%s::%s::%s\n" .Type .Name .Source}}{{end}}' "${CONTAINER}")

    # Pour chaque montage, on détermine s'il s'agit d'un volume nommé ou d'un bind mount
    # Format: Type::Name::Source
    # Type: volume ou bind
    # Name: nom du volume Docker (si Type=volume) ou "" si Type=bind
    # Source: chemin sur l'hôte
    
    IFS=$'\n'
    for MOUNT_INFO in $MOUNTS; do
        TYPE=$(echo "$MOUNT_INFO" | awk -F'::' '{print $1}')
        NAME=$(echo "$MOUNT_INFO" | awk -F'::' '{print $2}')
        SOURCE=$(echo "$MOUNT_INFO" | awk -F'::' '{print $3}')
        
        if [ "$TYPE" = "volume" ]; then
            # Volume nommé Docker
            # Les données se trouvent normalement dans /var/lib/docker/volumes/<Name>/_data
            # On va archiver le contenu du répertoire _data
            VOLUME_PATH="/var/lib/docker/volumes/${NAME}/_data"
            if [ -d "$VOLUME_PATH" ]; then
                echo "    -> Sauvegarde du volume nommé: $NAME"
                tar -czf "${VOLUME_DIR}/${NAME}.tar.gz" -C "${VOLUME_PATH}" .
            else
                echo "    -> Volume nommé $NAME introuvable sur le host. Vérifiez les chemins."
            fi
        elif [ "$TYPE" = "bind" ]; then
            # Bind mount (un répertoire du host)
            # On va archiver ce répertoire directement
            BASENAME=$(basename "$SOURCE")
            echo "    -> Sauvegarde du bind mount: $SOURCE"
            if [ -d "$SOURCE" ]; then
                tar -czf "${VOLUME_DIR}/${BASENAME}.tar.gz" -C "$(dirname "$SOURCE")" "$BASENAME"
            else
                echo "    -> Le répertoire bind mounté $SOURCE n'existe pas ou n'est pas accessible."
            fi
        fi
    done
    unset IFS

    echo "==> Sauvegarde terminée pour $CONTAINER dans $BACKUP_DIR"
done

echo "Toutes les sauvegardes sont terminées."
###############################################################################
#                              SUMMARY                                        #
###############################################################################

show_summary() {

    echo
    echo "============================================================"
    echo " INSTALLATION TERMINÉE"
    echo "============================================================"
    echo

    echo "Node:"
    echo "  ${NODE_NAME}"
    echo

    echo "Réseau:"
    echo "  LAN       : ${LAN_IP}"
    echo "  Private   : ${PRIVATE_GW}/24"
    echo

    echo "DATA:"
    echo "  Disk      : ${DATA_DISK}"
    echo "  Mount     : ${DATA_MOUNT}"
    echo "  Shared    : ${SHARED_DIR}"
    echo "  Proxmox   : ${PROXMOX_DATA_DIR}"
    echo

    if [[ "$ENABLE_FILES" == "true" ]]; then

        echo "FILES:"
        echo "  VMID      : ${FILES_ID}"
        echo "  IP        : ${FILES_IP}"
        echo "  VirtioFS  : ${FILES_MOUNT}"
        echo "  Samba     : \\\\10.10.10.104\\SHARED (direct, si la route vers 10.10.10.0/24 est configurée sur le LAN)"
        echo "  Samba LAN : \\\\${LAN_IP}\\SHARED (via redirection de port, fonctionne sans route particulière)"
        echo "  Webmin    : https://10.10.10.104:10000"
        echo "  Webmin LAN: https://${LAN_IP}:10000 (via redirection de port)"
        echo
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]]; then

        echo "DOCKER:"
        echo "  VMID      : ${DOCKER_ID}"
        echo "  IP        : ${DOCKER_IP}"
        echo "  Partage   : ${DOCKER_SHARED_MOUNT} (VirtioFS ; accès contrôlé par GID ${SHARED_GID})"
        echo

        if [[ "$ENABLE_NEXTCLOUD" == "true" ]]; then

            echo "  Nextcloud:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${NEXTCLOUD_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${NEXTCLOUD_HTTP_PORT}"
            echo "    Via SWAG  : https://cloud.${DOMAIN}"
            echo "    Admin     : ${NEXTCLOUD_ADMIN_USER} / ${NEXTCLOUD_ADMIN_PASSWORD}"
            echo "    À faire   : configurer External Storage (app 'files_external') - commandes occ documentées dans create_docker_cloud_init()"
            echo
        fi

        if [[ "$ENABLE_SYNCIN" == "true" ]]; then

            echo "  Sync-in:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${SYNCIN_HTTP_PORT}"
            echo "    Via SWAG  : https://sync.${DOMAIN}"
            echo "    Admin     : ${SYNCIN_ADMIN_LOGIN} / ${SYNCIN_ADMIN_PASSWORD}"
            echo "    ATTENTION : vérifie /opt/apps/syncin/environment.yaml contre la doc officielle si le conteneur ne démarre pas"
            echo
        fi

        if [[ "$ENABLE_IMMICH" == "true" ]]; then

            echo "  Immich:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${IMMICH_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${IMMICH_HTTP_PORT}"
            echo "    Via SWAG  : https://photos.${DOMAIN}"
            echo "    À faire   : créer le compte admin au premier accès, puis ajouter"
            echo "                /mnt/external/photo comme External Library"
            echo
        fi

        if [[ "$ENABLE_HOMEASSISTANT" == "true" ]]; then
            echo "  Home Assistant:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${HOMEASSISTANT_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${HOMEASSISTANT_HTTP_PORT}"
            echo "    Via SWAG  : https://home.${DOMAIN}"
            echo "    SHARED    : ${DOCKER_SHARED_MOUNT} (lecture seule)"
            echo
        fi

        if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
            echo "  Jellyfin:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${JELLYFIN_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${JELLYFIN_HTTP_PORT}"
            echo "    Via SWAG  : https://media.${DOMAIN}"
            echo "    Movies    : ${DOCKER_SHARED_MOUNT}/Movies (lecture seule)"
            echo "    Music     : ${DOCKER_SHARED_MOUNT}/Music (lecture seule)"
            echo "    Photo     : ${DOCKER_SHARED_MOUNT}/Photo (lecture seule)"
            echo
        fi
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then

        echo "SWAG:"
        echo "  CTID      : ${SWAG_ID}"
        echo "  IP        : ${SWAG_IP}"
        echo "  Domain    : ${DOMAIN}"
        echo "  Cloud     : cloud.${DOMAIN}"
        echo "  Sync      : sync.${DOMAIN}"
        echo
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]]; then

        echo "XMRig:"
        echo "  CTID      : ${XMRIG_ID}"
        echo "  IP        : ${XMRIG_IP}"
        echo "  Version   : ${XMRIG_VERSION}"
        echo "  Pool      : ${XMRIG_POOL}"
        echo "  Stop      : ${XMRIG_STOP_THRESHOLD}%"
        echo "  Resume    : ${XMRIG_RESUME_THRESHOLD}%"
        echo "  Delay     : ${XMRIG_RESUME_DELAY}s"
        echo
    fi

    echo "Log:"
    echo "  ${LOG_FILE}"
    echo
}


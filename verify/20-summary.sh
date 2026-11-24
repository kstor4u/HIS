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
            echo "    Via SWAG  : $(sd_fqdns NEXTCLOUD_SUBDOMAIN | sed 's#\([^ ]*\)#https://\1#g')"
            echo "    Admin     : ${NEXTCLOUD_ADMIN_USER} / ${NEXTCLOUD_ADMIN_PASSWORD}"
            echo "    À faire   : configurer External Storage (app 'files_external') - commandes occ documentées dans create_docker_cloud_init()"
            [[ "${NEXTCLOUD_PHOTOS:-false}" == "true" ]] && echo "    Photos    : https://${NEXTCLOUD_SUBDOMAIN%% *}.${DOMAIN}/apps/memories/ (état : ./install.sh --run nextcloud_photos_status)"
            echo "    PHP       : contrôle PHP2Shell : ./install.sh --run php_cve_check"
            echo
        fi

        if [[ "$ENABLE_COLLABORA" == "true" ]]; then

            echo "  Collabora Online (édition de documents dans Nextcloud):"
            echo "    Via SWAG  : https://${COLLABORA_SUBDOMAIN}.${DOMAIN}  (enregistrement DNS A requis)"
            echo "    Local     : http://${DOCKER_IP%%/*}:${COLLABORA_HTTP_PORT}"
            echo
        fi

        if [[ "$ENABLE_ONLYOFFICE" == "true" ]]; then

            echo "  OnlyOffice Document Server (édition de documents dans Nextcloud):"
            echo "    Via SWAG  : https://${ONLYOFFICE_SUBDOMAIN}.${DOMAIN}  (enregistrement DNS A requis)"
            echo "    Local     : http://${DOCKER_IP%%/*}:${ONLYOFFICE_HTTP_PORT}"
            echo "    JWT       : ${ONLYOFFICE_JWT_SECRET}"
            echo
        fi

        if [[ "$ENABLE_COLLABORA" == "true" && "$ENABLE_ONLYOFFICE" == "true" ]]; then

            echo "  Choisir l'éditeur dans Nextcloud : ./install.sh --run nextcloud_office_use collabora|onlyoffice|both"
            echo
        fi

        if [[ "$ENABLE_SYNCIN" == "true" ]]; then

            echo "  Sync-in:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${SYNCIN_HTTP_PORT}"
            echo "    Via SWAG  : $(sd_fqdns SYNCIN_SUBDOMAIN | sed 's#\([^ ]*\)#https://\1#g')"
            echo "    Admin     : ${SYNCIN_ADMIN_LOGIN} / ${SYNCIN_ADMIN_PASSWORD}"
            echo "    SHARED    : Admin > Spaces > ajouter une racine externe ${DOCKER_SHARED_MOUNT}/Users (idem Photo, Movies, Music)"
            echo
        fi

        if [[ "$ENABLE_IMMICH" == "true" ]]; then

            echo "  Immich:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${IMMICH_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${IMMICH_HTTP_PORT}"
            echo "    Via SWAG  : $(sd_fqdns IMMICH_SUBDOMAIN | sed 's#\([^ ]*\)#https://\1#g')"
            echo "    À faire   : créer le compte admin au premier accès, puis ajouter"
            echo "                /mnt/external/photo comme External Library"
            echo
        fi

        if [[ "$ENABLE_HOMEASSISTANT" == "true" ]]; then
            echo "  Home Assistant:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${HOMEASSISTANT_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${HOMEASSISTANT_HTTP_PORT}"
            echo "    SHARED    : ${DOCKER_SHARED_MOUNT} (lecture seule)"
            echo
        fi

        if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
            echo "  Jellyfin:"
            echo "    Local     : http://${DOCKER_IP%%/*}:${JELLYFIN_HTTP_PORT}"
            echo "    LAN       : http://${LAN_IP}:${JELLYFIN_HTTP_PORT}"
            echo "    Via SWAG  : $(sd_fqdns JELLYFIN_SUBDOMAIN | sed 's#\([^ ]*\)#https://\1#g')"
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
        echo "  Cloud     : $(sd_fqdns NEXTCLOUD_SUBDOMAIN)"
        echo "  Sync      : $(sd_fqdns SYNCIN_SUBDOMAIN)"
        echo "  Photos    : $(sd_fqdns IMMICH_SUBDOMAIN)"
        if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
            echo "  Media     : $(sd_fqdns JELLYFIN_SUBDOMAIN)"
        fi
        echo
    fi

    ssh_external_status | grep -q OUVERT && ssh_external_status
    portal_summary
    ai_summary

    if [[ "$ENABLE_WIREGUARD" == "true" ]]; then

        echo "WireGuard (VPN):"
        echo "  CTID      : ${WG_ID}"
        echo "  IP        : ${WG_IP}"
        echo "  Écoute    : UDP ${WG_PORT}  ->  À REDIRIGER SUR LA BOX vers ${LAN_IP}"
        echo "  Endpoint  : $(wg_endpoint):${WG_PORT}"
        echo "  Réseau VPN: ${WG_NET} (serveur ${WG_SERVER_IP})"
        echo "  Pairs     : ${WG_PEERS}"
        echo "  Profils   : lan (réseau privé + hôte) | backup (VM FILES seulement) | internet (Internet seulement)"
        echo "  Config    : ./install.sh --run wg_show_peer <nom>   (clé privée : ne la diffuse pas)"
        echo "  Samba VPN : \\\\${FILES_IP%%/*}\\SHARED (l'IP LAN ne fonctionne pas via le VPN)"
        echo "  Gestion   : ./install.sh --run wg_add_peer|wg_add_device|wg_add_exit|wg_list_peers|wg_status"
        echo
    fi

    if [[ "$ENABLE_BACKUP" == "true" ]]; then

        echo "Sauvegardes :"
        echo "  Tâche     : homelab-daily, ${BACKUP_SCHEDULE}, vers '${BACKUP_STORAGE}' (rotation ${BACKUP_KEEP})"
        echo "  Hors site : $([[ -n "$BACKUP_RESTIC_REPO" ]] && echo "${BACKUP_RESTIC_REPO} (${BACKUP_OFFSITE_CRON})" || echo "non configurée (même disque que les données : à compléter)")"
        echo "  Outils    : ./install.sh --run backup_status | backup_run_now | backup_offsite_run"
        echo
    fi

    if [[ "$ENABLE_MAIL" == "true" ]]; then

        echo "Serveur mail :"
        echo "  CTID      : ${MAIL_ID}"
        echo "  IP        : ${MAIL_IP}"
        echo "  Nom       : $(mail_fqdn)"
        echo "  Stockage  : ${APPS_DIR}/mail (disque DATA, hors SHARED)"
        echo "  Ports     : 25, 465, 587, 993 -> À REDIRIGER SUR LA BOX vers ${LAN_IP}"
        echo "  Envoi     : $([[ -n "$MAIL_RELAY_HOST" ]] && echo "via le relais ${MAIL_RELAY_HOST}" || echo "direct (port 25 sortant)")"
        if [[ -n "$MAIL_ACCOUNTS_INFO" ]]; then
            echo "  Comptes   :"
            while IFS= read -r line; do
                [[ -n "$line" ]] && echo "    ${line}"
            done <<< "$MAIL_ACCOUNTS_INFO"
        fi
        echo "  SMTP appli: ${MAIL_IP%%/*}:587 (STARTTLS, identifiants d'un compte, serveur TLS : $(mail_fqdn))"
        echo "  IMAP      : $(mail_fqdn):993 (SSL/TLS)"
        echo "  DNS       : ./install.sh --run mail_check   (enregistrements MX/SPF/DKIM/DMARC à publier + PTR)"
        echo "  Gestion   : ./install.sh --run mail_add_account <nom>[:mdp] | mail_list_accounts | mail_logs | mail_queue | mail_restart"
        echo
    fi

    if [[ "$ENABLE_DNS" == "true" ]]; then

        echo "DNS filtrant (AdGuard Home) :"
        echo "  CTID      : ${DNS_ID}"
        echo "  IP        : ${DNS_IP}"
        echo "  Serveur DNS à donner aux appareils / à la box (DHCP) : ${LAN_IP}   (port 53 de l'hôte -> CT)"
        echo "  Interface : $([[ -n "$DNS_UI_PORT" ]] && echo "http://${LAN_IP}:${DNS_UI_PORT} (LAN), ")http://${DNS_IP%%/*} (réseau privé / VPN)"
        echo "  Compte    : ${DNS_ADMIN_USER} / $(dns_admin_password)"
        echo "  Amont     : ${DNS_UPSTREAMS}"
        echo "  Interne   : $([[ "$DNS_LOCAL_REWRITE" == "true" ]] && echo "noms du homelab -> ${LAN_IP} pour les clients LAN/VPN" || echo "désactivé")"
        echo "  ATTENTION : ne redirige JAMAIS le port 53 de la box vers ${LAN_IP} (résolveur ouvert)."
        echo "  VPN       : $([[ "$DNS_FOR_WG" == "true" && "$ENABLE_WIREGUARD" == "true" ]] && echo "pairs lan/internet -> ce DNS (si WireGuard existait déjà : ./install.sh --run deploy_wireguard)" || echo "non utilisé")"
        echo "  Outils    : ./install.sh --run dns_check | dns_configure | dns_stats | dns_logs | dns_update"
        echo
    fi

    if [[ "$ENABLE_MONITOR" == "true" ]]; then

        echo "Supervision (CT ${MONITOR_ID}, ${MONITOR_IP}) :"
        [[ "$MONITOR_KUMA" == "true" ]]     && echo "  Uptime Kuma: http://${LAN_IP}:${KUMA_PORT}  (crée le compte à la 1re visite ; moniteurs : ./install.sh --run monitor_list)"
        [[ "$MONITOR_HOMEPAGE" == "true" ]] && echo "  Homepage   : http://${LAN_IP}:${HOMEPAGE_PORT}  (LAN uniquement, sans authentification)"
        if [[ "$MONITOR_NTFY" == "true" ]]; then
            echo "  ntfy       : $(monitor_ntfy_public_url)  sujet ${NOTIFY_NTFY_TOPIC}  compte ${NTFY_ADMIN_USER} / ${NTFY_ADMIN_PASSWORD}"
            echo "               (application ntfy sur le téléphone : serveur ci-dessus, même compte)"
        fi
        echo "  Outils     : ./install.sh --run monitor_list | monitor_homepage_regen | monitor_logs | monitor_restart"
        echo
    fi

    if [[ "$ENABLE_CROWDSEC" == "true" ]]; then

        echo "CrowdSec (devant SWAG) :"
        echo "  Bannit les IP qui scannent / font du brute-force sur les sites exposés ; LAN, réseau privé et VPN jamais bannis."
        echo "  Outils    : ./install.sh --run crowdsec_status | crowdsec_unban <ip> | crowdsec_ban <ip> [durée]"
        echo
    fi

    if [[ "${ENABLE_ARR:-false}" == "true" ]]; then

        echo "Sonarr / Radarr / Prowlarr / qBittorrent (VM DOCKER) :"
        echo "  Sonarr    : http://${LAN_IP}:${SONARR_PORT}   Radarr : http://${LAN_IP}:${RADARR_PORT}   Prowlarr : http://${LAN_IP}:${PROWLARR_PORT}"
        echo "  qBittorrent: http://${LAN_IP}:${QBIT_PORT}   utilisateur ${ARR_QBIT_USER} / ${ARR_QBIT_PASSWORD}"
        echo "  VPN       : $([[ "$ARR_VPN" == "true" ]] && echo "qBittorrent passe uniquement par gluetun (fichier ${ARR_VPN_WG_CONF:-NON FOURNI : qBittorrent non démarré})" || echo "AUCUN (ton IP réelle est visible)")"
        echo "  Étapes    : Sonarr/Radarr/Prowlarr demandent un compte à la 1re visite ; ajoute tes indexeurs dans Prowlarr."
        echo "  Outils    : ./install.sh --run arr_status | arr_vpn_check | arr_logs | arr_credentials"
        echo
    fi

    echo "Maintenance automatique :"
    echo "  Alertes   : $([[ "$ENABLE_HEALTH" == "true" ]] && echo "santé de l'hôte (SMART, disques, services, sauvegardes) toutes les 10 min -> $(notify_ntfy_url 2>/dev/null || echo "ntfy non configuré")" || echo "désactivées (ENABLE_HEALTH=false)")"
    echo "  Dump BDD  : $([[ "$ENABLE_DB_DUMP" == "true" ]] && echo "avant chaque sauvegarde (${DB_DUMP_KEEP} conservés) -> ${APPS_DIR}/backups/db   (./install.sh --run db_dump_now | db_dump_status | db_restore_help)" || echo "désactivé")"
    echo "  Restauration : $([[ "$ENABLE_RESTORE_TEST" == "true" ]] && echo "test automatique (${RESTORE_TEST_CALENDAR})   (./install.sh --run restore_test_now | restore_test_status)" || echo "désactivé")"
    echo "  Images Docker: mode ${DOCKER_UPDATE_MODE} (${DOCKER_UPDATE_CALENDAR})   (./install.sh --run docker_update_check | docker_update_apply)"
    echo

    if [[ "$ENABLE_NODE" == "true" ]]; then

        echo "Node.js + MongoDB:"
        echo "  CTID      : ${NODE_ID}"
        echo "  IP        : ${NODE_IP}"
        echo "  Application: http://${NODE_IP%%/*}:${NODE_HTTP_PORT}  (LAN : http://${LAN_IP}:${NODE_HTTP_PORT})"
        if [[ -n "$NODE_SUBDOMAIN" && "$ENABLE_SWAG" == "true" ]]; then
            echo "  Via SWAG  : https://${NODE_SUBDOMAIN}.${DOMAIN}  (enregistrement DNS A requis)"
        fi
        echo "  Code      : /opt/node/app dans le CT (pct enter ${NODE_ID}), puis ./install.sh --run node_restart"
        echo "  MongoDB   : ${MONGO_ADMIN_USER} / ${MONGO_ADMIN_PASSWORD}  (base ${MONGO_DB}, authSource=admin)"
        if [[ "$NODE_MONGO_EXPOSE" == "true" ]]; then
            echo "  Connexion : mongodb://${MONGO_ADMIN_USER}:<mot de passe>@${NODE_IP%%/*}:27017/?authSource=admin"
        else
            echo "  Connexion : depuis le conteneur node : mongodb://${MONGO_ADMIN_USER}:<mot de passe>@mongo:27017/?authSource=admin"
        fi
        echo "  Outils    : ./install.sh --run node_backup_mongo | node_restart | node_logs"
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


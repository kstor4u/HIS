###############################################################################
#                       OUTILS DE RÉPARATION À CHAUD                          #
###############################################################################

# Fonctions utilisables SANS refaire l'installation, sur des VM déjà créées :
#
#   ./install.sh --run <fonction> [arguments]
#
#   ./install.sh --run repair_syncin_stack          # config Sync-in + SHARED
#   ./install.sh --run configure_nextcloud_external_storage 103
#   ./install.sh --run diagnose_webmin              # lecture seule
#   ./install.sh --run repair_webmin
#   ./install.sh --run check_letsencrypt            # lecture seule
#   ./install.sh --run repair_nextcloud_proxy       # Nextcloud derrière SWAG
#   ./install.sh --run repair_swag_add_media        # media.<domaine> -> Jellyfin + certificat
#   ./install.sh --run repair_swag_add_photo_alias  # photo.<domaine> = alias de photos.<domaine> (Immich)
#   ./install.sh --run swag_regenerate_certs [force] # (re)émet le certificat (force = repart de zéro)
#   ./install.sh --run repair_swag_add_office       # Collabora/OnlyOffice : sous-domaines SWAG + certificat
#   ./install.sh --run configure_nextcloud_office   # (re)configure Nextcloud pour Collabora/OnlyOffice
#   ./install.sh --run nextcloud_office_use collabora|onlyoffice|both|none   # choisit l'éditeur actif
#   ./install.sh --run repair_swag_add_node         # <NODE_SUBDOMAIN>.<domaine> -> app Node + certificat
#   ./install.sh --run repair_swag_add_monitor      # <NTFY_SUBDOMAIN>.<domaine> -> ntfy + certificat
#   ./install.sh --run repair_swag_add_mail         # ajoute <MAIL_SUBDOMAIN>.<domaine> au certificat SWAG
#   ./install.sh --run mail_check | mail_dns | mail_dkim | mail_add_account | mail_list_accounts | mail_logs | mail_restart | mail_sync_certs
#   ./install.sh --run backup_status | backup_run_now | backup_offsite_run | configure_backups | configure_backup_pull_access | configure_usb_export | configure_ssh_root_login | usb_export_now <dossier>   # sauvegardes
#   ./install.sh --run dns_check | dns_configure | dns_stats | dns_logs | dns_update   # DNS filtrant AdGuard Home
#   ./install.sh --run monitor_list | monitor_homepage_regen | monitor_logs | monitor_restart   # Kuma / ntfy / Homepage
#   ./install.sh --run configure_crowdsec | crowdsec_status | crowdsec_unban <ip> | crowdsec_ban <ip>   # CrowdSec devant SWAG
#   ./install.sh --run deploy_arr_stack | arr_status | arr_vpn_check | arr_logs | arr_credentials     # Sonarr/Radarr/Prowlarr/qBittorrent
#   ./install.sh --run configure_notify | notify_test | health_check                                  # alertes ntfy + santé de l'hôte
#   ./install.sh --run db_dump_now | db_dump_status | db_restore_help                                 # dump des bases
#   ./install.sh --run restore_test_now | restore_test_status | docker_update_check | docker_update_apply <projet>
#   ./install.sh --run node_backup_mongo            # sauvegarde MongoDB -> /mnt/data/apps/backups
#   ./install.sh --run node_restart | node_logs     # redémarre / journaux de l'app Node
#   ./install.sh --run configure_admin_user         # crée le compte sudo ADMIN_USER
#   ./install.sh --run swag_backup_certs            # sauvegarde les certificats Let's Encrypt
#   ./install.sh --run swag_restore_certs           # les restaure après une réinstallation
#
# (cloud-init ne rejoue jamais son runcmd : une correction du script ne
# s'applique donc pas aux VM existantes sans passer par ces fonctions.)

# Lit un fichier dans une VM via l'agent QEMU.
vm_read_file() {

    local VMID="$1" FILE="$2" raw

    raw="$(qm guest exec "$VMID" --timeout 60 -- cat "$FILE" 2>/dev/null || true)"

    jq -r '.["out-data"] // empty' <<< "$raw" 2>/dev/null || true
}

# Écrit un fichier dans une VM (contenu transmis en base64 : pas de problème
# de guillemets). Usage : vm_write_file VMID CHEMIN MODE CONTENU
vm_write_file() {

    local VMID="$1" FILE="$2" MODE="$3" CONTENT="$4" b64

    b64="$(printf '%s\n' "$CONTENT" | base64 -w0)"

    qm guest exec "$VMID" --timeout 60 -- bash -c \
        "echo '${b64}' | base64 -d > '${FILE}' && chmod '${MODE}' '${FILE}'" > /dev/null \
        || die "Écriture de ${FILE} impossible dans la VM ${VMID}."
}

# Exécute une commande shell dans une VM et affiche sa sortie.
vm_run() {

    local VMID="$1" TIMEOUT="$2" CMD="$3" raw

    raw="$(qm guest exec "$VMID" --timeout "$TIMEOUT" -- bash -c "$CMD" 2>&1 || true)"

    jq -r '.["out-data"] // empty, .["err-data"] // empty' <<< "$raw" 2>/dev/null || printf '%s\n' "$raw"
}

# Corrige une installation Sync-in existante (squelette de config invalide
# des versions <= 2.26.2) : réécrit environment.yaml au schéma officiel en
# CONSERVANT le mot de passe DB et les secrets déjà générés, sépare les
# données internes de Sync-in de SHARED et monte SHARED pour y créer des
# espaces à racine externe. Idempotent.
repair_syncin_stack() {

    local VMID="${1:-$DOCKER_ID}"
    local DIR="/opt/apps/syncin"
    local compose env_old dbpass s1 s2 s3 new_env new_compose

    info "Sync-in : lecture de la configuration actuelle dans la VM ${VMID}..."

    compose="$(vm_read_file "$VMID" "${DIR}/docker-compose.yml")"
    env_old="$(vm_read_file "$VMID" "${DIR}/environment.yaml")"

    [[ -n "$compose" ]] || die "docker-compose.yml de Sync-in introuvable dans la VM ${VMID}."

    dbpass="$(grep -oP 'MARIADB_PASSWORD=\K\S+' <<< "$compose" | head -1 || true)"
    [[ -n "$dbpass" ]] || die "Mot de passe MariaDB de Sync-in introuvable dans le compose."

    if grep -q '^mysql:' <<< "$env_old"; then
        info "Sync-in : environment.yaml déjà au nouveau format, conservé."
    else
        s1="$(grep -oP 'secret1:\s*\K\S+' <<< "$env_old" | head -1 || true)"
        s2="$(grep -oP 'secret2:\s*\K\S+' <<< "$env_old" | head -1 || true)"
        s3="$(grep -oP 'secret3:\s*\K\S+' <<< "$env_old" | head -1 || true)"

        [[ -n "$s1" ]] || s1="$(openssl rand -hex 32)"
        [[ -n "$s2" ]] || s2="$(openssl rand -hex 32)"
        [[ -n "$s3" ]] || s3="$(openssl rand -hex 32)"

        new_env="mysql:
  url: mysql://syncin:${dbpass}@syncin-db:3306/syncin
auth:
  encryptionKey: ${s1}
  token:
    access:
      secret: ${s2}
    refresh:
      secret: ${s3}
applications:
  files:
    dataPath: /app/data"

        vm_run "$VMID" 60 "cp -a ${DIR}/environment.yaml ${DIR}/environment.yaml.bak.\$(date +%s)" > /dev/null
        vm_write_file "$VMID" "${DIR}/environment.yaml" 0644 "$new_env"
        info "Sync-in : environment.yaml réécrit (ancienne version sauvegardée en .bak)."
    fi

    new_compose="$compose"

    if ! grep -q "${DOCKER_APPS_MOUNT}/syncin:/app/data" <<< "$new_compose"; then
        new_compose="$(sed -E \
            "s#^([[:space:]]*)- .*:/app/data[[:space:]]*\$#\\1- ${DOCKER_APPS_MOUNT}/syncin:/app/data\\n\\1- ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:rw#" \
            <<< "$new_compose")"
    fi

    if ! grep -q 'innodb_ft_cache_size' <<< "$new_compose"; then
        new_compose="$(sed -E \
            "/container_name: syncin-db/{n;s#^([[:space:]]*)restart: unless-stopped#&\\n\\1command: --innodb_ft_cache_size=16000000 --max-allowed-packet=1G#}" \
            <<< "$new_compose")"
    fi

    if [[ "$new_compose" != "$compose" ]]; then
        vm_run "$VMID" 60 "cp -a ${DIR}/docker-compose.yml ${DIR}/docker-compose.yml.bak.\$(date +%s)" > /dev/null
        vm_write_file "$VMID" "${DIR}/docker-compose.yml" 0600 "$new_compose"
        info "Sync-in : docker-compose.yml mis à jour (ancienne version sauvegardée en .bak)."
    fi

    prepare_apps_data_dirs

    info "Sync-in : redémarrage de la stack..."
    vm_run "$VMID" 600 "cd ${DIR} && docker compose up -d --force-recreate" | tail -n 10

    sleep 20

    info "Sync-in : derniers logs du conteneur :"
    vm_run "$VMID" 60 "docker logs --tail 25 syncin 2>&1"

    info "Sync-in : réponse HTTP sur ${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT} : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT}" || true)"
    info "Sync-in : connecte-toi, puis Admin > Spaces : ajoute une racine externe ${DOCKER_SHARED_MOUNT}/Users (idem Photo, Movies, Music)."
}

# Sync-in + serveurs de documents (2.58.0 OnlyOffice, 2.59.0 Collabora) : Sync-in utilise les serveurs OnlyOffice et/ou
# Collabora déjà déployés pour Nextcloud (mode « serveur externe » : https://<sous-domaine>). OnlyOffice est authentifié par
# le secret JWT ONLYOFFICE_JWT_SECRET ; Collabora n'a pas de secret mais n'accepte que les hôtes WOPI listés (aliasgroupN).
syncin_onlyoffice_wanted() {
    [[ "${ENABLE_SYNCIN:-false}" == "true" && "${SYNCIN_ONLYOFFICE:-false}" == "true" && "${ENABLE_ONLYOFFICE:-false}" == "true" ]]
}

syncin_collabora_wanted() {
    [[ "${ENABLE_SYNCIN:-false}" == "true" && "${SYNCIN_COLLABORA:-false}" == "true" && "${ENABLE_COLLABORA:-false}" == "true" ]]
}

syncin_editors_wanted() {
    syncin_onlyoffice_wanted || syncin_collabora_wanted
}

# Premier nom complet d'une variable de sous-domaine (SYNCIN_SUBDOMAIN, ONLYOFFICE_SUBDOMAIN, COLLABORA_SUBDOMAIN).
subdomain_first_fqdn() {
    local all
    all="$(sd_fqdns "$1")"
    printf '%s' "${all%% *}"
}

# Noms complets (séparés par des espaces) des serveurs de documents utilisés par Sync-in.
syncin_editor_fqdns() {
    if syncin_onlyoffice_wanted; then sd_fqdns ONLYOFFICE_SUBDOMAIN; printf ' '; fi
    if syncin_collabora_wanted; then sd_fqdns COLLABORA_SUBDOMAIN; fi
    return 0
}

# Contenu (non indenté) de /opt/apps/syncin/environment.yaml.
syncin_environment_text() {
    cat <<YAML
# Schéma Sync-in v2 : mysql.url, auth.encryptionKey, auth.token.*,
# applications.files.dataPath (cf. environment.dist.yaml du projet).
mysql:
  url: mysql://syncin:${SYNCIN_DB_PASSWORD}@syncin-db:3306/syncin
auth:
  encryptionKey: ${SYNCIN_SECRET_1}
  token:
    access:
      secret: ${SYNCIN_SECRET_2}
    refresh:
      secret: ${SYNCIN_SECRET_3}
YAML
    if syncin_editors_wanted; then
        cat <<YAML
server:
  publicUrl: 'https://$(subdomain_first_fqdn SYNCIN_SUBDOMAIN)'
YAML
    fi
    cat <<YAML
applications:
  files:
    dataPath: /app/data
YAML
    if syncin_editors_wanted; then
        printf '    editors:\n'
    fi
    if syncin_onlyoffice_wanted; then
        cat <<YAML
      onlyoffice:
        enabled: true
        externalServer: 'https://$(subdomain_first_fqdn ONLYOFFICE_SUBDOMAIN)'
        secret: '${ONLYOFFICE_JWT_SECRET}'
        verifySSL: true
YAML
    fi
    if syncin_collabora_wanted; then
        cat <<YAML
      collabora:
        enabled: true
        externalServer: 'https://$(subdomain_first_fqdn COLLABORA_SUBDOMAIN)'
YAML
    fi
}

# Lignes extra_hosts du conteneur Sync-in (résoudre les serveurs de documents via SWAG) : indentation du compose cloud-init.
syncin_extra_hosts_cloudinit() {
    local n
    syncin_editors_wanted || return 0
    printf '          extra_hosts:\n'
    for n in $(syncin_editor_fqdns); do printf '            - "%s:%s"\n' "$n" "${SWAG_IP%%/*}"; done
}

# Lignes à ajouter à extra_hosts du conteneur OnlyOffice (résoudre Sync-in via SWAG), indentation du compose cloud-init.
onlyoffice_syncin_hosts_cloudinit() {
    local n
    syncin_onlyoffice_wanted || return 0
    for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do printf '            - "%s:%s"\n' "$n" "${SWAG_IP%%/*}"; done
}

# Collabora : lignes extra_hosts (résoudre Sync-in via SWAG) et aliasgroupN (Sync-in autorisé comme hôte WOPI, à partir de 2
# car Nextcloud est aliasgroup1), indentation du compose cloud-init.
collabora_syncin_hosts_cloudinit() {
    local n
    syncin_collabora_wanted || return 0
    for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do printf '            - "%s:%s"\n' "$n" "${SWAG_IP%%/*}"; done
}

collabora_syncin_alias_cloudinit() {
    local n i=2
    syncin_collabora_wanted || return 0
    for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do printf '            - aliasgroup%s=https://%s:443\n' "$i" "$n"; i=$((i + 1)); done
}

# Ajoute des entrées « hôte:ip » à extra_hosts d'un docker-compose (texte). $1 = compose, $2 = container_name, puis les
# entrées. S'il existe déjà une clé extra_hosts, les entrées y sont ajoutées ; sinon elle est créée sous container_name.
compose_add_extra_hosts() {

    local text="$1" cname="$2" line out="" ind has=false placed=false h
    shift 2

    grep -qE '^[[:space:]]*extra_hosts:[[:space:]]*$' <<< "$text" && has=true

    while IFS= read -r line || [[ -n "$line" ]]; do
        out+="${line}"$'\n'
        [[ "$placed" == "false" ]] || continue
        if [[ "$has" == "true" && "$line" =~ ^([[:space:]]*)extra_hosts:[[:space:]]*$ ]]; then
            ind="${BASH_REMATCH[1]}"
            for h in "$@"; do out+="${ind}  - \"${h}\""$'\n'; done
            placed=true
        elif [[ "$has" == "false" && "$line" =~ ^([[:space:]]*)container_name:[[:space:]]*${cname}[[:space:]]*$ ]]; then
            ind="${BASH_REMATCH[1]}"
            out+="${ind}extra_hosts:"$'\n'
            for h in "$@"; do out+="${ind}  - \"${h}\""$'\n'; done
            placed=true
        fi
    done <<< "$text"

    printf '%s' "${out%$'\n'}"
}

# Insère une ligne (avec l'indentation de la ligne repère) après la première ligne qui contient le repère.
# $1 = texte, $2 = repère, $3 = ligne à insérer (sans indentation).
compose_insert_after() {

    local text="$1" anchor="$2" new="$3" line out="" placed=false ind

    while IFS= read -r line || [[ -n "$line" ]]; do
        out+="${line}"$'\n'
        if [[ "$placed" == "false" && "$line" == *"${anchor}"* ]]; then
            [[ "$line" =~ ^([[:space:]]*) ]]
            ind="${BASH_REMATCH[1]}"
            out+="${ind}${new}"$'\n'
            placed=true
        fi
    done <<< "$text"

    printf '%s' "${out%$'\n'}"
}

# Active OnlyOffice et/ou Collabora dans une installation Sync-in existante (VM Docker) : réécrit environment.yaml (secrets
# inchangés, sauvegarde .bak), ajoute les extra_hosts (et, pour Collabora, aliasgroupN) aux compose concernés, relance les
# serveurs de documents puis Sync-in.
#   Prérequis : ENABLE_SYNCIN=true ; SYNCIN_ONLYOFFICE=true avec ENABLE_ONLYOFFICE=true (conteneur déjà déployé) et/ou
#   SYNCIN_COLLABORA=true avec ENABLE_COLLABORA=true.
#   ./install.sh --run syncin_editors_apply        (ancien nom : syncin_onlyoffice_apply)
syncin_editors_apply() {

    local VMID="${1:-$DOCKER_ID}" dir="/opt/apps/syncin" odir="/opt/apps/onlyoffice" cdir="/opt/apps/collabora"
    local env_old env_new sc oc cc sc_new oc_new cc_new n entry bak i first_sync
    local -a sync_hosts=() oo_hosts=() co_hosts=()

    [[ "${ENABLE_SYNCIN:-false}" == "true" ]] || die "ENABLE_SYNCIN=true est requis."
    if ! syncin_editors_wanted; then
        die "Rien à appliquer : mets SYNCIN_ONLYOFFICE=true (avec ENABLE_ONLYOFFICE=true) et/ou SYNCIN_COLLABORA=true (avec ENABLE_COLLABORA=true) dans le fichier de réponses (./install.sh --update-answers ajoute les variables), puis relance cette commande."
    fi
    [[ -n "${SYNCIN_DB_PASSWORD:-}" && -n "${SYNCIN_SECRET_1:-}" && -n "${SYNCIN_SECRET_2:-}" && -n "${SYNCIN_SECRET_3:-}" ]] \
        || die "Secrets Sync-in introuvables (proxmox-homelab-secrets.json) : lance la commande depuis le dossier de l'installation."
    if syncin_onlyoffice_wanted && [[ -z "${ONLYOFFICE_JWT_SECRET:-}" ]]; then
        die "Secret JWT d'OnlyOffice introuvable (proxmox-homelab-secrets.json) : lance la commande depuis le dossier de l'installation."
    fi

    env_old="$(vm_read_file "$VMID" "${dir}/environment.yaml")"
    sc="$(vm_read_file "$VMID" "${dir}/docker-compose.yml")"
    oc=""; cc=""
    syncin_onlyoffice_wanted && oc="$(vm_read_file "$VMID" "${odir}/docker-compose.yml")"
    syncin_collabora_wanted  && cc="$(vm_read_file "$VMID" "${cdir}/docker-compose.yml")"

    [[ -n "$env_old" && -n "$sc" ]] || die "Sync-in introuvable dans la VM ${VMID} (${dir})."
    if syncin_onlyoffice_wanted && [[ -z "$oc" ]]; then
        die "OnlyOffice introuvable dans la VM ${VMID} (${odir}) : ENABLE_ONLYOFFICE=true n'a pas encore été déployé."
    fi
    if syncin_collabora_wanted && [[ -z "$cc" ]]; then
        die "Collabora introuvable dans la VM ${VMID} (${cdir}) : ENABLE_COLLABORA=true n'a pas encore été déployé."
    fi

    # Les secrets du fichier de réponses doivent être ceux de la VM : sinon on s'arrête sans rien modifier.
    grep -qF "encryptionKey: ${SYNCIN_SECRET_1}" <<< "$env_old" \
        && grep -qF "secret: ${SYNCIN_SECRET_2}" <<< "$env_old" \
        && grep -qF ":${SYNCIN_DB_PASSWORD}@" <<< "$env_old" \
        || die "Les secrets du fichier de réponses ne correspondent pas à ceux de ${dir}/environment.yaml : rien n'a été modifié."

    env_new="$(syncin_environment_text)"
    first_sync="$(subdomain_first_fqdn SYNCIN_SUBDOMAIN)"

    # Sync-in doit résoudre les serveurs de documents via SWAG.
    for n in $(syncin_editor_fqdns); do
        entry="${n}:${SWAG_IP%%/*}"
        grep -qF "\"${entry}\"" <<< "$sc" || sync_hosts+=("$entry")
    done

    # OnlyOffice et Collabora doivent résoudre Sync-in via SWAG (téléchargement et enregistrement des fichiers).
    oc_new="$oc"; cc_new="$cc"; sc_new="$sc"
    if syncin_onlyoffice_wanted; then
        for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do
            entry="${n}:${SWAG_IP%%/*}"
            grep -qF "\"${entry}\"" <<< "$oc" || oo_hosts+=("$entry")
        done
        (( ${#oo_hosts[@]} )) && oc_new="$(compose_add_extra_hosts "$oc" onlyoffice "${oo_hosts[@]}")"
    fi
    if syncin_collabora_wanted; then
        for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do
            entry="${n}:${SWAG_IP%%/*}"
            grep -qF "\"${entry}\"" <<< "$cc" || co_hosts+=("$entry")
        done
        (( ${#co_hosts[@]} )) && cc_new="$(compose_add_extra_hosts "$cc" collabora "${co_hosts[@]}")"
        # Hôtes WOPI autorisés : un aliasgroupN par nom de Sync-in (N après le plus grand déjà utilisé).
        i="$(grep -oE 'aliasgroup[0-9]+' <<< "$cc_new" | grep -oE '[0-9]+' | sort -n | tail -n 1 || true)"
        i=$(( ${i:-0} + 1 ))
        for n in $(sd_fqdns SYNCIN_SUBDOMAIN); do
            if ! grep -qF "https://${n}:443" <<< "$cc_new"; then
                cc_new="$(compose_insert_after "$cc_new" "aliasgroup" "- aliasgroup${i}=https://${n}:443")"
                i=$((i + 1))
            fi
        done
        grep -qF "https://${first_sync}:443" <<< "$cc_new" \
            || die "Compose de Collabora (${cdir}) sans ligne aliasgroup : ajoute à la main « - aliasgroupN=https://${first_sync}:443 » sous environment, puis relance."
    fi
    (( ${#sync_hosts[@]} )) && sc_new="$(compose_add_extra_hosts "$sc" syncin "${sync_hosts[@]}")"

    bak="bak.$(date +%s)"

    if [[ "$env_new" != "$env_old" ]]; then
        vm_run "$VMID" 60 "cp -a ${dir}/environment.yaml ${dir}/environment.yaml.${bak}" > /dev/null
        vm_write_file "$VMID" "${dir}/environment.yaml" 0644 "$env_new"
        info "Sync-in : environment.yaml mis à jour ; ancienne version en .${bak}."
    else
        info "Sync-in : environment.yaml déjà à jour."
    fi
    if [[ "$oc_new" != "$oc" ]]; then
        vm_run "$VMID" 60 "cp -a ${odir}/docker-compose.yml ${odir}/docker-compose.yml.${bak}" > /dev/null
        vm_write_file "$VMID" "${odir}/docker-compose.yml" 0600 "$oc_new"
        info "OnlyOffice : extra_hosts ajoutés (${oo_hosts[*]})."
    fi
    if [[ "$cc_new" != "$cc" ]]; then
        vm_run "$VMID" 60 "cp -a ${cdir}/docker-compose.yml ${cdir}/docker-compose.yml.${bak}" > /dev/null
        vm_write_file "$VMID" "${cdir}/docker-compose.yml" 0600 "$cc_new"
        info "Collabora : hôte WOPI et extra_hosts ajoutés pour ${first_sync}."
    fi
    if [[ "$sc_new" != "$sc" ]]; then
        vm_run "$VMID" 60 "cp -a ${dir}/docker-compose.yml ${dir}/docker-compose.yml.${bak}" > /dev/null
        vm_write_file "$VMID" "${dir}/docker-compose.yml" 0600 "$sc_new"
        info "Sync-in : extra_hosts ajoutés (${sync_hosts[*]})."
    fi

    if syncin_onlyoffice_wanted; then
        info "OnlyOffice : application de la configuration..."
        vm_run "$VMID" 600 "cd ${odir} && docker compose up -d 2>&1 | tail -n 5"
    fi
    if syncin_collabora_wanted; then
        info "Collabora : application de la configuration (recréation si le compose a changé)..."
        vm_run "$VMID" 600 "cd ${cdir} && docker compose up -d 2>&1 | tail -n 5"
    fi
    info "Sync-in : relance du serveur (lecture du nouvel environment.yaml)..."
    vm_run "$VMID" 600 "cd ${dir} && docker compose up -d --force-recreate syncin 2>&1 | tail -n 5"

    sleep 20

    if syncin_onlyoffice_wanted; then
        n="$(subdomain_first_fqdn ONLYOFFICE_SUBDOMAIN)"
        info "OnlyOffice : healthcheck (attendu : true) : $(vm_run "$VMID" 60 "curl -sk --max-time 20 --resolve ${n}:443:${SWAG_IP%%/*} https://${n}/healthcheck" | tr -d '\n')"
    fi
    if syncin_collabora_wanted; then
        n="$(subdomain_first_fqdn COLLABORA_SUBDOMAIN)"
        info "Collabora : discovery (attendu : 200) : $(vm_run "$VMID" 60 "curl -sk --max-time 20 -o /dev/null -w '%{http_code}' --resolve ${n}:443:${SWAG_IP%%/*} https://${n}/hosting/discovery" | tr -d '\n')"
    fi
    info "Sync-in : réponse HTTP sur ${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT} : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT}" || true)"
    info "Sync-in : derniers logs du conteneur :"
    vm_run "$VMID" 60 "docker logs --tail 15 syncin 2>&1"
    info "Teste : ouvre un .docx dans Sync-in (https://${first_sync}). OnlyOffice demande environ 4 Go de RAM de plus (DOCKER_MEMORY)."
}

# Ancien nom (2.58.0), conservé.
syncin_onlyoffice_apply() { syncin_editors_apply "$@"; }

# Diagnostic Webmin (lecture seule) sur la VM FILES.
diagnose_webmin() {

    local VMID="${1:-$FILES_ID}"

    info "Webmin : diagnostic sur la VM ${VMID}..."

    vm_run "$VMID" 60 '
        echo "--- cloud-init"; cloud-init status --long 2>&1 | head -n 8
        echo "--- paquet webmin"; dpkg-query -W -f="${Status} ${Version}\n" webmin 2>&1
        echo "--- service"; systemctl is-active webmin 2>&1; systemctl is-enabled webmin 2>&1
        echo "--- port 10000"; ss -ltn 2>/dev/null | grep -E ":10000\b" || echo "rien n écoute sur 10000"
        echo "--- dépôt webmin"; ls /etc/apt/sources.list.d/ 2>&1 | grep -i webmin || echo "aucun dépôt webmin"
        echo "--- fin du log cloud-init"; tail -n 25 /var/log/cloud-init-output.log 2>&1
    '

    info "Webmin : test depuis l'hôte : HTTPS=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${FILES_IP%%/*}:10000" || true) (200/302 = OK), HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${FILES_IP%%/*}:10000" || true)"
}

# (Ré)installe Webmin dans la VM FILES en fournissant la confirmation que
# le script de dépôt attend. Voir diagnose_webmin pour vérifier avant/après.
repair_webmin() {

    local VMID="${1:-$FILES_ID}"

    info "Webmin : (ré)installation dans la VM ${VMID} (quelques minutes)..."

    vm_run "$VMID" 1500 '
        set -Eeuo pipefail
        export DEBIAN_FRONTEND=noninteractive
        cd /root
        wget --https-only -O webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
        chmod 700 webmin-setup-repo.sh
        sh ./webmin-setup-repo.sh <<< "y"
        apt-get update
        apt-get install -y --install-recommends webmin
        systemctl enable webmin
        systemctl restart webmin
        systemctl is-active webmin
        rm -f /root/webmin-setup-repo.sh
    ' | tail -n 25

    diagnose_webmin "$VMID"
}

# Déclare SWAG comme proxy de confiance dans une instance Nextcloud déjà
# installée (les installations neuves le reçoivent via TRUSTED_PROXIES).
repair_nextcloud_proxy() {

    local VMID="${1:-$DOCKER_ID}"

    info "Nextcloud : proxy de confiance ${SWAG_IP%%/*} (SWAG)..."

    nextcloud_occ "$VMID" config:system:set trusted_proxies 0 --value="${SWAG_IP%%/*}"
    nextcloud_occ "$VMID" config:system:get trusted_proxies
}

# Corrige « Impossible de créer ou d'écrire dans le répertoire de données » : le dossier de données de
# Nextcloud (NEXTCLOUD_DATA_DIR sous DOCKER_APPS_MOUNT) n'était pas monté dans le conteneur.
# Ajoute le montage au docker-compose.yml existant puis recrée le conteneur.
# Usage : ./install.sh --run repair_nextcloud_data_mount
repair_nextcloud_data_mount() {

    local VMID="${1:-$DOCKER_ID}"
    local DIR="/opt/apps/nextcloud" compose bind

    bind="${DOCKER_APPS_MOUNT}/nextcloud:${DOCKER_APPS_MOUNT}/nextcloud:rw"

    compose="$(vm_run "$VMID" 30 "cat ${DIR}/docker-compose.yml")" \
        || die "Nextcloud : ${DIR}/docker-compose.yml introuvable dans la VM ${VMID}."

    prepare_apps_data_dirs

    if grep -qF "$bind" <<< "$compose"; then
        info "Nextcloud : le dossier de données est déjà monté dans le conteneur."
    else
        vm_run "$VMID" 60 "cp -a ${DIR}/docker-compose.yml ${DIR}/docker-compose.yml.bak.\$(date +%s)" > /dev/null
        compose="$(sed -E "s#^([[:space:]]*)- ${DOCKER_SHARED_MOUNT}:.*:rw[[:space:]]*\$#&\\n\\1- ${bind}#" <<< "$compose")"
        grep -qF "$bind" <<< "$compose" \
            || die "Nextcloud : ligne de montage SHARED introuvable dans le compose ; ajoute à la main sous « volumes » de nextcloud : - ${bind}"
        vm_write_file "$VMID" "${DIR}/docker-compose.yml" 0600 "$compose"
        info "Nextcloud : montage ${DOCKER_APPS_MOUNT}/nextcloud ajouté (ancienne version sauvegardée en .bak)."
    fi

    info "Nextcloud : recréation du conteneur..."
    vm_run "$VMID" 900 "cd ${DIR} && docker compose up -d --force-recreate nextcloud" | tail -n 10
    vm_run "$VMID" 30 "docker exec nextcloud sh -c 'ls -ld ${DOCKER_APPS_MOUNT}/nextcloud && touch ${DOCKER_APPS_MOUNT}/nextcloud/.w && rm ${DOCKER_APPS_MOUNT}/nextcloud/.w && echo ECRITURE-OK'" \
        || warn "Nextcloud : écriture impossible dans ${DOCKER_APPS_MOUNT}/nextcloud (vérifie les droits : ls -ld sur la VM)."
}

# Vérifie (lecture seule) les prérequis Let's Encrypt de SWAG : DNS des 4
# noms du certificat, IPv6, certificat émis, et HTTPS réellement servi.
# Validation "http" = Let's Encrypt doit joindre le port 80 depuis Internet.
check_letsencrypt() {

    local pub_ip name v4 v6 code
    local -a names=("${DOMAIN}") web_names=()
    local h

    # Tous les noms du certificat (core/35-subdomains.sh) ; le serveur mail n'est pas un site web
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        names+=("${h}.${DOMAIN}")
        [[ " ${SUBDOMAIN_ALL[MAIL_SUBDOMAIN]:-} " == *" ${h} "* ]] || web_names+=("${h}.${DOMAIN}")
    done < <(subdomain_hosts cert | awk '!s[$0]++')

    pub_ip="$(curl -s4 --max-time 10 https://api.ipify.org || true)"
    info "IP publique vue depuis l'hôte : ${pub_ip:-inconnue}"

    for name in "${names[@]}"; do

        v4="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}' || true)"
        v6="$(getent ahostsv6 "$name" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}' || true)"

        if [[ -z "$v4" ]]; then
            warn "DNS  ${name} : AUCUN enregistrement A -> la validation échouera."
        elif [[ -n "$pub_ip" && "$v4" != "$pub_ip" ]]; then
            warn "DNS  ${name} : A=${v4} mais l'IP publique est ${pub_ip} (DNS pas à jour, ou CGNAT/DDNS ?)."
        else
            info "DNS  ${name} : A=${v4} OK"
        fi

        if [[ -n "$v6" ]]; then
            warn "DNS  ${name} : AAAA=${v6} présent. Let's Encrypt préfère l'IPv6 et la redirection de ports est IPv4 seulement -> supprime l'AAAA ou fais suivre l'IPv6."
        fi
    done

    info "Certificat et journaux SWAG (CT ${SWAG_ID}) :"

    pct exec "$SWAG_ID" -- bash -c "
        ls /opt/swag/config/etc/letsencrypt/live 2>&1
        docker exec swag openssl x509 -noout -issuer -subject -enddate -in /config/etc/letsencrypt/live/${DOMAIN}/fullchain.pem 2>&1
        docker logs swag 2>&1 | grep -iE 'server ready|successfully|not yet due|error|failed|challenge|unauthorized|timeout|caa|too many|rate limit|retry after' | tail -n 15
        docker exec swag tail -n 60 /config/log/letsencrypt/letsencrypt.log 2>/dev/null | grep -iE 'detail|problem|too many|caa|retry after' | tail -n 8
    " || warn "Impossible d'interroger le CT SWAG ${SWAG_ID}."

    for name in "${web_names[@]}"; do

        code="$(curl -s -o /dev/null -w '%{http_code} (vérif. certificat : %{ssl_verify_result}, 0 = valide)' \
            --max-time 15 --resolve "${name}:443:${SWAG_IP%%/*}" "https://${name}" || true)"

        info "HTTPS ${name} via SWAG : ${code:-pas de réponse}"
    done

    info "Test depuis l'extérieur (4G, pas le Wi-Fi) : curl -I http://cloud.${DOMAIN}  -> doit répondre (301 vers https)."
    info "Après correction du DNS/de la box : pct exec ${SWAG_ID} -- docker restart swag (SWAG retente l'émission au démarrage)."
}

# Ajoute media.<domaine> (Jellyfin) à une installation SWAG existante :
# sous-domaine dans le certificat Let's Encrypt + conf nginx. Au redémarrage,
# SWAG détecte le nouveau nom et réémet le certificat élargi. Idempotent.
# Le port 80 doit toujours être joignable depuis Internet (validation HTTP).
repair_swag_add_media() {

    local compose new_compose b64 code

    info "SWAG : ajout de $(sd_fqdns JELLYFIN_SUBDOMAIN) -> Jellyfin (${DOCKER_IP%%/*}:${JELLYFIN_HTTP_PORT})..."

    compose="$(pct exec "$SWAG_ID" -- cat /opt/swag/docker-compose.yml 2>/dev/null || true)"
    [[ -n "$compose" ]] || die "docker-compose.yml de SWAG introuvable dans le CT ${SWAG_ID}."

    if grep -qE 'SUBDOMAINS=.*\bmedia\b' <<< "$compose"; then
        info "SWAG : media déjà présent dans SUBDOMAINS."
    else
        new_compose="$(sed -E 's/^([[:space:]]*- SUBDOMAINS=.*)$/\1,media/' <<< "$compose")"
        [[ "$new_compose" != "$compose" ]] || die "Ligne SUBDOMAINS introuvable dans le compose de SWAG."

        pct exec "$SWAG_ID" -- bash -c "cp -a /opt/swag/docker-compose.yml /opt/swag/docker-compose.yml.bak.\$(date +%s)"

        b64="$(printf '%s\n' "$new_compose" | base64 -w0)"
        pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/docker-compose.yml"
        info "SWAG : SUBDOMAINS mis à jour (ancienne version sauvegardée en .bak)."
    fi

    b64="$(swag_media_conf | base64 -w0)"
    pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/config/nginx/site-confs/media.conf"
    info "SWAG : media.conf écrit."

    info "SWAG : redémarrage et émission du certificat (jusqu'à ~2 min)..."
    pct exec "$SWAG_ID" -- bash -c "cd /opt/swag && docker compose up -d --force-recreate" | tail -n 5

    sleep 60

    pct exec "$SWAG_ID" -- bash -c "docker logs swag 2>&1 | grep -iE 'server ready|successfully|not yet due|error|failed|challenge|unauthorized|timeout|media' | tail -n 15" || true

    code="$(curl -s -o /dev/null -w '%{http_code} (vérif. certificat : %{ssl_verify_result}, 0 = valide)' \
        --max-time 15 --resolve "${JELLYFIN_SUBDOMAIN}.${DOMAIN}:443:${SWAG_IP%%/*}" "https://${JELLYFIN_SUBDOMAIN}.${DOMAIN}" || true)"

    info "HTTPS ${JELLYFIN_SUBDOMAIN}.${DOMAIN} via SWAG : ${code:-pas de réponse}"
    info "Si la vérification n'est pas à 0, relance dans une minute : ./install.sh --run check_letsencrypt"
}

# Applique à un SWAG déjà installé les sous-domaines définis par NEXTCLOUD_SUBDOMAIN, SYNCIN_SUBDOMAIN,
# IMMICH_SUBDOMAIN, JELLYFIN_SUBDOMAIN, COLLABORA_/ONLYOFFICE_/MAIL_/NODE_/NTFY_/HOMEPAGE_SUBDOMAIN
# (un ou plusieurs noms par service) : liste du certificat, confs nginx, domaines de confiance Nextcloud,
# fichier de zone DNS. SWAG réémet alors le certificat élargi (port 80 joignable depuis Internet ; Let's Encrypt
# limite à 5 certificats identiques par semaine). Les anciens fichiers de conf d'un nom abandonné ne sont
# pas supprimés (ls /opt/swag/config/nginx/site-confs dans le CT SWAG).
# Usage : ./install.sh --run repair_swag_subdomains
repair_swag_subdomains() {

    local csv compose new_compose tmp script fq i=10

    pct status "$SWAG_ID" >/dev/null 2>&1 || die "CT SWAG ${SWAG_ID} introuvable."

    csv="$(subdomain_hosts_csv)"
    info "SWAG : sous-domaines du certificat : ${csv}"

    compose="$(pct exec "$SWAG_ID" -- cat /opt/swag/docker-compose.yml 2>/dev/null || true)"
    [[ -n "$compose" ]] || die "docker-compose.yml de SWAG introuvable dans le CT ${SWAG_ID}."

    new_compose="$(sed -E "s#^([[:space:]]*- SUBDOMAINS=).*#\\1${csv}#" <<< "$compose")"
    grep -q "SUBDOMAINS=${csv}\$" <<< "$new_compose" || die "Ligne SUBDOMAINS introuvable dans le compose de SWAG."

    if [[ "$new_compose" != "$compose" ]]; then
        pct exec "$SWAG_ID" -- cp -a /opt/swag/docker-compose.yml "/opt/swag/docker-compose.yml.bak.$(date +%s)"
        tmp="$(mktemp)"
        printf '%s\n' "$new_compose" > "$tmp"
        pct push "$SWAG_ID" "$tmp" /opt/swag/docker-compose.yml
        rm -f "$tmp"
        info "SWAG : SUBDOMAINS mis à jour (ancienne version sauvegardée en .bak)."
    else
        info "SWAG : SUBDOMAINS déjà à jour."
    fi

    script="$(mktemp)"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -Eeuo pipefail'
        echo 'cd /opt/swag'
        swag_conf_blocks
        echo 'docker compose up -d --force-recreate'
    } > "$script"
    pct_push_script "$SWAG_ID" "$script" /root/swag-subdomains.sh
    rm -f "$script"
    pct exec "$SWAG_ID" -- bash /root/swag-subdomains.sh || die "Écriture des confs SWAG échouée."
    pct exec "$SWAG_ID" -- rm -f /root/swag-subdomains.sh || true
    info "SWAG : confs nginx réécrites, conteneur recréé (émission du certificat : ./install.sh --run check_letsencrypt dans 2 min)."

    if [[ "${ENABLE_DOCKER:-false}" == "true" ]] && qm status "$DOCKER_ID" >/dev/null 2>&1; then
        for fq in $(sd_fqdns NEXTCLOUD_SUBDOMAIN); do
            nextcloud_occ "$DOCKER_ID" config:system:set trusted_domains "$i" --value="$fq" >/dev/null || true
            i=$((i + 1))
        done
        info "Nextcloud : domaines de confiance mis à jour ($(sd_fqdns NEXTCLOUD_SUBDOMAIN))."
    fi

    info "SWAG : mise à jour de la zone DNS et d'AdGuard..."
    dns_zone_generate || true
    [[ "${ENABLE_DNS:-false}" == "true" ]] && { dns_configure || warn "DNS : réécritures non mises à jour (./install.sh --run dns_configure)."; }
    return 0
}

# Sauvegarde les certificats Let's Encrypt de SWAG sur l'hôte (SWAG_CERT_BACKUP).
# Appelée automatiquement quand un certificat vient d'être émis.
swag_backup_certs() {

    local tmp="/root/swag-letsencrypt.tgz"

    if ! pct exec "$SWAG_ID" -- test -d /opt/swag/config/etc/letsencrypt/live; then
        warn "SWAG : aucun certificat Let's Encrypt à sauvegarder (SWAG sert un certificat auto-signé)."
        return 0
    fi

    mkdir -p "$(dirname "$SWAG_CERT_BACKUP")"
    chmod 700 "$(dirname "$SWAG_CERT_BACKUP")"

    pct exec "$SWAG_ID" -- tar -C /opt/swag/config/etc -czf "$tmp" letsencrypt
    pct pull "$SWAG_ID" "$tmp" "$SWAG_CERT_BACKUP"
    pct exec "$SWAG_ID" -- rm -f "$tmp"
    chmod 600 "$SWAG_CERT_BACKUP"

    info "SWAG : certificats sauvegardés dans ${SWAG_CERT_BACKUP} (contient les clés privées : ne le diffuse pas)."
}

# Restaure les certificats sauvegardés dans un SWAG fraîchement réinstallé, puis
# redémarre SWAG : il détecte un certificat valide et n'en redemande pas.
swag_restore_certs() {

    [[ -f "$SWAG_CERT_BACKUP" ]] \
        || die "Aucune sauvegarde de certificats : ${SWAG_CERT_BACKUP} (voir swag_backup_certs)."

    info "SWAG : restauration des certificats depuis ${SWAG_CERT_BACKUP}..."

    pct push "$SWAG_ID" "$SWAG_CERT_BACKUP" /root/swag-letsencrypt.tgz --perms 0600

    pct exec "$SWAG_ID" -- bash -c "
        set -e
        mkdir -p /opt/swag/config/etc
        rm -rf /opt/swag/config/etc/letsencrypt
        tar -C /opt/swag/config/etc -xzf /root/swag-letsencrypt.tgz
        rm -f /root/swag-letsencrypt.tgz
        cd /opt/swag && docker compose restart swag
    "

    sleep 30

    verify_swag_certificate
}

# Ajoute photo.<domaine> comme alias de photos.<domaine> (Immich) dans SWAG :
# sous-domaine du certificat + server_name, puis redémarrage (nouveau certificat
# élargi, émis automatiquement par SWAG). Idempotent.
repair_swag_add_photo_alias() {

    local compose new_compose b64 conf

    info "SWAG : ajout de photo.${DOMAIN} (alias de photos.${DOMAIN} -> Immich)..."

    compose="$(pct exec "$SWAG_ID" -- cat /opt/swag/docker-compose.yml 2>/dev/null || true)"
    [[ -n "$compose" ]] || die "docker-compose.yml de SWAG introuvable dans le CT ${SWAG_ID}."

    if grep -qE 'SUBDOMAINS=.*\bphoto\b' <<< "$compose"; then
        info "SWAG : photo déjà présent dans SUBDOMAINS."
    else
        new_compose="$(sed -E 's/^([[:space:]]*- SUBDOMAINS=.*)$/\1,photo/' <<< "$compose")"
        [[ "$new_compose" != "$compose" ]] || die "Ligne SUBDOMAINS introuvable dans le compose de SWAG."

        pct exec "$SWAG_ID" -- bash -c "cp -a /opt/swag/docker-compose.yml /opt/swag/docker-compose.yml.bak.\$(date +%s)"
        b64="$(printf '%s\n' "$new_compose" | base64 -w0)"
        pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/docker-compose.yml"
        info "SWAG : SUBDOMAINS mis à jour (ancienne version sauvegardée en .bak)."
    fi

    conf=/opt/swag/config/nginx/site-confs/photos.conf

    if pct exec "$SWAG_ID" -- grep -qE "server_name .*photo\.${DOMAIN//./\\.}" "$conf" 2>/dev/null; then
        info "SWAG : photos.conf contient déjà l'alias."
    else
        pct exec "$SWAG_ID" -- sed -i -E "s/^([[:space:]]*server_name[[:space:]]+photos\.${DOMAIN//./\\.})[[:space:]]*;/\1 photo.${DOMAIN};/" "$conf" \
            || die "Modification de ${conf} impossible."
        pct exec "$SWAG_ID" -- grep -q "photo\.${DOMAIN//./\\.}" "$conf" \
            || die "server_name de ${conf} non reconnu : ajoute 'photo.${DOMAIN}' à la main."
        info "SWAG : photos.conf mis à jour."
    fi

    swag_regenerate_certs
}

# Redémarre SWAG pour (ré)émettre le certificat. SWAG ne redemande un certificat
# que si la liste des sous-domaines a changé ou si le certificat est absent/proche
# de l'expiration. "force" : sauvegarde puis SUPPRIME le certificat actuel pour
# en obtenir un neuf (attention : limite Let's Encrypt de 5 certificats identiques
# par semaine ; à n'utiliser qu'en cas de certificat cassé).
swag_regenerate_certs() {

    local mode="${1:-}"

    if [[ "$mode" == "force" ]]; then
        warn "Mode force : le certificat actuel va être supprimé puis redemandé (limite : 5 par semaine)."
        swag_backup_certs || true
        pct exec "$SWAG_ID" -- bash -c "rm -rf /opt/swag/config/etc/letsencrypt/live /opt/swag/config/etc/letsencrypt/archive /opt/swag/config/etc/letsencrypt/renewal"
    fi

    info "SWAG : redémarrage et émission du certificat (jusqu'à ~2 min)..."
    pct exec "$SWAG_ID" -- bash -c "cd /opt/swag && docker compose up -d --force-recreate" | tail -n 5

    sleep 60

    pct exec "$SWAG_ID" -- bash -c "docker logs swag 2>&1 | grep -iE 'server ready|successfully|not yet due|error|failed|challenge|unauthorized|timeout' | tail -n 15" || true

    verify_swag_certificate
}

# Ajoute un sous-domaine à SUBDOMAINS du compose de SWAG (sauvegarde .bak, idempotent).
# Usage : swag_ensure_subdomain <sous-domaine>
swag_ensure_subdomain() {

    local sub="$1" compose new_compose b64

    compose="$(pct exec "$SWAG_ID" -- cat /opt/swag/docker-compose.yml 2>/dev/null || true)"
    [[ -n "$compose" ]] || die "docker-compose.yml de SWAG introuvable dans le CT ${SWAG_ID}."

    if grep -qE "SUBDOMAINS=.*(^|,)${sub}(,|\$)" <<< "$compose"; then
        info "SWAG : ${sub} déjà présent dans SUBDOMAINS."
        return 0
    fi

    new_compose="$(sed -E "s/^([[:space:]]*- SUBDOMAINS=.*)\$/\1,${sub}/" <<< "$compose")"
    [[ "$new_compose" != "$compose" ]] || die "Ligne SUBDOMAINS introuvable dans le compose de SWAG."

    pct exec "$SWAG_ID" -- bash -c "cp -a /opt/swag/docker-compose.yml /opt/swag/docker-compose.yml.bak.\$(date +%s)"
    b64="$(printf '%s\n' "$new_compose" | base64 -w0)"
    pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/docker-compose.yml"
    info "SWAG : SUBDOMAINS mis à jour (ancienne version sauvegardée en .bak)."
}

# Branche les serveurs de documents (Collabora / OnlyOffice activés) sur SWAG :
# sous-domaines ajoutés au certificat + confs nginx, redémarrage de SWAG.
repair_swag_add_office() {

    local b64 done_any=false

    if [[ "$ENABLE_COLLABORA" == "true" ]]; then
        swag_ensure_subdomain "$COLLABORA_SUBDOMAIN"
        b64="$(swag_collabora_conf | base64 -w0)"
        pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/config/nginx/site-confs/${COLLABORA_SUBDOMAIN}.conf"
        info "SWAG : ${COLLABORA_SUBDOMAIN}.conf écrit (Collabora)."
        done_any=true
    fi

    if [[ "$ENABLE_ONLYOFFICE" == "true" ]]; then
        swag_ensure_subdomain "$ONLYOFFICE_SUBDOMAIN"
        b64="$(swag_onlyoffice_conf | base64 -w0)"
        pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/config/nginx/site-confs/${ONLYOFFICE_SUBDOMAIN}.conf"
        info "SWAG : ${ONLYOFFICE_SUBDOMAIN}.conf écrit (OnlyOffice)."
        done_any=true
    fi

    [[ "$done_any" == "true" ]] || die "ENABLE_COLLABORA et ENABLE_ONLYOFFICE sont tous deux à false : rien à brancher."

    swag_regenerate_certs
}

# Branche l'application Node (CT NODE) sur SWAG : sous-domaine NODE_SUBDOMAIN
# (défaut "web" -> web.<domaine>) ajouté au certificat + conf nginx, puis
# redémarrage de SWAG (émission automatique du certificat élargi). Idempotent.
repair_swag_add_node() {

    local sub="${NODE_SUBDOMAIN:-}" b64 code

    [[ -n "$sub" ]] || die "NODE_SUBDOMAIN est vide : rien à brancher."
    [[ "$sub" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NODE_SUBDOMAIN='${sub}' invalide."

    info "SWAG : ajout de ${sub}.${DOMAIN} -> NODE (${NODE_IP%%/*}:${NODE_HTTP_PORT})..."

    swag_ensure_subdomain "$sub"

    b64="$(swag_node_conf | base64 -w0)"
    pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/config/nginx/site-confs/${sub}.conf"
    info "SWAG : ${sub}.conf écrit."

    swag_regenerate_certs

    code="$(curl -s -o /dev/null -w '%{http_code} (vérif. certificat : %{ssl_verify_result}, 0 = valide)' \
        --max-time 15 --resolve "${sub}.${DOMAIN}:443:${SWAG_IP%%/*}" "https://${sub}.${DOMAIN}" || true)"

    info "HTTPS ${sub}.${DOMAIN} via SWAG : ${code:-pas de réponse}"
}

# Branche ntfy (CT MONITOR) sur SWAG : NTFY_SUBDOMAIN.<domaine> + certificat. Idempotent.
repair_swag_add_monitor() {

    local sub="${NTFY_SUBDOMAIN:-}" b64

    [[ -n "$sub" ]] || die "NTFY_SUBDOMAIN est vide : rien à brancher."
    [[ "$sub" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NTFY_SUBDOMAIN='${sub}' invalide."

    info "SWAG : ajout de ${sub}.${DOMAIN} -> ntfy (${MONITOR_IP%%/*}:${NTFY_PORT})..."

    swag_ensure_subdomain "$sub"

    b64="$(swag_ntfy_conf | base64 -w0)"
    pct exec "$SWAG_ID" -- bash -c "echo '${b64}' | base64 -d > /opt/swag/config/nginx/site-confs/${sub}.conf"
    info "SWAG : ${sub}.conf écrit."

    swag_regenerate_certs
}

# Ajoute <MAIL_SUBDOMAIN>.<domaine> (nom du serveur mail) au certificat SWAG (SAN),
# puis redémarre SWAG pour l'émettre et recopie le certificat dans le CT MAIL.
repair_swag_add_mail() {

    info "SWAG : ajout de ${MAIL_SUBDOMAIN}.${DOMAIN} au certificat (serveur mail)..."

    swag_ensure_subdomain "$MAIL_SUBDOMAIN"

    swag_regenerate_certs

    if pct status "$MAIL_ID" >/dev/null 2>&1; then
        mail_sync_certs || true
    fi
}

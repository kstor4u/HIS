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
#   ./install.sh --run repair_apps_data_location    # données Immich/Sync-in -> SHARED
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

    if ! grep -q "${DOCKER_SHARED_MOUNT}/${APPS_DATA_SUBDIR}/syncin:/app/data" <<< "$new_compose"; then
        new_compose="$(sed -E \
            "s#^([[:space:]]*)- .*:/app/data[[:space:]]*\$#\\1- ${DOCKER_SHARED_MOUNT}/${APPS_DATA_SUBDIR}/syncin:/app/data\\n\\1- ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:rw#" \
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
    info "Sync-in : connecte-toi, puis Admin > Spaces : ajoute une racine externe ${DOCKER_SHARED_MOUNT}/Family (idem Photo, Movies, Music)."
}

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

# Vérifie (lecture seule) les prérequis Let's Encrypt de SWAG : DNS des 4
# noms du certificat, IPv6, certificat émis, et HTTPS réellement servi.
# Validation "http" = Let's Encrypt doit joindre le port 80 depuis Internet.
check_letsencrypt() {

    local pub_ip name v4 v6 code
    local -a names=("${DOMAIN}" "cloud.${DOMAIN}" "sync.${DOMAIN}" "photos.${DOMAIN}")
    local -a web_names=("cloud.${DOMAIN}" "sync.${DOMAIN}" "photos.${DOMAIN}")

    if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
        names+=("media.${DOMAIN}")
        web_names+=("media.${DOMAIN}")
    fi

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

    info "SWAG : ajout de media.${DOMAIN} -> Jellyfin (${DOCKER_IP%%/*}:${JELLYFIN_HTTP_PORT})..."

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
        --max-time 15 --resolve "media.${DOMAIN}:443:${SWAG_IP%%/*}" "https://media.${DOMAIN}" || true)"

    info "HTTPS media.${DOMAIN} via SWAG : ${code:-pas de réponse}"
    info "Si la vérification n'est pas à 0, relance dans une minute : ./install.sh --run check_letsencrypt"
}

# Déplace les DONNÉES d'applications déjà installées vers SHARED (disque DATA) :
#   - Immich  : photos, miniatures, vidéos encodées -> SHARED/Photo/Immich (monté sur /data)
#   - Sync-in : données internes                    -> SHARED/.apps/syncin
# Les anciennes données ne sont PAS supprimées (à faire à la main après contrôle).
# Les bases de données, caches et configurations restent dans la VM (une base
# sur un partage réseau risque la corruption). Nextcloud n'est pas migré ici.
# Idempotent : une stack déjà migrée est ignorée.
repair_apps_data_location() {

    local VMID="${1:-$DOCKER_ID}"
    local immich_dst="${DOCKER_SHARED_MOUNT}/${IMMICH_UPLOAD_SUBDIR}"
    local syncin_dst="${DOCKER_SHARED_MOUNT}/${APPS_DATA_SUBDIR}/syncin"
    local compose new_compose src_count dst_count

    info "Préparation des dossiers sur SHARED (hôte)..."
    prepare_apps_data_dirs

    # ------------------------------------------------------------ Immich
    compose="$(vm_read_file "$VMID" /opt/apps/immich/docker-compose.yml)"

    if [[ -z "$compose" ]]; then
        warn "Immich : compose introuvable, ignoré."
    elif grep -q "${immich_dst}:/data" <<< "$compose"; then
        info "Immich : déjà sur ${immich_dst}."
    else
        info "Immich : arrêt du serveur (les données restent dans le conteneur)..."
        vm_run "$VMID" 300 "cd /opt/apps/immich && docker compose stop immich-server" | tail -n 3

        info "Immich : volumétrie actuelle (/data = chemin actuel, /usr/src/app/upload = ancien chemin) :"
        vm_run "$VMID" 600 "docker run --rm --volumes-from immich-server --entrypoint sh redis:7-alpine -c 'du -sh /data /usr/src/app/upload 2>&1'"

        [[ -z "$(vm_run "$VMID" 60 "ls -A '${immich_dst}' 2>/dev/null")" ]] \
            || die "Immich : ${immich_dst} n'est pas vide. Vérifie son contenu avant de relancer (rien n'a été modifié)."

        src_count="$(vm_run "$VMID" 600 "docker run --rm --volumes-from immich-server --entrypoint sh redis:7-alpine -c 'find /data -type f 2>/dev/null | wc -l'" | tr -dc '0-9')"

        info "Immich : copie de ${src_count:-0} fichier(s) vers ${immich_dst} (peut durer longtemps)..."
        vm_run "$VMID" 7200 "docker cp -a immich-server:/data/. '${immich_dst}/'" > /dev/null

        dst_count="$(vm_run "$VMID" 600 "find '${immich_dst}' -type f | wc -l" | tr -dc '0-9')"

        [[ "${src_count:-0}" == "${dst_count:-x}" ]] \
            || die "Immich : copie incomplète (${src_count:-0} source, ${dst_count:-?} destination). Compose NON modifié, Immich reste arrêté, tes données d'origine sont intactes. Pour repartir : vide ${immich_dst} (rm -rf ${immich_dst}/.[!.]* ${immich_dst}/*) puis relance './install.sh --run repair_apps_data_location' ; pour annuler : 'cd /opt/apps/immich && docker compose start immich-server'."

        new_compose="$(sed -E \
            -e "s#^([[:space:]]*)- immich_upload:/usr/src/app/upload[[:space:]]*\$#\\1- ${immich_dst}:/data#" \
            -e '/^[[:space:]]*immich_upload:[[:space:]]*$/d' \
            <<< "$compose")"

        grep -q "${immich_dst}:/data" <<< "$new_compose" \
            || die "Immich : ligne de volume attendue introuvable dans le compose (rien modifié, Immich reste arrêté)."

        vm_run "$VMID" 60 "cp -a /opt/apps/immich/docker-compose.yml /opt/apps/immich/docker-compose.yml.bak.\$(date +%s)" > /dev/null
        vm_write_file "$VMID" /opt/apps/immich/docker-compose.yml 0600 "$new_compose"

        info "Immich : redémarrage sur le nouvel emplacement..."
        vm_run "$VMID" 900 "cd /opt/apps/immich && docker compose up -d" | tail -n 8
        sleep 15
        vm_run "$VMID" 60 "docker logs --tail 12 immich-server 2>&1"

        info "Immich : dans l'interface, vérifie que tes photos s'affichent, puis supprime l'ancien conteneur de données (docker volume ls)."
        info "Immich : ajoute l'exclusion **/Immich/** à ta bibliothèque externe (Photo), sinon Immich réimporte ses propres fichiers."
    fi

    # ------------------------------------------------------------ Sync-in
    compose="$(vm_read_file "$VMID" /opt/apps/syncin/docker-compose.yml)"

    if [[ -z "$compose" ]]; then
        info "Sync-in : non installé, ignoré."
    elif grep -q "${syncin_dst}:/app/data" <<< "$compose"; then
        info "Sync-in : déjà sur ${syncin_dst}."
    else
        info "Sync-in : migration des données vers ${syncin_dst}..."
        vm_run "$VMID" 300 "cd /opt/apps/syncin && docker compose stop syncin" | tail -n 3
        vm_run "$VMID" 3600 "if [ -d /opt/apps/syncin/data ]; then cp -a /opt/apps/syncin/data/. '${syncin_dst}/'; fi"

        new_compose="$(sed -E \
            "s#^([[:space:]]*)- /opt/apps/syncin/data:/app/data[[:space:]]*\$#\\1- ${syncin_dst}:/app/data#" \
            <<< "$compose")"

        grep -q "${syncin_dst}:/app/data" <<< "$new_compose" \
            || die "Sync-in : ligne de volume attendue introuvable (rien modifié ; lance d'abord repair_syncin_stack)."

        vm_run "$VMID" 60 "cp -a /opt/apps/syncin/docker-compose.yml /opt/apps/syncin/docker-compose.yml.bak.\$(date +%s)" > /dev/null
        vm_write_file "$VMID" /opt/apps/syncin/docker-compose.yml 0600 "$new_compose"
        vm_run "$VMID" 600 "cd /opt/apps/syncin && docker compose up -d" | tail -n 5
        info "Sync-in : ancien dossier /opt/apps/syncin/data conservé (à supprimer après contrôle)."
    fi

    info "Nextcloud : non migré (ses fichiers sont dans le volume nextcloud_html ; les installations NEUVES utilisent SHARED/${APPS_DATA_SUBDIR}/nextcloud)."
}

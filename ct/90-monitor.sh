###############################################################################
#        SUPERVISION : Uptime Kuma + ntfy + Homepage (CT LXC, Docker)         #
###############################################################################

# Architecture
# ------------
#  - Un CT LXC (MONITOR_ID) sur le bridge privé fait tourner Docker avec jusqu'à trois
#    conteneurs (MONITOR_KUMA / MONITOR_NTFY / MONITOR_HOMEPAGE) :
#      * Uptime Kuma : historique de disponibilité, certificats, pages d'état.
#                      Les moniteurs se créent dans son interface (http://<IP LAN>:KUMA_PORT) ;
#                      ./install.sh --run monitor_list affiche la liste prête à saisir.
#      * ntfy        : serveur de notifications (téléphone/navigateur). Accès refusé par défaut
#                      (auth-default-access: deny-all) ; compte admin + jeton créés ici. Publié
#                      par SWAG sur NTFY_SUBDOMAIN.<domaine> pour recevoir les alertes hors du LAN
#                      (NTFY_SUBDOMAIN="" : pas d'accès Internet, réseau local/VPN seulement).
#      * Homepage    : page d'accueil de tous les services, réservée au LAN (HOMEPAGE_PORT).
#  - L'hôte envoie ses alertes (SMART, disques, services, sauvegardes, restauration, mises à
#    jour) à ntfy par /usr/local/sbin/homelab-notify (host/58-notify.sh).
#  - Données et configuration : /opt/monitor dans le CT (inclus dans vzdump et dans le dump
#    des bases : cible "monitor").

monitor_ntfy_public_url() {

    if [[ -n "$NTFY_SUBDOMAIN" && "$ENABLE_SWAG" == "true" ]]; then
        printf 'https://%s.%s' "$NTFY_SUBDOMAIN" "$DOMAIN"
    else
        printf 'http://%s:%s' "${MONITOR_IP%%/*}" "$NTFY_PORT"
    fi
}

# Jeton ntfy de l'hôte : variable, sinon fichier du CT.
notify_token() {

    if [[ -n "${NOTIFY_NTFY_TOKEN:-}" ]]; then
        printf '%s' "$NOTIFY_NTFY_TOKEN"
    elif [[ "${ENABLE_MONITOR:-false}" == "true" ]] && pct status "$MONITOR_ID" >/dev/null 2>&1; then
        pct exec "$MONITOR_ID" -- cat /opt/monitor/ntfy-token 2>/dev/null || true
    fi
}

# URL d'un service pour Homepage : adresse publique si SWAG, sinon IP LAN de l'hôte + port.
monitor_href() {   # $1 = sous-domaine ("" = aucun)  $2 = port LAN
    if [[ -n "$1" && "$ENABLE_SWAG" == "true" ]]; then
        printf 'https://%s.%s' "$1" "$DOMAIN"
    else
        printf 'http://%s:%s' "$LAN_IP" "$2"
    fi
}

# services.yaml de Homepage, d'après les services réellement installés.
homepage_services_yaml() {

    local dip="${DOCKER_IP%%/*}"

    local files="" media="" home="" infra="" apps=""

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        [[ "${ENABLE_NEXTCLOUD:-true}" == "true" ]] && files+="    - Nextcloud:
        href: $(monitor_href cloud "$NEXTCLOUD_HTTP_PORT")
        description: Fichiers, agenda, contacts
        siteMonitor: http://${dip}:${NEXTCLOUD_HTTP_PORT}/status.php
"
        files+="    - Sync-in:
        href: $(monitor_href sync "$SYNCIN_HTTP_PORT")
        description: Espaces de fichiers partagés
        siteMonitor: http://${dip}:${SYNCIN_HTTP_PORT}/
"
        [[ "$ENABLE_IMMICH" == "true" ]] && media+="    - Immich:
        href: $(monitor_href photos "$IMMICH_HTTP_PORT")
        description: Photos et vidéos
        siteMonitor: http://${dip}:${IMMICH_HTTP_PORT}/api/server/ping
"
        [[ "$ENABLE_JELLYFIN" == "true" ]] && media+="    - Jellyfin:
        href: $(monitor_href media "$JELLYFIN_HTTP_PORT")
        description: Films, séries, musique
        siteMonitor: http://${dip}:${JELLYFIN_HTTP_PORT}/health
"
        if [[ "${ENABLE_ARR:-false}" == "true" ]]; then
            media+="    - Sonarr:
        href: http://${LAN_IP}:${SONARR_PORT}
        description: Séries
        siteMonitor: http://${dip}:${SONARR_PORT}/ping
    - Radarr:
        href: http://${LAN_IP}:${RADARR_PORT}
        description: Films
        siteMonitor: http://${dip}:${RADARR_PORT}/ping
    - Prowlarr:
        href: http://${LAN_IP}:${PROWLARR_PORT}
        description: Indexeurs
        siteMonitor: http://${dip}:${PROWLARR_PORT}/ping
    - qBittorrent:
        href: http://${LAN_IP}:${QBIT_PORT}
        description: Téléchargements (derrière le VPN)
"
        fi
        [[ "$ENABLE_HOMEASSISTANT" == "true" ]] && home+="    - Home Assistant:
        href: http://${LAN_IP}:${HOMEASSISTANT_HTTP_PORT}
        description: Domotique
        siteMonitor: http://${dip}:${HOMEASSISTANT_HTTP_PORT}/
"
    fi

    infra+="    - Proxmox:
        href: https://${LAN_IP}:8006
        description: Hyperviseur
"
    [[ "$ENABLE_FILES" == "true" ]] && infra+="    - Webmin:
        href: https://${LAN_IP}:10000
        description: Administration de la VM FILES
"
    [[ "$ENABLE_DNS" == "true" ]] && infra+="    - AdGuard Home:
        href: http://${LAN_IP}:${DNS_UI_PORT:-80}
        description: DNS filtrant
        siteMonitor: http://${DNS_IP%%/*}/
"
    [[ "$MONITOR_KUMA" == "true" ]] && infra+="    - Uptime Kuma:
        href: http://${LAN_IP}:${KUMA_PORT}
        description: Disponibilité des services
        siteMonitor: http://${MONITOR_IP%%/*}:${KUMA_PORT}/
"
    [[ "$MONITOR_NTFY" == "true" ]] && infra+="    - ntfy:
        href: $(monitor_ntfy_public_url)
        description: Notifications
        siteMonitor: http://${MONITOR_IP%%/*}:${NTFY_PORT}/v1/health
"

    [[ "$ENABLE_NODE" == "true" ]] && apps+="    - Application Node:
        href: $(monitor_href "${NODE_SUBDOMAIN:-}" "$NODE_HTTP_PORT")
        description: Site web (Node.js + MongoDB)
        siteMonitor: http://${NODE_IP%%/*}:${NODE_HTTP_PORT}/
"

    [[ -n "$files" ]] && printf -- '- Fichiers:\n%s\n' "$files"
    [[ -n "$media" ]] && printf -- '- Médias:\n%s\n' "$media"
    [[ -n "$home" ]]  && printf -- '- Maison:\n%s\n' "$home"
    [[ -n "$apps" ]]  && printf -- '- Applications:\n%s\n' "$apps"
    printf -- '- Infrastructure:\n%s' "$infra"
}

# Répare un CT MONITOR déjà créé dont l'installation s'est arrêtée au téléchargement de l'image ntfy
# (ancien nom d'image erroné « binwiederhold/ntfy ») : corrige le compose dans le CT, télécharge,
# démarre, crée le compte/jeton ntfy et vérifie.
# Usage : ./install.sh --run monitor_fix_ntfy_image
monitor_fix_ntfy_image() {

    pct status "$MONITOR_ID" >/dev/null 2>&1 || die "CT ${MONITOR_ID} introuvable : crée-le d'abord (./install.sh)."

    info "MONITOR : correction de l'image ntfy (binwiederhier/ntfy) et démarrage de la stack..."

    pct exec "$MONITOR_ID" -- bash -c '
        set -e
        cd /opt/monitor
        sed -i "s#binwiederhold/ntfy#binwiederhier/ntfy#" docker-compose.yml
        for i in 1 2 3 4; do docker compose pull && break; sleep $((i * 10)); done
        docker compose up -d
        docker compose ps' \
        || die "MONITOR : démarrage de la stack échoué (pct exec ${MONITOR_ID} -- docker compose -f /opt/monitor/docker-compose.yml logs)."

    if [[ "$MONITOR_NTFY" == "true" ]]; then
        monitor_ntfy_bootstrap || warn "MONITOR : compte/jeton ntfy non créés (voir ./install.sh --run monitor_ntfy_bootstrap)."
    fi

    verify_monitor
}

create_monitor_ct() {

    if pct status "$MONITOR_ID" >/dev/null 2>&1; then

        warn "CT ${MONITOR_ID} existe déjà. Création MONITOR ignorée."

        return 0
    fi

    [[ -n "$NTFY_ADMIN_PASSWORD" ]] \
        || NTFY_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"

    [[ -n "$NTFY_ADMIN_PASSWORD" ]] || die "Échec de génération de NTFY_ADMIN_PASSWORD."

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT MONITOR ${MONITOR_ID}..."

    pct create "$MONITOR_ID" \
        "$TEMPLATE" \
        --hostname "$MONITOR_HOSTNAME" \
        --cores "$MONITOR_CORES" \
        --memory "$MONITOR_MEMORY" \
        --swap 512 \
        --rootfs "${GUEST_STORAGE}:${MONITOR_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${MONITOR_GATEWAY},ip=${MONITOR_IP}" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$MONITOR_ID"

    pct_wait_for_network "$MONITOR_ID"

    local WORK
    WORK="$(mktemp -d)"

    local allowed="${LAN_IP}:${HOMEPAGE_PORT},${MONITOR_IP%%/*}:3000,localhost:3000"
    local hp
    for hp in $(sd_fqdns HOMEPAGE_SUBDOMAIN); do allowed+=",${hp}"; done

    # --- docker-compose.yml : seulement les services choisis ---
    {
        echo "services:"
        if [[ "$MONITOR_KUMA" == "true" ]]; then
            cat <<EOF
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - /opt/monitor/kuma:/app/data
    ports:
      - "${KUMA_PORT}:3001"
EOF
        fi
        if [[ "$MONITOR_NTFY" == "true" ]]; then
            cat <<EOF
  ntfy:
    image: binwiederhier/ntfy:latest
    container_name: ntfy
    restart: unless-stopped
    command: ["serve"]
    environment:
      - TZ=Europe/Paris
    volumes:
      - /opt/monitor/ntfy/etc:/etc/ntfy
      - /opt/monitor/ntfy/cache:/var/cache/ntfy
      - /opt/monitor/ntfy/lib:/var/lib/ntfy
    ports:
      - "${NTFY_PORT}:80"
EOF
        fi
        if [[ "$MONITOR_HOMEPAGE" == "true" ]]; then
            cat <<EOF
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    environment:
      - PUID=0
      - PGID=0
      - TZ=Europe/Paris
      - HOMEPAGE_ALLOWED_HOSTS=${allowed}
    volumes:
      - /opt/monitor/homepage:/app/config
    ports:
      - "${HOMEPAGE_PORT}:3000"
EOF
        fi
    } > "${WORK}/docker-compose.yml"

    # --- ntfy : configuration du serveur ---
    cat > "${WORK}/ntfy-server.yml" <<EOF
base-url: "$(monitor_ntfy_public_url)"
listen-http: ":80"
cache-file: "/var/cache/ntfy/cache.db"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: true
# Relais ntfy.sh : ne transmet que l'identifiant du message pour réveiller l'application iOS.
upstream-base-url: "https://ntfy.sh"
EOF

    # --- Homepage : configuration initiale (jamais écrasée ensuite) ---
    cat > "${WORK}/settings.yaml" <<EOF
title: Homelab
theme: dark
color: slate
language: fr
headerStyle: clean
EOF
    cat > "${WORK}/widgets.yaml" <<EOF
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
      hourCycle: h23
EOF
    homepage_services_yaml > "${WORK}/services.yaml"
    : > "${WORK}/bookmarks.yaml"

    printf '%s\n' "$NTFY_ADMIN_PASSWORD" > "${WORK}/ntfy-pass"

    cat > "${WORK}/install-monitor.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

# Affiche la commande qui échoue (sinon l'hôte ne voit que « bash install-monitor.sh »)
trap 'echo "MONITOR : échec à la ligne $LINENO : $BASH_COMMAND" >&2' ERR

# Réessaie une commande réseau (DNS/miroir/registre momentanément indisponible)
retry() {
    local i
    for i in 1 2 3 4; do
        "$@" && return 0
        echo "MONITOR : tentative $i/4 échouée : $*" >&2
        sleep $((i * 10))
    done
    return 1
}

retry apt-get update
retry apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
retry curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<'DOCKER_EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF

retry apt-get update
retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

mkdir -p /opt/monitor/kuma /opt/monitor/ntfy/etc /opt/monitor/ntfy/cache /opt/monitor/ntfy/lib /opt/monitor/homepage
mv -f /root/monitor-compose.yml /opt/monitor/docker-compose.yml
mv -f /root/ntfy-server.yml /opt/monitor/ntfy/etc/server.yml
mv -f /root/ntfy-pass /opt/monitor/ntfy-admin-pass
chmod 600 /opt/monitor/ntfy-admin-pass

for f in settings services widgets bookmarks; do
    [[ -f "/opt/monitor/homepage/${f}.yaml" ]] || mv "/root/hp-${f}.yaml" "/opt/monitor/homepage/${f}.yaml"
done
rm -f /root/hp-*.yaml

cd /opt/monitor
retry docker compose pull
retry docker compose up -d
docker compose ps
EOF_INSTALL

    pct push "$MONITOR_ID" "${WORK}/docker-compose.yml" /root/monitor-compose.yml
    pct push "$MONITOR_ID" "${WORK}/ntfy-server.yml"    /root/ntfy-server.yml
    pct push "$MONITOR_ID" "${WORK}/ntfy-pass"          /root/ntfy-pass --perms 0600
    pct push "$MONITOR_ID" "${WORK}/settings.yaml"      /root/hp-settings.yaml
    pct push "$MONITOR_ID" "${WORK}/services.yaml"      /root/hp-services.yaml
    pct push "$MONITOR_ID" "${WORK}/widgets.yaml"       /root/hp-widgets.yaml
    pct push "$MONITOR_ID" "${WORK}/bookmarks.yaml"     /root/hp-bookmarks.yaml

    pct_push_script "$MONITOR_ID" "${WORK}/install-monitor.sh" /root/install-monitor.sh

    rm -rf "$WORK"

    pct exec "$MONITOR_ID" -- bash /root/install-monitor.sh \
        || die "MONITOR : l'installation dans le CT ${MONITOR_ID} a échoué (cause juste au-dessus ; réessaie : ./install.sh --run create_monitor_ct ; vérifie le réseau du CT : pct exec ${MONITOR_ID} -- ping -c2 deb.debian.org)."

    if [[ "$MONITOR_NTFY" == "true" ]]; then
        monitor_ntfy_bootstrap || warn "MONITOR : compte/jeton ntfy non créés (voir ./install.sh --run monitor_ntfy_bootstrap)."
    fi

    info "MONITOR installé dans le CT ${MONITOR_ID}."

    verify_monitor
}

# Crée le compte admin ntfy et un jeton d'accès pour l'hôte (écrit dans /opt/monitor/ntfy-token).
# Idempotent : réutilise le compte et le jeton existants.
monitor_ntfy_bootstrap() {

    local pass tok

    pass="$(pct exec "$MONITOR_ID" -- cat /opt/monitor/ntfy-admin-pass 2>/dev/null | head -n 1 || true)"
    [[ -n "$pass" ]] || die "Mot de passe admin ntfy introuvable dans le CT ${MONITOR_ID}."

    local attempt
    for attempt in $(seq 1 20); do
        pct exec "$MONITOR_ID" -- docker exec ntfy ntfy --help >/dev/null 2>&1 && break
        sleep 3
    done

    if ! pct exec "$MONITOR_ID" -- docker exec ntfy ntfy user list 2>/dev/null | grep -q "user ${NTFY_ADMIN_USER} "; then
        pct exec "$MONITOR_ID" -- docker exec -e "NTFY_PASSWORD=${pass}" ntfy ntfy user add --role=admin "$NTFY_ADMIN_USER" >/dev/null
        info "ntfy : compte admin '${NTFY_ADMIN_USER}' créé."
    fi

    tok="$(pct exec "$MONITOR_ID" -- cat /opt/monitor/ntfy-token 2>/dev/null || true)"

    if [[ -z "$tok" ]]; then
        tok="$(pct exec "$MONITOR_ID" -- docker exec ntfy ntfy token add --label=homelab-host "$NTFY_ADMIN_USER" 2>&1 | grep -o 'tk_[a-z0-9]*' | head -n 1 || true)"
        [[ -n "$tok" ]] || die "Jeton ntfy non obtenu."
        pct exec "$MONITOR_ID" -- bash -c "umask 077; printf '%s' '${tok}' > /opt/monitor/ntfy-token"
        info "ntfy : jeton d'accès créé pour l'hôte."
    fi

    NOTIFY_NTFY_TOKEN="$tok"
}

# Contrôle : Kuma / ntfy / Homepage répondent.
verify_monitor() {

    local attempt code name url

    for entry in \
        "Uptime Kuma|${MONITOR_KUMA}|http://${MONITOR_IP%%/*}:${KUMA_PORT}/" \
        "ntfy|${MONITOR_NTFY}|http://${MONITOR_IP%%/*}:${NTFY_PORT}/v1/health" \
        "Homepage|${MONITOR_HOMEPAGE}|http://${MONITOR_IP%%/*}:${HOMEPAGE_PORT}/"; do

        IFS='|' read -r name on url <<< "$entry"
        [[ "$on" == "true" ]] || continue

        code=""
        for attempt in $(seq 1 18); do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
            [[ "$code" =~ ^(200|301|302|307|401)$ ]] && break
            sleep 5
        done

        if [[ "$code" =~ ^(200|301|302|307|401)$ ]]; then
            info "MONITOR : ${name} répond (HTTP ${code})."
        else
            warn "MONITOR : ${name} ne répond pas (${url}, dernier code : ${code:-aucun}). Diagnostic : ./install.sh --run monitor_logs"
        fi
    done

    return 0
}

# Moniteurs à créer dans Uptime Kuma (nom | type | adresse), d'après les services installés.
monitor_list() {

    echo "Moniteurs suggérés pour Uptime Kuma (Ajouter un moniteur) :"
    echo

    local name url
    while IFS='|' read -r name url; do
        [[ -n "$name" ]] || continue
        printf '  %-22s HTTP(s)  %s\n' "$name" "$url"
    done < <(health_url_list)

    if [[ "$ENABLE_SWAG" == "true" ]]; then
        local s
        for s in cloud sync photos media; do
            printf '  %-22s HTTP(s)  https://%s.%s   (+ expiration du certificat)\n' "Public ${s}" "$s" "$DOMAIN"
        done
    fi

    [[ "$ENABLE_MAIL" == "true" ]] && printf '  %-22s TCP      %s:587 / :993\n' "Mail" "${MAIL_IP%%/*}"
    [[ "$ENABLE_DNS" == "true" ]] && printf '  %-22s DNS      %s:53 (résoudre example.com)\n' "DNS" "${DNS_IP%%/*}"

    echo
    echo "Moniteur « Push » (alerte si l'hôte cesse d'envoyer son battement de cœur) :"
    echo "  1. Kuma : Ajouter un moniteur > type Push, intervalle 900 s (l'hôte envoie toutes les 10 min)."
    echo "  2. Copie l'URL de push dans NOTIFY_KUMA_PUSH_URL (fichier de réponses), puis ./install.sh --run configure_notify"
    echo
    echo "Notifications Kuma : Paramètres > Notifications > ntfy ; serveur $(monitor_ntfy_public_url), sujet ${NOTIFY_NTFY_TOPIC}, authentification : jeton (voir le résumé)."
}

# Régénère le services.yaml de Homepage (remplace l'actuel, sauvegarde en .bak).
monitor_homepage_regen() {

    local b64
    b64="$(homepage_services_yaml | base64 -w0)"
    pct exec "$MONITOR_ID" -- bash -c "cd /opt/monitor/homepage && cp -a services.yaml services.yaml.bak.\$(date +%s) 2>/dev/null; echo '${b64}' | base64 -d > services.yaml"
    info "Homepage : services.yaml régénéré (ancien fichier sauvegardé en .bak)."
}

monitor_logs() {
    pct exec "$MONITOR_ID" -- bash -c "cd /opt/monitor && docker compose ps && docker compose logs --tail 20"
}

monitor_restart() {
    pct exec "$MONITOR_ID" -- bash -c "cd /opt/monitor && docker compose restart"
}

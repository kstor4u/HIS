###############################################################################
#                              SWAG                                           #
###############################################################################

# Conf nginx SWAG des sous-domaines JELLYFIN_SUBDOMAIN -> Jellyfin (affichée sur stdout).
swag_media_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns JELLYFIN_SUBDOMAIN);

    include /config/nginx/ssl.conf;

    client_max_body_size 0;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${JELLYFIN_HTTP_PORT};
    }
}
CONF
}

# Conf nginx SWAG du sous-domaine NODE_SUBDOMAIN -> application Node (CT NODE).
swag_node_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns NODE_SUBDOMAIN);

    include /config/nginx/ssl.conf;

    client_max_body_size 100M;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${NODE_IP%%/*}:${NODE_HTTP_PORT};
    }
}
CONF
}

# Répare/valide les confs nginx de SWAG : le proxy.conf des versions récentes définit déjà
# proxy_read_timeout / proxy_send_timeout ; les redéfinir dans une conf de site fait
# refuser nginx ("directive is duplicate") et TOUS les sites tombent en timeout.
# Usage : ./install.sh --run swag_nginx_fix
swag_nginx_fix() {
    info "SWAG : suppression des timeouts en double dans les confs de sites, test et rechargement de nginx..."
    pct exec "$SWAG_ID" -- bash -c '
        docker exec swag sh -c "sed -i -E \"/^[[:space:]]*proxy_(read|send)_timeout[[:space:]]/d\" /config/nginx/site-confs/*.conf" || true
        docker exec swag nginx -t' \
        || die "SWAG : nginx refuse encore la configuration (voir le message ci-dessus ; pct exec ${SWAG_ID} -- docker exec swag nginx -t)."
    pct exec "$SWAG_ID" -- docker restart swag >/dev/null
    info "SWAG : configuration nginx valide, conteneur redémarré."
}

# Conf nginx SWAG de ntfy (notifications) : connexions longues (SSE/WebSocket), sans mise en tampon.
swag_ntfy_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns NTFY_SUBDOMAIN);

    include /config/nginx/ssl.conf;

    client_max_body_size 20M;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${MONITOR_IP%%/*}:${NTFY_PORT};
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
CONF
}

# Confs nginx SWAG des serveurs de documents (Collabora / OnlyOffice).
# Pas de "$" ici (heredoc non protégé) : les en-têtes WebSocket viennent de proxy.conf.
swag_collabora_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns COLLABORA_SUBDOMAIN);

    include /config/nginx/ssl.conf;

    client_max_body_size 100M;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${COLLABORA_HTTP_PORT};
    }
}
CONF
}

swag_onlyoffice_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns ONLYOFFICE_SUBDOMAIN);

    include /config/nginx/ssl.conf;

    client_max_body_size 100M;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${ONLYOFFICE_HTTP_PORT};
    }
}
CONF
}

# Confs nginx des applications Docker (Nextcloud, Sync-in, Immich) : une conf par service, plusieurs noms possibles.
swag_app_conf() {   # $1 = variable de sous-domaine, $2 = port, $3 = taille max du corps
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $(sd_fqdns "$1");

    include /config/nginx/ssl.conf;

    client_max_body_size $3;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:$2;
    }
}
CONF
}

# Texte shell qui écrit TOUTES les confs de SWAG selon les services actifs et les sous-domaines choisis.
# Utilisé à l'installation et par repair_swag_subdomains. Les fichiers cloud/sync/photos/media gardent
# leur nom (continuité des installations existantes) ; node, ntfy, collabora et onlyoffice portent leur nom principal.
swag_conf_blocks() {

    local out="" f

    out+="cat > /opt/swag/config/nginx/site-confs/cloud.conf <<'CONF_EOF'
$(swag_app_conf NEXTCLOUD_SUBDOMAIN "$NEXTCLOUD_HTTP_PORT" 0)
CONF_EOF

cat > /opt/swag/config/nginx/site-confs/sync.conf <<'CONF_EOF'
$(swag_app_conf SYNCIN_SUBDOMAIN "$SYNCIN_HTTP_PORT" 0)
CONF_EOF

cat > /opt/swag/config/nginx/site-confs/photos.conf <<'CONF_EOF'
$(swag_app_conf IMMICH_SUBDOMAIN "$IMMICH_HTTP_PORT" 50000M)
CONF_EOF

"

    if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
        out+="cat > /opt/swag/config/nginx/site-confs/media.conf <<'CONF_EOF'
$(swag_media_conf)
CONF_EOF
"
    fi

    if [[ "$ENABLE_COLLABORA" == "true" ]]; then
        out+="cat > /opt/swag/config/nginx/site-confs/${COLLABORA_SUBDOMAIN}.conf <<'CONF_EOF'
$(swag_collabora_conf)
CONF_EOF
"
    fi

    if [[ "$ENABLE_ONLYOFFICE" == "true" ]]; then
        out+="cat > /opt/swag/config/nginx/site-confs/${ONLYOFFICE_SUBDOMAIN}.conf <<'CONF_EOF'
$(swag_onlyoffice_conf)
CONF_EOF
"
    fi

    if [[ "$ENABLE_NODE" == "true" && -n "$NODE_SUBDOMAIN" ]]; then
        out+="cat > /opt/swag/config/nginx/site-confs/${NODE_SUBDOMAIN}.conf <<'CONF_EOF'
$(swag_node_conf)
CONF_EOF
"
    fi

    if [[ "${ENABLE_MONITOR:-false}" == "true" && "$MONITOR_NTFY" == "true" && -n "$NTFY_SUBDOMAIN" ]]; then
        out+="cat > /opt/swag/config/nginx/site-confs/${NTFY_SUBDOMAIN}.conf <<'CONF_EOF'
$(swag_ntfy_conf)
CONF_EOF
"
    fi

    printf '%s' "$out"
}

# Vérifie que Let's Encrypt a bien émis le certificat. Si l'émission échoue,
# SWAG démarre quand même avec un certificat AUTO-SIGNÉ (Firefox affiche
# MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT) : sans cette vérification l'échec
# reste silencieux. N'interrompt jamais l'installation (simple avertissement).
# Utilisable seule : ./install.sh --run verify_swag_certificate
verify_swag_certificate() {

    local attempt

    info "SWAG : attente de l'émission du certificat Let's Encrypt (jusqu'à 3 min)..."

    for ((attempt = 1; attempt <= 18; attempt++)); do

        if pct exec "$SWAG_ID" -- bash -c "docker exec swag openssl x509 -noout -issuer -in /config/etc/letsencrypt/live/${DOMAIN}/fullchain.pem 2>/dev/null | grep -qi \"Let's Encrypt\""; then
            info "SWAG : certificat Let's Encrypt émis pour ${DOMAIN} (et ses sous-domaines)."

            # Sauvegarde sur l'hôte : permet de réinstaller sans redemander de certificat.
            if declare -F swag_backup_certs >/dev/null; then
                swag_backup_certs || true
            fi

            return 0
        fi

        sleep 10
    done

    warn "SWAG : AUCUN certificat Let's Encrypt émis : SWAG sert un certificat auto-signé."
    warn "Raison probable (journaux SWAG) :"

    pct exec "$SWAG_ID" -- bash -c "
        docker logs swag 2>&1 | grep -iE 'error|failed|challenge|unauthorized|timeout|caa|too many|rate limit|retry after|invalid' | tail -n 12
        docker exec swag tail -n 60 /config/log/letsencrypt/letsencrypt.log 2>/dev/null | grep -iE 'detail|problem|too many|caa|retry after' | tail -n 8
    " || true

    warn "À vérifier : enregistrements A (${DOMAIN}, $(subdomain_hosts_csv | sed 's/,/, /g')), redirection TCP 80 ET 443 de la box vers ${LAN_IP}."
    warn "Après correction : pct exec ${SWAG_ID} -- docker restart swag  (puis ./install.sh --run verify_swag_certificate)."
    warn "Rappel : Let's Encrypt limite à 5 échecs/heure et 5 certificats identiques/semaine (réinstallations répétées)."

    return 0
}

create_swag_ct() {

    if pct status "$SWAG_ID" >/dev/null 2>&1; then

        warn "CT ${SWAG_ID} existe déjà. Création SWAG ignorée."

        return 0
    fi

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT SWAG ${SWAG_ID}..."

    pct create "$SWAG_ID" \
        "$TEMPLATE" \
        --hostname "$SWAG_HOSTNAME" \
        --cores "$SWAG_CORES" \
        --memory "$SWAG_MEMORY" \
        --swap 512 \
        --rootfs "${GUEST_STORAGE}:${SWAG_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${SWAG_GATEWAY},ip=${SWAG_IP}" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$SWAG_ID"

    pct_wait_for_network "$SWAG_ID"

    local SCRIPT
    SCRIPT="$(mktemp)"

    # Sous-domaines du certificat et confs nginx : voir core/35-subdomains.sh
    local SWAG_SUBDOMAINS SWAG_CONF_BLOCKS
    SWAG_SUBDOMAINS="$(subdomain_hosts_csv)"
    SWAG_CONF_BLOCKS="$(swag_conf_blocks)"

    cat > "$SCRIPT" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<'DOCKER_EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF

apt-get update

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

mkdir -p /opt/swag

cat > /opt/swag/docker-compose.yml <<'COMPOSE_EOF'
services:
  swag:
    image: lscr.io/linuxserver/swag:latest
    container_name: swag
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      - PUID=0
      - PGID=0
      - TZ=Europe/Paris
      - URL=${DOMAIN}
      - SUBDOMAINS=${SWAG_SUBDOMAINS}
      - VALIDATION=http
      - EMAIL=${LE_EMAIL}
      - STAGING=false
    volumes:
      - /opt/swag/config:/config
    ports:
      - "80:80"
      - "443:443"
COMPOSE_EOF

cd /opt/swag

docker compose pull
docker compose up -d

for attempt in \$(seq 1 30); do

    if [[ -d /opt/swag/config/nginx/site-confs ]]; then
        break
    fi

    sleep 2
done

[[ -d /opt/swag/config/nginx/site-confs ]] \
    || { echo "ERREUR: /opt/swag/config/nginx/site-confs absent, confs reverse-proxy non générées."; exit 1; }

${SWAG_CONF_BLOCKS}
docker compose restart swag

docker compose ps
EOF

    pct_push_script \
        "$SWAG_ID" \
        "$SCRIPT" \
        "/root/install-swag.sh"

    pct exec "$SWAG_ID" -- \
        bash /root/install-swag.sh

    rm -f "$SCRIPT"

    info "SWAG installé dans le CT ${SWAG_ID}."

    verify_swag_certificate
}


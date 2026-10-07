###############################################################################
#                              SWAG                                           #
###############################################################################

# Conf nginx SWAG du sous-domaine media -> Jellyfin (affichée sur stdout).
swag_media_conf() {
    cat <<CONF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name media.${DOMAIN};

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

    warn "À vérifier : enregistrements A (${DOMAIN}, cloud, sync, photos), redirection TCP 80 ET 443 de la box vers ${LAN_IP}."
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
        --rootfs "local-lvm:${SWAG_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${SWAG_GATEWAY},ip=${SWAG_IP}" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$SWAG_ID"

    pct_wait_for_network "$SWAG_ID"

    local SCRIPT
    SCRIPT="$(mktemp)"

    # Sous-domaines du certificat : media (Jellyfin) seulement s'il est activé.
    local SWAG_SUBDOMAINS="cloud,sync,photos"
    local MEDIA_BLOCK=""

    if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
        SWAG_SUBDOMAINS+=",media"
        MEDIA_BLOCK="cat > /opt/swag/config/nginx/site-confs/media.conf <<'CONF_EOF'
$(swag_media_conf)
CONF_EOF
"
    fi

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

cat > /opt/swag/config/nginx/site-confs/cloud.conf <<'CONF_EOF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name cloud.${DOMAIN};

    include /config/nginx/ssl.conf;

    client_max_body_size 0;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${NEXTCLOUD_HTTP_PORT};
    }
}
CONF_EOF

cat > /opt/swag/config/nginx/site-confs/sync.conf <<'CONF_EOF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name sync.${DOMAIN};

    include /config/nginx/ssl.conf;

    client_max_body_size 0;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${SYNCIN_HTTP_PORT};
    }
}
CONF_EOF

cat > /opt/swag/config/nginx/site-confs/photos.conf <<'CONF_EOF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name photos.${DOMAIN};

    include /config/nginx/ssl.conf;

    client_max_body_size 50000M;

    location / {
        include /config/nginx/proxy.conf;
        include /config/nginx/resolver.conf;
        proxy_pass http://${DOCKER_IP%%/*}:${IMMICH_HTTP_PORT};
    }
}
CONF_EOF

${MEDIA_BLOCK}docker compose restart swag

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


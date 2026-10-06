###############################################################################
#                              SWAG                                           #
###############################################################################

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
      - SUBDOMAINS=cloud,sync,photos
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
}


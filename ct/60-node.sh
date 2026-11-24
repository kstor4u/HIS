###############################################################################
#                     NODE.JS + MONGODB (CT LXC, Docker)                      #
###############################################################################

# Architecture
# ------------
#  - Un CT LXC (NODE_ID) sur le bridge privé fait tourner Docker avec deux
#    conteneurs : "mongo" (MongoDB, authentification activée, accessible
#    uniquement par le conteneur node, sauf NODE_MONGO_EXPOSE=true) et "node"
#    (Node.js LTS, écoute NODE_HTTP_PORT).
#  - Ton application vit dans le CT, dossier /opt/node/app (server.js,
#    package.json). Au démarrage, le conteneur fait "npm install" puis
#    "node server.js". Une application d'exemple (connexion MongoDB testée sur
#    /health) est déposée à la première installation et jamais écrasée ensuite.
#  - Les données MongoDB sont dans /opt/node/mongo-data (disque du CT : une base
#    sur un partage réseau/virtiofs risque la corruption). Sauvegarde :
#    ./install.sh --run node_backup_mongo
#  - Identifiants : /opt/node/.env dans le CT (fichier 0600).

generate_node_secrets() {

    [[ -n "$MONGO_ADMIN_PASSWORD" ]] \
        || MONGO_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"

    [[ -n "$MONGO_ADMIN_PASSWORD" ]] || die "Échec de génération de MONGO_ADMIN_PASSWORD."
}

create_node_ct() {

    if pct status "$NODE_ID" >/dev/null 2>&1; then

        warn "CT ${NODE_ID} existe déjà. Création NODE ignorée."

        return 0
    fi

    generate_node_secrets

    # MongoDB >= 5 exige un CPU avec AVX (un CT utilise le CPU de l'hôte).
    if ! grep -qw avx /proc/cpuinfo && [[ "$MONGO_IMAGE" != mongo:4* ]]; then
        warn "Le CPU de l'hôte n'annonce pas AVX : MongoDB 5+ ne démarrera pas. Mets MONGO_IMAGE=\"mongo:4.4\" dans le fichier de réponses."
    fi

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT NODE ${NODE_ID}..."

    pct create "$NODE_ID" \
        "$TEMPLATE" \
        --hostname "$NODE_HOSTNAME" \
        --cores "$NODE_CORES" \
        --memory "$NODE_MEMORY" \
        --swap 512 \
        --rootfs "${GUEST_STORAGE}:${NODE_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${NODE_GATEWAY},ip=${NODE_IP}" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$NODE_ID"

    pct_wait_for_network "$NODE_ID"

    local WORK
    WORK="$(mktemp -d)"

    # --- .env (secrets) ---
    {
        printf 'MONGO_IMAGE=%s\n' "$MONGO_IMAGE"
        printf 'MONGO_ADMIN_USER=%s\n' "$MONGO_ADMIN_USER"
        printf 'MONGO_ADMIN_PASSWORD=%s\n' "$MONGO_ADMIN_PASSWORD"
        printf 'MONGO_DB=%s\n' "$MONGO_DB"
        printf 'NODE_HTTP_PORT=%s\n' "$NODE_HTTP_PORT"
        if [[ "$NODE_MONGO_EXPOSE" == "true" ]]; then
            printf 'MONGO_BIND=%s:27017\n' "${NODE_IP%%/*}"
        else
            printf 'MONGO_BIND=127.0.0.1:27017\n'
        fi
    } > "${WORK}/env"

    # --- docker-compose.yml ---
    cat > "${WORK}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  mongo:
    image: ${MONGO_IMAGE}
    container_name: mongo
    restart: unless-stopped
    environment:
      - MONGO_INITDB_ROOT_USERNAME=${MONGO_ADMIN_USER}
      - MONGO_INITDB_ROOT_PASSWORD=${MONGO_ADMIN_PASSWORD}
      # MongoDB 8 refuse de démarrer sur un noyau Linux >= 6.19 (SERVER-121912, conflit rseq TCMalloc/glibc) ;
      # le noyau est celui de l'hôte Proxmox. Sans effet sur les anciens noyaux.
      - GLIBC_TUNABLES=glibc.pthread.rseq=1
    volumes:
      - /opt/node/mongo-data:/data/db
    ports:
      - "${MONGO_BIND}:27017"
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet --eval \"db.adminCommand('ping').ok\" || mongo --quiet --eval \"db.adminCommand('ping').ok\""]
      interval: 10s
      timeout: 10s
      retries: 12
      start_period: 20s

  node:
    image: node:lts-slim
    container_name: node
    restart: unless-stopped
    depends_on:
      mongo:
        condition: service_healthy
    working_dir: /app
    environment:
      - NODE_ENV=production
      - PORT=3000
      - MONGO_HOST=mongo
      - MONGO_USER=${MONGO_ADMIN_USER}
      - MONGO_PASSWORD=${MONGO_ADMIN_PASSWORD}
      - MONGO_DB=${MONGO_DB}
    volumes:
      - /opt/node/app:/app
    ports:
      - "${NODE_HTTP_PORT}:3000"
    command: ["sh", "-c", "npm install --omit=dev --no-audit --no-fund && node server.js"]
COMPOSE_EOF

    # --- application d'exemple ---
    cat > "${WORK}/package.json" <<'PKG_EOF'
{
  "name": "homelab-node-app",
  "version": "1.0.0",
  "private": true,
  "main": "server.js",
  "dependencies": {
    "mongodb": "^6.0.0"
  }
}
PKG_EOF

    cat > "${WORK}/server.js" <<'JS_EOF'
// Application d'exemple : remplace ce fichier par ton application.
// Variables fournies : PORT, MONGO_HOST, MONGO_USER, MONGO_PASSWORD, MONGO_DB.
const http = require('http');
const { MongoClient } = require('mongodb');

const url = `mongodb://${encodeURIComponent(process.env.MONGO_USER)}:${encodeURIComponent(process.env.MONGO_PASSWORD)}@${process.env.MONGO_HOST}:27017/?authSource=admin`;
const client = new MongoClient(url);

async function main() {
  await client.connect();
  const db = client.db(process.env.MONGO_DB);

  http.createServer(async (req, res) => {
    try {
      if (req.url === '/health') {
        await db.command({ ping: 1 });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ node: process.version, mongo: 'ok' }));
      }
      const visits = db.collection('visits');
      await visits.insertOne({ at: new Date(), path: req.url });
      const count = await visits.countDocuments();
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(`Node ${process.version} + MongoDB : OK (${count} visites enregistrées)\n`);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('Erreur : ' + e.message + '\n');
    }
  }).listen(process.env.PORT || 3000, () => console.log('Écoute sur le port ' + (process.env.PORT || 3000)));
}

main().catch((e) => { console.error(e); process.exit(1); });
JS_EOF

    # --- script d'installation exécuté dans le CT ---
    cat > "${WORK}/install-node.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<'DOCKER_EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

mkdir -p /opt/node/app /opt/node/mongo-data
mv /root/node-env /opt/node/.env
mv /root/node-compose.yml /opt/node/docker-compose.yml
chmod 600 /opt/node/.env

# Application d'exemple : jamais d'écrasement d'une application existante.
[[ -f /opt/node/app/server.js ]]   || mv /root/node-server.js /opt/node/app/server.js
[[ -f /opt/node/app/package.json ]] || mv /root/node-package.json /opt/node/app/package.json
rm -f /root/node-server.js /root/node-package.json

cd /opt/node
docker compose pull
docker compose up -d
docker compose ps
EOF_INSTALL

    pct push "$NODE_ID" "${WORK}/env"                /root/node-env --perms 0600
    pct push "$NODE_ID" "${WORK}/docker-compose.yml" /root/node-compose.yml
    pct push "$NODE_ID" "${WORK}/server.js"          /root/node-server.js
    pct push "$NODE_ID" "${WORK}/package.json"       /root/node-package.json

    pct_push_script "$NODE_ID" "${WORK}/install-node.sh" /root/install-node.sh

    rm -rf "$WORK"

    pct exec "$NODE_ID" -- bash /root/install-node.sh

    info "NODE installé dans le CT ${NODE_ID} : http://${NODE_IP%%/*}:${NODE_HTTP_PORT}"

    verify_node
}

# Contrôle l'état : conteneurs démarrés et page d'exemple/application joignable.
verify_node() {

    local attempt code

    for attempt in $(seq 1 18); do

        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${NODE_IP%%/*}:${NODE_HTTP_PORT}/health" || true)"

        if [[ "$code" == "200" ]]; then
            info "NODE : application joignable, MongoDB répond (HTTP 200 sur /health)."
            return 0
        fi

        sleep 10
    done

    warn "NODE : /health ne répond pas encore (dernier code : ${code:-aucun}). Si tu as remplacé l'application d'exemple, c'est normal."
    pct exec "$NODE_ID" -- bash -c "cd /opt/node && docker compose ps && docker compose logs --tail 15" || true

    return 0
}

# Sauvegarde logique de MongoDB (mongodump compressé) vers ${APPS_DIR}/backups,
# donc sur le disque DATA. Usage : ./install.sh --run node_backup_mongo
node_backup_mongo() {

    local dest="${APPS_DIR}/backups"
    local stamp file

    stamp="$(date +%Y%m%d-%H%M%S)"
    file="mongo-${stamp}.archive.gz"

    mkdir -p "$dest"

    pct exec "$NODE_ID" -- bash -c "
        set -e
        cd /opt/node
        set -a; . ./.env; set +a
        docker exec mongo mongodump --username \"\$MONGO_ADMIN_USER\" --password \"\$MONGO_ADMIN_PASSWORD\" \
            --authenticationDatabase admin --archive=/tmp/${file} --gzip
        docker cp mongo:/tmp/${file} /root/${file}
        docker exec mongo rm -f /tmp/${file}
    "

    pct pull "$NODE_ID" "/root/${file}" "${dest}/${file}"
    pct exec "$NODE_ID" -- rm -f "/root/${file}"
    chmod 600 "${dest}/${file}"

    info "MongoDB sauvegardé : ${dest}/${file} (contient les données : ne le diffuse pas)."
}

# Redémarre l'application (après modification de /opt/node/app).
# Corrige « MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility »
# sur un CT NODE déjà créé : ajoute GLIBC_TUNABLES au docker-compose.yml puis relance la pile.
# Usage : ./install.sh --run node_fix_mongo_kernel
node_fix_mongo_kernel() {

    pct status "$NODE_ID" >/dev/null 2>&1 || die "CT NODE ${NODE_ID} introuvable."

    if pct exec "$NODE_ID" -- grep -q 'GLIBC_TUNABLES' /opt/node/docker-compose.yml; then
        info "NODE : correctif déjà présent dans le docker-compose.yml."
    else
        pct exec "$NODE_ID" -- cp -a /opt/node/docker-compose.yml "/opt/node/docker-compose.yml.bak"
        pct exec "$NODE_ID" -- sed -i -E 's/^([[:space:]]*)- (MONGO_INITDB_ROOT_PASSWORD=.*)$/\1- \2\n\1- GLIBC_TUNABLES=glibc.pthread.rseq=1/' /opt/node/docker-compose.yml
        pct exec "$NODE_ID" -- grep -q 'GLIBC_TUNABLES' /opt/node/docker-compose.yml \
            || die "NODE : ligne MONGO_INITDB_ROOT_PASSWORD introuvable ; ajoute « - GLIBC_TUNABLES=glibc.pthread.rseq=1 » sous environment de mongo."
        info "NODE : GLIBC_TUNABLES ajouté (ancienne version : docker-compose.yml.bak)."
    fi

    pct exec "$NODE_ID" -- bash -c 'cd /opt/node && docker compose up -d --force-recreate'
    verify_node
}

node_restart() {
    pct exec "$NODE_ID" -- bash -c "cd /opt/node && docker compose restart node"
}

# Journaux de l'application. Usage : ./install.sh --run node_logs
node_logs() {
    pct exec "$NODE_ID" -- bash -c "cd /opt/node && docker compose logs --tail 50 node mongo"
}

###############################################################################
#                              DOCKER VM                                      #
###############################################################################

create_docker_cloud_init() {

    info "Création du cloud-init Docker..."

    local SNIPPET="/var/lib/vz/snippets/docker-${DOCKER_ID}.yaml"

    cat > "$SNIPPET" <<EOF
#cloud-config

hostname: ${DOCKER_HOSTNAME}
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: false
    passwd: ${ROOT_PASSWORD_HASH}

package_update: true

packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
  - gnupg

write_files:

  - path: /usr/local/sbin/install-docker.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash

      set -Eeuo pipefail

      export DEBIAN_FRONTEND=noninteractive

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

      systemctl enable docker
      systemctl restart docker

      docker version
      docker compose version

  - path: /usr/local/sbin/docker-shared-storage.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash

      set -Eeuo pipefail

      SHARED_GROUP="${SHARED_GROUP}"
      SHARED_GID="${SHARED_GID}"
      MOUNT_POINT="${DOCKER_SHARED_MOUNT}"

      if getent group "\${SHARED_GROUP}" >/dev/null 2>&1; then

          EXISTING_GID="\$(getent group "\${SHARED_GROUP}" | cut -d: -f3)"

          [[ "\${EXISTING_GID}" == "\${SHARED_GID}" ]] \
              || exit 1

      else

          groupadd \
              -g "\${SHARED_GID}" \
              "\${SHARED_GROUP}"
      fi

      mkdir -p "\${MOUNT_POINT}"

      if ! grep -q "\${MOUNT_POINT}" /etc/fstab; then

          printf '${VIRTIOFS_DIR_ID} %s virtiofs defaults,_netdev,nofail 0 0\n' \
              "\${MOUNT_POINT}" >> /etc/fstab
      fi

      for attempt in {1..20}; do

          if mountpoint -q "\${MOUNT_POINT}"; then
              break
          fi

          if ! mount "\${MOUNT_POINT}"; then
              sleep 2
          fi
      done

      if ! mountpoint -q "\${MOUNT_POINT}"; then
          echo "AVERTISSEMENT: \${MOUNT_POINT} non monté (normal au tout premier boot). Le montage réel aura lieu après le redémarrage prévu par le script d'installation." >&2
      fi

      mkdir -p \
          /opt/apps/nextcloud \
          /opt/apps/syncin \
          /opt/apps/immich \
          /opt/apps/homeassistant \
          /opt/apps/jellyfin
EOF

    if [[ "$ENABLE_NEXTCLOUD" == "true" ]]; then

        cat >> "$SNIPPET" <<EOF

  - path: /opt/apps/nextcloud/docker-compose.yml
    owner: root:root
    permissions: '0600'
    content: |
      services:

        nextcloud-db:
          image: postgres:16-alpine
          container_name: nextcloud-db
          restart: unless-stopped
          environment:
            - POSTGRES_DB=nextcloud
            - POSTGRES_USER=nextcloud
            - POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
          volumes:
            - nextcloud_db:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U nextcloud -d nextcloud"]
            interval: 5s
            timeout: 5s
            retries: 20

        nextcloud:
          image: nextcloud:stable
          container_name: nextcloud
          restart: unless-stopped
          depends_on:
            nextcloud-db:
              condition: service_healthy
          environment:
            - POSTGRES_HOST=nextcloud-db
            - POSTGRES_DB=nextcloud
            - POSTGRES_USER=nextcloud
            - POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
            - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
            - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
            - NEXTCLOUD_TRUSTED_DOMAINS=cloud.${DOMAIN} ${DOCKER_IP%%/*} ${LAN_IP}
            - TRUSTED_PROXIES=${SWAG_IP%%/*}
            - NEXTCLOUD_DATA_DIR=${DOCKER_SHARED_MOUNT}/${APPS_DATA_SUBDIR}/nextcloud
            - TZ=Europe/Paris
          volumes:
            - nextcloud_html:/var/www/html
            - ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:rw
          group_add:
            - "${SHARED_GID}"
          ports:
            - "${NEXTCLOUD_HTTP_PORT}:80"

      volumes:
        nextcloud_db:
        nextcloud_html:
EOF
    fi

    # -------------------------------------------------------------------
    # NEXTCLOUD - EXTERNAL STORAGE : automatisé, voir
    # configure_nextcloud_external_storage() (appelée par start_docker_apps).
    # -------------------------------------------------------------------

    if [[ "$ENABLE_SYNCIN" == "true" ]]; then

        cat >> "$SNIPPET" <<EOF

  - path: /opt/apps/syncin/environment.yaml
    owner: root:root
    permissions: '0644'
    content: |
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
      applications:
        files:
          dataPath: /app/data

  - path: /opt/apps/syncin/docker-compose.yml
    owner: root:root
    permissions: '0600'
    content: |
      name: syncin
      services:

        syncin-db:
          image: mariadb:11
          container_name: syncin-db
          restart: unless-stopped
          command: --innodb_ft_cache_size=16000000 --max-allowed-packet=1G
          environment:
            - MARIADB_DATABASE=syncin
            - MARIADB_USER=syncin
            - MARIADB_PASSWORD=${SYNCIN_DB_PASSWORD}
            - MARIADB_ROOT_PASSWORD=${SYNCIN_DB_ROOT_PASSWORD}
          volumes:
            - syncin_db:/var/lib/mysql
          healthcheck:
            test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
            interval: 5s
            timeout: 5s
            retries: 20

        syncin:
          image: syncin/server:2
          container_name: syncin
          restart: unless-stopped
          depends_on:
            syncin-db:
              condition: service_healthy
          environment:
            - INIT_ADMIN=true
            - INIT_ADMIN_LOGIN=${SYNCIN_ADMIN_LOGIN}
            - INIT_ADMIN_PASSWORD=${SYNCIN_ADMIN_PASSWORD}
            - PUID=${DOCKER_APPS_UID}
            - PGID=${SHARED_GID}
            - TZ=Europe/Paris
          volumes:
            - /opt/apps/syncin/environment.yaml:/app/environment/environment.yaml:ro
            # Données internes de Sync-in (users/spaces/tmp) : sur SHARED, dans un dossier caché.
            - ${DOCKER_SHARED_MOUNT}/${APPS_DATA_SUBDIR}/syncin:/app/data
            # SHARED visible dans le conteneur au même chemin que partout :
            # dans Sync-in (Admin > Spaces > racine externe), utiliser
            # ${DOCKER_SHARED_MOUNT}/Family, /Photo, /Movies, /Music.
            - ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:rw
          group_add:
            - "${SHARED_GID}"
          ports:
            - "${SYNCIN_HTTP_PORT}:8080"

      volumes:
        syncin_db:
EOF
    fi

    if [[ "$ENABLE_IMMICH" == "true" ]]; then

        cat >> "$SNIPPET" <<EOF

  - path: /opt/apps/immich/docker-compose.yml
    owner: root:root
    permissions: '0600'
    content: |
      # Vérifie le tag d'image immich-app/postgres actuel sur
      # https://docs.immich.app avant le premier démarrage : ce tag
      # change à chaque version majeure d'Immich.
      services:

        immich-server:
          image: ghcr.io/immich-app/immich-server:release
          container_name: immich-server
          restart: unless-stopped
          depends_on:
            immich-redis:
              condition: service_healthy
            immich-db:
              condition: service_healthy
          environment:
            - DB_HOSTNAME=immich-db
            - DB_USERNAME=immich
            - DB_PASSWORD=${IMMICH_DB_PASSWORD}
            - DB_DATABASE_NAME=immich
            - REDIS_HOSTNAME=immich-redis
            - TZ=Europe/Paris
          volumes:
            # Les versions actuelles d'Immich lisent/écrivent UNIQUEMENT dans /data.
            - ${DOCKER_SHARED_MOUNT}/${IMMICH_UPLOAD_SUBDIR}:/data
            - ${DOCKER_SHARED_MOUNT}/Photo:/mnt/external/photo:rw
            - /etc/localtime:/etc/localtime:ro
          group_add:
            - "${SHARED_GID}"
          ports:
            - "${IMMICH_HTTP_PORT}:2283"

        immich-machine-learning:
          image: ghcr.io/immich-app/immich-machine-learning:release
          container_name: immich-ml
          restart: unless-stopped
          volumes:
            - immich_model_cache:/cache

        immich-redis:
          image: redis:7-alpine
          container_name: immich-redis
          restart: unless-stopped
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 5s
            timeout: 5s
            retries: 20

        immich-db:
          image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
          container_name: immich-db
          restart: unless-stopped
          environment:
            - POSTGRES_PASSWORD=${IMMICH_DB_PASSWORD}
            - POSTGRES_USER=immich
            - POSTGRES_DB=immich
            - POSTGRES_INITDB_ARGS=--data-checksums
          volumes:
            - immich_db:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U immich -d immich"]
            interval: 5s
            timeout: 5s
            retries: 20

      volumes:
        immich_model_cache:
        immich_db:
EOF
    fi

    if [[ "$ENABLE_HOMEASSISTANT" == "true" ]]; then

        cat >> "$SNIPPET" <<EOF

  - path: /opt/apps/homeassistant/docker-compose.yml
    owner: root:root
    permissions: '0600'
    content: |
      name: homeassistant
      services:
        homeassistant:
          image: ghcr.io/home-assistant/home-assistant:stable
          container_name: homeassistant
          restart: unless-stopped
          privileged: true
          network_mode: host
          environment:
            - TZ=Europe/Paris
          volumes:
            - homeassistant_config:/config
            - ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:ro
            - /run/dbus:/run/dbus:ro
          group_add:
            - "${SHARED_GID}"

      volumes:
        homeassistant_config:
EOF
    fi

    if [[ "$ENABLE_JELLYFIN" == "true" ]]; then

        cat >> "$SNIPPET" <<EOF

  - path: /opt/apps/jellyfin/docker-compose.yml
    owner: root:root
    permissions: '0600'
    content: |
      name: jellyfin
      services:
        jellyfin:
          image: jellyfin/jellyfin:latest
          container_name: jellyfin
          restart: unless-stopped
          environment:
            - TZ=Europe/Paris
          volumes:
            - jellyfin_config:/config
            - jellyfin_cache:/cache
            - ${DOCKER_SHARED_MOUNT}/Movies:/media/movies:ro
            - ${DOCKER_SHARED_MOUNT}/Music:/media/music:ro
            - ${DOCKER_SHARED_MOUNT}/Photo:/media/photo:ro
          group_add:
            - "${SHARED_GID}"
          ports:
            - "${JELLYFIN_HTTP_PORT}:8096"

      volumes:
        jellyfin_config:
        jellyfin_cache:
EOF
    fi

    cat >> "$SNIPPET" <<EOF

runcmd:
  - [bash, /usr/local/sbin/install-docker.sh]
  - [bash, /usr/local/sbin/docker-shared-storage.sh]
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, restart, qemu-guest-agent]
EOF

    chmod 600 "$SNIPPET"
}

# Exécute "occ" dans le conteneur Nextcloud via l'agent QEMU et affiche
# stdout/stderr du guest (qm guest exec renvoie du JSON).
nextcloud_occ() {

    local VMID="$1"
    shift

    local raw

    raw="$(qm guest exec "$VMID" --timeout 180 -- docker exec -u www-data nextcloud php occ "$@" 2>&1 || true)"

    jq -r '.["out-data"] // empty, .["err-data"] // empty' <<< "$raw" 2>/dev/null || printf '%s\n' "$raw"
}

# Connecte Nextcloud aux sous-dossiers de SHARED (stockages externes
# "local"). Idempotent : un montage déjà présent n'est pas recréé ni
# modifié (les droits ajustés ensuite dans l'interface sont conservés).
# À la création, chaque stockage est réservé au groupe "admin" ; les
# autres utilisateurs/groupes s'ajoutent ensuite dans Paramètres
# d'administration > Stockage externe > colonne "Disponible pour".
configure_nextcloud_external_storage() {

    local VMID="$1"
    local attempt out folder mount_list storage_id
    local ready=false

    info "Attente de la fin d'installation de Nextcloud (occ status)..."

    for ((attempt = 1; attempt <= 60; attempt++)); do

        out="$(nextcloud_occ "$VMID" status)"

        if grep -q 'installed: true' <<< "$out"; then
            ready=true
            break
        fi

        sleep 10
    done

    if [[ "$ready" != "true" ]]; then
        warn "Nextcloud n'a pas fini son installation après 10 min : stockages externes non configurés. Relance-les plus tard avec : qm guest exec ${VMID} -- docker exec -u www-data nextcloud php occ files_external:list"
        return 0
    fi

    # Nextcloud interdit par défaut la création de stockages "local".
    nextcloud_occ "$VMID" config:system:set files_external_allow_create_new_local --value=true --type=boolean > /dev/null
    nextcloud_occ "$VMID" app:enable files_external > /dev/null

    mount_list="$(nextcloud_occ "$VMID" files_external:list)"

    for folder in Family Photo Movies Music; do

        if grep -q "/${folder} " <<< "$mount_list"; then
            info "Nextcloud : stockage externe /${folder} déjà présent."
            continue
        fi

        info "Nextcloud : stockage externe /${folder} -> ${DOCKER_SHARED_MOUNT}/${folder}"

        out="$(nextcloud_occ "$VMID" files_external:create "$folder" local null::null -c "datadir=${DOCKER_SHARED_MOUNT}/${folder}")"

        info "Nextcloud : ${out}"

        storage_id="$(grep -oE '[0-9]+' <<< "$out" | tail -n 1 || true)"

        if [[ -n "$storage_id" ]]; then
            nextcloud_occ "$VMID" files_external:applicable --add-group="admin" "$storage_id" > /dev/null
            info "Nextcloud : /${folder} (id ${storage_id}) réservé au groupe admin."
        else
            warn "ID du stockage /${folder} introuvable : il reste visible de tous les utilisateurs, à restreindre dans l'interface."
        fi
    done

    info "Stockages externes Nextcloud :"
    nextcloud_occ "$VMID" files_external:list
}

# Démarre les 3 stacks Docker depuis l'hôte, une par une, APRÈS le
# redémarrage qui attache le VirtioFS. Volontairement PAS dans le runcmd
# du premier boot : si le cumul des téléchargements d'images dépasse la
# fenêtre d'attente de cloud-init, le script finissait par éteindre la
# VM de force pendant que "docker compose up -d" tournait encore, tuant
# le script en plein milieu - et cloud-init ne rejoue jamais son runcmd
# ensuite, donc les stacks pas encore atteintes ne démarraient plus
# jamais, même après relance. Ici, chaque stack a son temps propre, sans
# délai global partagé, et un échec de l'une n'empêche pas les autres.
start_docker_apps() {

    local VMID="$1"

    info "Attente de l'agent QEMU après le redémarrage de la VM DOCKER..."

    wait_for_qemu_agent "$VMID" 60 \
        || warn "L'agent QEMU ne répond pas après 5 minutes ; tentative de démarrage des apps quand même."

    if [[ "$ENABLE_NEXTCLOUD" == "true" ]]; then

        info "Démarrage de la stack Nextcloud (peut prendre plusieurs minutes au premier tirage d'images)..."

        if ! timeout 1800 qm guest exec "$VMID" -- bash -c "cd /opt/apps/nextcloud && docker compose up -d"; then
            warn "Échec du démarrage de Nextcloud. Vérifie : qm guest exec ${VMID} -- docker compose -f /opt/apps/nextcloud/docker-compose.yml logs"
        else
            configure_nextcloud_external_storage "$VMID"
        fi
    fi

    if [[ "$ENABLE_SYNCIN" == "true" ]]; then

        info "Démarrage de la stack Sync-in..."

        if ! timeout 1800 qm guest exec "$VMID" -- bash -c "cd /opt/apps/syncin && docker compose up -d"; then
            warn "Échec du démarrage de Sync-in. Vérifie : qm guest exec ${VMID} -- docker compose -f /opt/apps/syncin/docker-compose.yml logs"
        fi
    fi

    if [[ "$ENABLE_IMMICH" == "true" ]]; then

        info "Démarrage de la stack Immich (l'image machine-learning est volumineuse, ça peut prendre longtemps)..."

        if ! timeout 1800 qm guest exec "$VMID" -- bash -c "cd /opt/apps/immich && docker compose up -d"; then
            warn "Échec du démarrage d'Immich. Vérifie : qm guest exec ${VMID} -- docker compose -f /opt/apps/immich/docker-compose.yml logs"
        fi
    fi

    if [[ "$ENABLE_HOMEASSISTANT" == "true" ]]; then

        info "Démarrage de Home Assistant..."

        if ! timeout 600 qm guest exec "$VMID" -- bash -c "cd /opt/apps/homeassistant && docker compose up -d"; then
            warn "Échec du démarrage de Home Assistant. Vérifie : qm guest exec ${VMID} -- docker compose -f /opt/apps/homeassistant/docker-compose.yml logs"
        fi
    fi

    if [[ "$ENABLE_JELLYFIN" == "true" ]]; then

        info "Démarrage de Jellyfin..."

        if ! timeout 600 qm guest exec "$VMID" -- bash -c "cd /opt/apps/jellyfin && docker compose up -d"; then
            warn "Échec du démarrage de Jellyfin. Vérifie : qm guest exec ${VMID} -- docker compose -f /opt/apps/jellyfin/docker-compose.yml logs"
        fi
    fi
}

# Vérifie les éléments indispensables avant de lancer les stacks.
# Cela rend notamment les problèmes Sync-in beaucoup plus explicites.
#
# La VM vient d'être redémarrée (qm start) pour attacher le VirtioFS :
# l'agent QEMU et le montage /srv/data (fstab, _netdev) ne sont prêts qu'au
# bout de quelques dizaines de secondes. On attend donc l'agent, puis on
# retente la vérification plusieurs fois avant de conclure à un échec.
verify_docker_shared_storage() {

    local VMID="$1"
    local MAX_ATTEMPTS="${2:-24}"
    local attempt raw exitcode

    info "Vérification du stockage SHARED dans la VM DOCKER..."

    wait_for_qemu_agent "$VMID" 60 \
        || die "L'agent QEMU de la VM DOCKER ne répond pas après le redémarrage. Diagnostic : qm config ${VMID} | grep -E 'agent|virtiofs' ; journalctl -b | grep -i virtiofsd | tail ; console de la VM : systemctl status qemu-guest-agent"

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do

        raw="$(qm guest exec "$VMID" -- bash -c '
            set -e
            mountpoint -q /srv/data
            getent group fileshare | grep -q ":2000:"
            test -d /srv/data/Family
            test -d /srv/data/Photo
            test -d /srv/data/Movies
            test -d /srv/data/Music
        ' 2>&1 || true)"

        exitcode="$(jq -r '.exitcode // empty' <<< "$raw" 2>/dev/null || true)"

        if [[ "$exitcode" == "0" ]]; then
            info "SHARED est monté et le groupe fileshare/GID ${SHARED_GID} est présent dans DOCKER."
            return 0
        fi

        info "SHARED pas encore prêt dans DOCKER (tentative ${attempt}/${MAX_ATTEMPTS}, exitcode='${exitcode}') ; nouvelle tentative dans 5 s."
        sleep 5
    done

    die "SHARED n'est pas correctement monté dans la VM DOCKER après $(( MAX_ATTEMPTS * 5 ))s. Dernière sortie : ${raw}. Diagnostic : qm guest exec ${VMID} -- bash -c 'findmnt /srv/data; mount | grep virtiofs; dmesg | grep -i virtiofs; ls -la /srv/data'. Les stacks Docker ne doivent pas être démarrées avant correction."
}

create_docker_vm() {

    create_docker_cloud_init

    create_cloud_vm \
        "$DOCKER_ID" \
        "$DOCKER_HOSTNAME" \
        "$DOCKER_CORES" \
        "$DOCKER_MEMORY" \
        "$DOCKER_DISK" \
        "$DOCKER_IP" \
        "$DOCKER_GATEWAY" \
        "docker-${DOCKER_ID}.yaml"

    info "Configuration VirtioFS de la VM ${DOCKER_ID}..."

    qm set "$DOCKER_ID" \
        --virtiofs0 "dirid=${VIRTIOFS_DIR_ID},cache=auto,expose-acl=1"

    if qm status "$DOCKER_ID" |
        grep -q "status: running"; then

        info "Attente du qemu-guest-agent sur la VM DOCKER..."

        wait_for_qemu_agent "$DOCKER_ID" \
            || warn "L'agent QEMU ne répond pas après 5 minutes, tentative d'arrêt quand même."

        # Fenêtre large : le runcmd installe Docker puis tire les images
        # des 3 stacks (Nextcloud/Sync-in/Immich, dont l'image machine
        # learning d'Immich qui pèse plusieurs Go) avant que cloud-init
        # ne se déclare "done". Sur une connexion modeste, ça peut prendre
        # 20-30 min au premier démarrage rien que pour les téléchargements.
        info "Attente de la fin du cloud-init (Docker + pull des images) sur la VM DOCKER, ça peut prendre jusqu'à 30 min au premier démarrage..."

        wait_for_cloud_init "$DOCKER_ID" 360 \
            || warn "cloud-init ne signale pas 'done' après 30 minutes, tentative d'arrêt quand même."

        qm shutdown "$DOCKER_ID" --timeout 60 \
            || die "Impossible d'arrêter proprement la VM DOCKER."

        for _ in {1..30}; do

            if qm status "$DOCKER_ID" |
                grep -q "status: stopped"; then
                break
            fi

            sleep 1
        done

        qm status "$DOCKER_ID" |
            grep -q "status: stopped" \
            || die "La VM DOCKER ne s'est pas arrêtée."
    fi

    qm start "$DOCKER_ID"

    info "VM DOCKER ${DOCKER_ID} créée avec accès VirtioFS à ${DOCKER_SHARED_MOUNT}."

    verify_docker_shared_storage "$DOCKER_ID"
    start_docker_apps "$DOCKER_ID"
}


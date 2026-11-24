###############################################################################
#   NEXTCLOUD : OPTIMISATION, CORRECTIFS PHP (PHP2Shell), PHOTOS + IA          #
###############################################################################

# Module tools/20-nextcloud.sh (v2.55.0). Tout est idempotent et NON BLOQUANT dans l'installation :
# un échec ici affiche un avertissement, il n'arrête jamais le script.
#
#   nextcloud_stack_apply     écrit docker-compose.override.yml (Redis, cron, réglages PHP, image avec ffmpeg+node si IA)
#                             à côté du compose d'origine (jamais modifié) puis relance Nextcloud
#   nextcloud_optimize        stack_apply + réglages occ (cache Redis, cron, région, fenêtre de maintenance, aperçus)
#   php_cve_check             PHP de chaque conteneur (VM Docker, CT SWAG) comparé aux versions corrigées de PHP2Shell
#   php_cve_hunt              recherche d'indices de compromission (webshells...)
#   php_cve_fix               met à jour Nextcloud (même version majeure) et SWAG, puis revérifie
#   nextcloud_photos_setup    Memories + Photos (+ Recognize = IA) ; modèles, scan et indexation en arrière-plan
#   nextcloud_photos_classify lance la classification IA de toute la bibliothèque (long) : start | stop | status
#   nextcloud_photos_status   état (applications, files d'attente, nombre de visages...)
#   docker_vm_cpu_apply       type de processeur de la VM Docker (AVX/AVX2 pour l'IA) : [reboot]

NC_STACK_DIR="/opt/apps/nextcloud"

# occ dans le conteneur Nextcloud de la VM Docker
nc_occ() { nextcloud_occ "$DOCKER_ID" "$@"; }

# Version majeure de Nextcloud en cours d'exécution (vide si occ ne répond pas)
nextcloud_running_major() {

    local out
    out="$(nc_occ status 2>/dev/null || true)"
    sed -n 's/^.*versionstring: *\([0-9][0-9]*\)\..*$/\1/p' <<< "$out" | head -n 1
}

# Étiquette d'image Nextcloud : NEXTCLOUD_IMAGE_TAG, sinon la version MAJEURE en cours (jamais "stable" qui peut
# sauter à la majeure suivante lors d'un simple pull), sinon la dernière étiquette connue, sinon "stable".
nextcloud_image_tag() {

    local tag="${NEXTCLOUD_IMAGE_TAG:-}" major

    if [[ -z "$tag" ]]; then
        major="$(nextcloud_running_major)"
        if [[ "$major" =~ ^[0-9]+$ ]]; then
            tag="$major"
        else
            tag="$(vm_read_file "$DOCKER_ID" "${NC_STACK_DIR}/.homelab-image-tag" | head -n 1 | tr -d '[:space:]')"
        fi
    fi

    printf '%s' "${tag:-stable}"
}

# Réglages PHP ajoutés au conteneur (chargés en dernier : zz-)
nextcloud_php_ini_text() {
    cat <<'EOF'
; Généré par l'installateur homelab (nextcloud_stack_apply) : ne pas modifier à la main.
; Contre-mesure PHP (CVE-2026-115560, ouverte au 2 nov. 2026) : la progression d'envoi de session n'est pas utilisée par Nextcloud.
session.upload_progress.enabled=0
expose_php=Off
opcache.interned_strings_buffer=32
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
apc.enable_cli=1
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF
}

# Image dérivée (IA) : Recognize a besoin de Node.js et de FFmpeg DANS le conteneur qui exécute les tâches de fond.
nextcloud_dockerfile_text() {
    cat <<'EOF'
# Généré par l'installateur homelab (nextcloud_stack_apply).
ARG NC_TAG=stable
FROM nextcloud:${NC_TAG}
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg nodejs \
 && rm -rf /var/lib/apt/lists/*
EOF
}

# docker-compose.override.yml (fusionné automatiquement par « docker compose » avec docker-compose.yml)
# $1 = étiquette de l'image, $2 = true si image dérivée (IA)
nextcloud_override_text() {

    local tag="$1" custom="$2" img="nextcloud:$1" build=""

    if [[ "$custom" == "true" ]]; then
        img="nextcloud-homelab:${tag}"
        build="    build:
      context: ./build
      args:
        NC_TAG: \"${tag}\""
    fi

    cat <<EOF
# Généré par l'installateur homelab (nextcloud_stack_apply) : ne pas modifier à la main.
# Réécrit à chaque lancement ; docker-compose.yml (créé à l'installation) n'est jamais touché.
services:

  nextcloud-redis:
    image: redis:7-alpine
    container_name: nextcloud-redis
    restart: unless-stopped
    command: ["redis-server", "--save", "", "--appendonly", "no", "--maxmemory", "256mb", "--maxmemory-policy", "volatile-lru"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  nextcloud:
    image: ${img}
${build}
    depends_on:
      nextcloud-redis:
        condition: service_healthy
    environment:
      - REDIS_HOST=nextcloud-redis
      - PHP_MEMORY_LIMIT=${NEXTCLOUD_PHP_MEMORY_LIMIT}
      - PHP_UPLOAD_LIMIT=${NEXTCLOUD_UPLOAD_LIMIT}
    volumes:
      - ./php-homelab.ini:/usr/local/etc/php/conf.d/zz-homelab.ini:ro

  nextcloud-cron:
    image: ${img}
${build}
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on:
      nextcloud:
        condition: service_started
      nextcloud-redis:
        condition: service_healthy
    environment:
      - REDIS_HOST=nextcloud-redis
      - PHP_MEMORY_LIMIT=${NEXTCLOUD_PHP_MEMORY_LIMIT}
      - TZ=Europe/Paris
    volumes:
      - nextcloud_html:/var/www/html
      - ${DOCKER_SHARED_MOUNT}:${DOCKER_SHARED_MOUNT}:rw
      - ${DOCKER_APPS_MOUNT}/nextcloud:${DOCKER_APPS_MOUNT}/nextcloud:rw
      - ./php-homelab.ini:/usr/local/etc/php/conf.d/zz-homelab.ini:ro
    group_add:
      - "${SHARED_GID}"
EOF
}

# Vrai si l'un des réglages demande l'override
nextcloud_stack_wanted() {
    [[ "${NEXTCLOUD_OPTIMIZE:-true}" == "true" || "${NEXTCLOUD_PHOTOS:-false}" == "true" || "${NEXTCLOUD_RECOGNIZE:-false}" == "true" ]]
}

# Écrit les fichiers dans la VM, valide la configuration, (re)construit l'image si besoin et relance les conteneurs.
nextcloud_stack_apply() {

    local VMID="${1:-$DOCKER_ID}" tag custom=false ov ini df old out svc

    [[ "$ENABLE_NEXTCLOUD" == "true" ]] || return 0

    nextcloud_wait_ready "$VMID" || { warn "Nextcloud pas prêt : relance ./install.sh --run nextcloud_stack_apply quand il l'est."; return 1; }

    [[ "${NEXTCLOUD_RECOGNIZE:-false}" == "true" ]] && custom=true

    tag="$(nextcloud_image_tag)"
    ov="$(nextcloud_override_text "$tag" "$custom")"
    ini="$(nextcloud_php_ini_text)"
    df="$(nextcloud_dockerfile_text)"

    info "Nextcloud : pile Docker (Redis, cron, PHP) ; image nextcloud:${tag}$([[ "$custom" == "true" ]] && echo " + ffmpeg/node (IA)")."

    vm_run "$VMID" 30 "mkdir -p '${NC_STACK_DIR}/build'" > /dev/null
    vm_write_file "$VMID" "${NC_STACK_DIR}/php-homelab.ini" 0644 "$ini"
    vm_write_file "$VMID" "${NC_STACK_DIR}/build/Dockerfile" 0644 "$df"
    vm_write_file "$VMID" "${NC_STACK_DIR}/.homelab-image-tag" 0644 "$tag"
    vm_write_file "$VMID" "${NC_STACK_DIR}/docker-compose.override.yml.new" 0600 "$ov"

    out="$(vm_run "$VMID" 60 "cd '${NC_STACK_DIR}' && docker compose -f docker-compose.yml -f docker-compose.override.yml.new config -q 2>&1 && echo CONFIG_OK")"
    if ! grep -q CONFIG_OK <<< "$out"; then
        vm_run "$VMID" 30 "rm -f '${NC_STACK_DIR}/docker-compose.override.yml.new'" > /dev/null
        warn "Nextcloud : configuration Docker invalide, rien n'a été modifié. Sortie : $(head -n 5 <<< "$out" | tr '\n' ' ')"
        return 1
    fi

    old="$(vm_read_file "$VMID" "${NC_STACK_DIR}/docker-compose.override.yml")"
    vm_run "$VMID" 30 "mv -f '${NC_STACK_DIR}/docker-compose.override.yml.new' '${NC_STACK_DIR}/docker-compose.override.yml'" > /dev/null

    svc="nextcloud-redis nextcloud nextcloud-cron"
    if [[ "$old" == "$ov" ]]; then
        info "Nextcloud : override inchangé, simple vérification des conteneurs."
    fi

    if [[ "$custom" == "true" ]]; then
        info "Nextcloud : construction de l'image (ffmpeg + node ; plusieurs minutes la première fois)..."
        out="$(vm_run "$VMID" 1800 "cd '${NC_STACK_DIR}' && docker compose build --pull nextcloud 2>&1 | tail -n 6; echo BUILD_RC=\${PIPESTATUS[0]}")"
        if ! grep -q 'BUILD_RC=0' <<< "$out"; then
            warn "Nextcloud : construction de l'image échouée, conteneurs non modifiés. Sortie : $(tail -n 4 <<< "$out" | tr '\n' ' ')"
            return 1
        fi
        vm_run "$VMID" 600 "cd '${NC_STACK_DIR}' && docker compose pull -q nextcloud-redis" > /dev/null
    else
        vm_run "$VMID" 900 "cd '${NC_STACK_DIR}' && docker compose pull -q ${svc}" > /dev/null
    fi

    out="$(vm_run "$VMID" 900 "cd '${NC_STACK_DIR}' && docker compose up -d ${svc} 2>&1 | tail -n 12")"
    printf '%s\n' "$out" | sed 's/^/    /'

    nextcloud_wait_ready "$VMID" || { warn "Nextcloud ne répond plus après la relance (journal : qm guest exec ${VMID} -- docker logs --tail 40 nextcloud)."; return 1; }
    return 0
}

# Réglages occ recommandés (cache Redis/APCu, cron, région, fenêtre de maintenance, aperçus, index de base)
nextcloud_optimize() {

    local VMID="${1:-$DOCKER_ID}" out

    [[ "$ENABLE_NEXTCLOUD" == "true" ]] || return 0
    nextcloud_stack_wanted || { info "Nextcloud : optimisation désactivée (NEXTCLOUD_OPTIMIZE=false)."; return 0; }

    nextcloud_stack_apply "$VMID" || return 1

    info "Nextcloud : réglages (cache, cron, aperçus, maintenance)..."

    nc_occ config:system:set memcache.local --value='\OC\Memcache\APCu' > /dev/null || true
    nc_occ config:system:set memcache.distributed --value='\OC\Memcache\Redis' > /dev/null || true
    nc_occ config:system:set memcache.locking --value='\OC\Memcache\Redis' > /dev/null || true
    nc_occ config:system:set redis host --value=nextcloud-redis > /dev/null || true
    nc_occ config:system:set redis port --type=integer --value=6379 > /dev/null || true

    nc_occ background:cron > /dev/null || true

    nc_occ config:system:set default_phone_region --value="${NEXTCLOUD_PHONE_REGION:-FR}" > /dev/null || true
    nc_occ config:system:set maintenance_window_start --type=integer --value="${NEXTCLOUD_MAINTENANCE_HOUR:-1}" > /dev/null || true
    nc_occ config:system:set overwriteprotocol --value=https > /dev/null || true
    nc_occ config:system:set overwrite.cli.url --value="https://${NEXTCLOUD_SUBDOMAIN}.${DOMAIN}" > /dev/null || true

    nc_occ config:system:set preview_max_x --type=integer --value="${NEXTCLOUD_PREVIEW_MAX:-2048}" > /dev/null || true
    nc_occ config:system:set preview_max_y --type=integer --value="${NEXTCLOUD_PREVIEW_MAX:-2048}" > /dev/null || true
    nc_occ config:system:set jpeg_quality --type=integer --value=60 > /dev/null || true

    nc_occ app:disable survey_client > /dev/null 2>&1 || true
    nc_occ db:add-missing-indices > /dev/null 2>&1 || true

    out="$(nc_occ status 2>&1 || true)"
    if grep -q 'installed: true' <<< "$out"; then
        info "Nextcloud : optimisation appliquée (Redis : cache + verrous + sessions, cron toutes les 5 min, région ${NEXTCLOUD_PHONE_REGION:-FR})."
    else
        warn "Nextcloud : occ répond mal après les réglages (Redis injoignable ?). Sortie : $(head -n 3 <<< "$out" | tr '\n' ' ')"
        warn "Retour arrière : qm guest exec ${VMID} -- docker exec -u www-data nextcloud php occ config:system:delete memcache.distributed"
        return 1
    fi
}

###############################################################################
#                     PHP2Shell : CVE-2026-109618 / CVE-2026-109619            #
###############################################################################

# Première version corrigée par branche (publication du 21 octobre 2026). 8.1 et plus ancien : aucun correctif.
php_fixed_for_branch() {
    case "$1" in
        8.5) echo "8.5.12" ;;
        8.4) echo "8.4.27" ;;
        8.3) echo "8.3.36" ;;
        8.2) echo "8.2.35" ;;
        *)   echo "" ;;
    esac
}

# 0 = corrigée, 1 = vulnérable, 2 = branche sans correctif connu
php_version_ok() {

    local v="${1%%[-+~ ]*}" b fixed

    b="$(cut -d. -f1,2 <<< "$v")"
    fixed="$(php_fixed_for_branch "$b")"
    [[ -n "$fixed" ]] || return 2

    [[ "$(printf '%s\n%s\n' "$fixed" "$v" | sort -V | head -n 1)" == "$fixed" ]]
}

# Lignes « étiquette|conteneur|version PHP|date de l'image » pour chaque conteneur qui contient PHP.
php_cve_scan_guest() {

    local kind="$1" id="$2" label="$3" out l cmd

    cmd='for c in $(docker ps --format "{{.Names}}" 2>/dev/null); do
  v=$(docker exec "$c" php -r "echo PHP_VERSION;" 2>/dev/null) || continue
  [ -n "$v" ] || continue
  i=$(docker inspect -f "{{.Image}}" "$c" 2>/dev/null)
  d=$(docker inspect -f "{{.Created}}" "$i" 2>/dev/null | cut -c1-10)
  echo "$c|$v|${d:-?}"
done'

    if [[ "$kind" == "ct" ]]; then
        out="$(pct exec "$id" -- bash -c "$cmd" 2>/dev/null || true)"
    else
        out="$(vm_run "$id" 120 "$cmd")"
    fi

    while IFS= read -r l; do
        [[ "$l" == *"|"*"|"* ]] && printf '%s|%s\n' "$label" "$l"
    done <<< "$out"
    return 0
}

php_cve_check() {

    local rows="" label c v d st bad=0 total=0

    info "PHP2Shell (CVE-2026-109618 / 109619, exécution de code sans authentification, exploitées) : corrigées dans PHP 8.5.12, 8.4.27, 8.3.36, 8.2.35."

    [[ "$ENABLE_DOCKER" == "true" ]] && rows+="$(php_cve_scan_guest vm "$DOCKER_ID" "VM Docker")"$'\n'
    [[ "$ENABLE_SWAG" == "true" ]] && rows+="$(php_cve_scan_guest ct "$SWAG_ID" "CT SWAG")"$'\n'

    if [[ -z "${rows//[[:space:]]/}" ]]; then
        info "PHP2Shell : aucun conteneur PHP joignable (VM Docker / CT SWAG arrêtés ?)."
        return 0
    fi

    while IFS='|' read -r label c v d; do
        [[ -n "$c" ]] || continue
        total=$((total + 1))
        if php_version_ok "$v"; then st=0; else st=$?; fi
        case "$st" in
            0) info "  OK          ${label} / ${c} : PHP ${v} (image du ${d})" ;;
            1) warn "  VULNÉRABLE  ${label} / ${c} : PHP ${v} (image du ${d}) -> ./install.sh --run php_cve_fix"; bad=$((bad + 1)) ;;
            *) warn "  SANS CORRECTIF  ${label} / ${c} : PHP ${v} (branche non corrigée) -> changer d'image"; bad=$((bad + 1)) ;;
        esac
    done <<< "$rows"

    if (( bad == 0 )); then
        info "PHP2Shell : ${total} conteneur(s) PHP, tous à une version corrigée."
    else
        warn "PHP2Shell : ${bad} conteneur(s) à mettre à jour. L'image Nextcloud officielle est de type Apache (mod_php) : c'est la configuration la plus exposée, correctif à appliquer sans attendre."
    fi
    return 0
}

# Indices de compromission (heuristique : l'absence de résultat ne prouve rien).
php_cve_hunt() {

    local V="/var/lib/docker/volumes/nextcloud_nextcloud_html/_data" out

    [[ "$ENABLE_DOCKER" == "true" ]] || die "VM Docker non activée."

    info "Recherche d'indices de compromission dans la VM ${DOCKER_ID} (PHP2Shell actif depuis le 17 octobre 2026, Collabora CODE intégré depuis septembre)..."

    out="$(vm_run "$DOCKER_ID" 300 "V='${V}'
echo '== webshells shx*/shr*.php (app richdocumentscode, CVE-2026-110447) :'
find \"\$V/apps\" \"\$V/custom_apps\" -maxdepth 3 -name 'sh[xr]*.php' 2>/dev/null
echo '== application richdocumentscode (CODE intégré ; inutile avec un Collabora séparé) :'
docker exec -u www-data nextcloud php occ app:list 2>/dev/null | grep -E 'richdocumentscode' || echo '(absente)'
echo '== fichiers PHP inattendus dans config/ :'
ls \"\$V/config\" 2>/dev/null | grep -vE '^(config|apcu|apache-pretty-urls|redis|reverse-proxy|s3|smtp|swift|autoconfig|docker|objectstore|upgrade-disable-web)\\.(config\\.)?php\$|^config\\.sample\\.php\$|^CAN_INSTALL\$|^\\.htaccess\$' || echo '(aucun)'
echo '== fichiers PHP dans le dossier de données (à examiner, normalement aucun) :'
find '${DOCKER_APPS_MOUNT}/nextcloud' -maxdepth 4 -name '*.php' 2>/dev/null | head -n 20")"

    printf '%s\n' "$out"
    echo
    echo "Si quelque chose de suspect apparaît : considérer le serveur comme compromis (changer les mots de passe et secrets, restaurer une sauvegarde saine)."
    echo "Les mots de passe et secrets lus par PHP (Nextcloud : base de données, admin) sont à changer si la VM était exposée avant la mise à jour."
}

# Met à jour Nextcloud (MÊME version majeure) et SWAG, puis revérifie.
php_cve_fix() {

    local out

    if [[ "$ENABLE_DOCKER" == "true" && "$ENABLE_NEXTCLOUD" == "true" ]]; then
        info "Nextcloud : dump des bases puis mise à jour de l'image (version majeure conservée)..."
        [[ -x /usr/local/sbin/homelab-db-dump ]] && /usr/local/sbin/homelab-db-dump > /dev/null 2>&1 || true

        # Le compose d'origine utilise nextcloud:stable : on fige la majeure en cours via l'override.
        ENABLE_NEXTCLOUD=true
        NEXTCLOUD_OPTIMIZE=true
        nextcloud_stack_apply || warn "Nextcloud : mise à jour incomplète, voir plus haut."
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then
        info "SWAG : mise à jour de l'image (PHP-FPM inclus)..."
        out="$(pct exec "$SWAG_ID" -- bash -c "cd /opt/swag && docker compose pull -q 2>&1 | tail -n 3; docker compose up -d 2>&1 | tail -n 5" 2>&1 || true)"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi

    php_cve_check
}


###############################################################################
#                       PHOTOS : MEMORIES + RECOGNIZE (IA)                    #
###############################################################################

# Installe une application Nextcloud et vérifie qu'elle est active.
nextcloud_app_install() {

    local app="$1" out

    out="$(nc_occ app:install "$app" 2>&1 || true)"
    nc_occ app:enable "$app" > /dev/null 2>&1 || true

    if nc_occ app:list --enabled 2>/dev/null | grep -qE "^[[:space:]]*- ${app}:"; then
        info "Nextcloud : application ${app} active."
        return 0
    fi

    warn "Nextcloud : application ${app} non activée (incompatible avec cette version de Nextcloud ?). Sortie : $(head -n 2 <<< "$out" | tr '\n' ' ')"
    return 1
}

# Installe un script dans la VM et le lance en arrière-plan (un seul exemplaire à la fois, journal /var/log/<nom>.log).
nextcloud_vm_script() {   # nom contenu
    vm_write_file "$DOCKER_ID" "/usr/local/sbin/$1" 0755 "$2"
}

nextcloud_vm_bg() {       # nom
    vm_run "$DOCKER_ID" 30 "setsid nohup /usr/local/sbin/$1 > /var/log/$1.log 2>&1 < /dev/null &" > /dev/null
}

nextcloud_photos_user() { printf '%s' "${NEXTCLOUD_PHOTOS_USER:-$NEXTCLOUD_ADMIN_USER}"; }

nextcloud_photos_preflight() {

    local avx mem

    avx="$(vm_run "$DOCKER_ID" 30 "grep -m1 -o -w avx2 /proc/cpuinfo" | tr -d '[:space:]')"
    if [[ "$avx" != "avx2" ]]; then
        warn "IA photos : la VM ${DOCKER_ID} n'expose pas AVX2 (type de processeur '$(qm config "$DOCKER_ID" | sed -n 's/^cpu: *//p' | head -n 1)') : TensorFlow sera très lent ou ne démarrera pas."
        warn "  -> ./install.sh --run docker_vm_cpu_apply reboot   (type '${DOCKER_CPU_TYPE:-host}')"
    fi

    mem="${DOCKER_MEMORY:-8192}"
    if [[ "${NEXTCLOUD_RECOGNIZE:-false}" == "true" ]] && (( mem < 10240 )); then
        warn "IA photos : Recognize demande environ 4 Go de RAM en plus des autres applications, la VM Docker n'en a que ${mem} Mo (4096 gelaient déjà)."
        warn "  -> DOCKER_MEMORY=\"12288\" dans le fichier de réponses, puis à chaud : qm shutdown ${DOCKER_ID} && qm set ${DOCKER_ID} --memory 12288 && qm start ${DOCKER_ID}"
    fi
}

nextcloud_photos_setup() {

    local VMID="${1:-$DOCKER_ID}" user path m modes faces objects landmarks audio video

    [[ "$ENABLE_NEXTCLOUD" == "true" ]] || return 0
    [[ "${NEXTCLOUD_PHOTOS:-false}" == "true" || "${NEXTCLOUD_RECOGNIZE:-false}" == "true" ]] || return 0

    user="$(nextcloud_photos_user)"
    path="${NEXTCLOUD_PHOTOS_PATH:-/Photo}"
    [[ "$path" == /* ]] || path="/${path}"

    info "Nextcloud : photos (Memories${NEXTCLOUD_RECOGNIZE:+ + Recognize}) pour ${user} : dossier ${path}."

    nextcloud_wait_ready "$VMID" || return 1
    nextcloud_photos_preflight

    # L'application Photos est requise par Memories pour les albums (Nextcloud 35 : sans elle, plus d'albums).
    nc_occ app:enable photos > /dev/null 2>&1 || true
    nextcloud_app_install memories || true

    nc_occ user:setting "$user" memories timelinePath "$path" > /dev/null 2>&1 || true

    nextcloud_vm_script nc-photos-index.sh "#!/usr/bin/env bash
# Scan du dossier photos, lieux (géocodage inversé) puis indexation Memories. Lancé par l'installateur.
exec 9>/run/nc-photos-index.lock; flock -n 9 || exit 0
OCC='docker exec -u www-data nextcloud php occ'
\$OCC files:scan --path='${user}/files${path}' -v
\$OCC memories:places-setup || true
\$OCC memories:index
echo \"Terminé : \$(date -Is)\""

    if [[ "${NEXTCLOUD_RECOGNIZE:-false}" == "true" ]]; then

        if nextcloud_app_install recognize; then

            modes=" ${RECOGNIZE_MODES:-faces objects} "
            faces=false; objects=false; landmarks=false; audio=false; video=false
            for m in $modes; do
                case "$m" in
                    faces) faces=true ;;
                    objects) objects=true ;;
                    landmarks) landmarks=true ;;
                    audio) audio=true ;;
                    video) video=true ;;
                    *) warn "RECOGNIZE_MODES : '${m}' inconnu (faces objects landmarks audio video)." ;;
                esac
            done

            nc_occ config:app:set recognize faces.enabled --value="$faces" > /dev/null || true
            nc_occ config:app:set recognize imagenet.enabled --value="$objects" > /dev/null || true
            nc_occ config:app:set recognize landmarks.enabled --value="$landmarks" > /dev/null || true
            nc_occ config:app:set recognize musicnn.enabled --value="$audio" > /dev/null || true
            nc_occ config:app:set recognize movinet.enabled --value="$video" > /dev/null || true
            nc_occ config:app:set recognize tensorflow.gpu --value=false > /dev/null || true
            nc_occ config:app:set recognize tensorflow.purejs --value=false > /dev/null || true
            nc_occ config:app:set recognize tensorflow.cores --value="${RECOGNIZE_CORES:-2}" > /dev/null || true

            info "Recognize : modes ${RECOGNIZE_MODES:-faces objects}, ${RECOGNIZE_CORES:-2} cœur(s), processeur seulement."

            nextcloud_vm_script nc-recognize-models.sh "#!/usr/bin/env bash
# Téléchargement des modèles Recognize (environ 1,5 Go). Lancé par l'installateur.
exec 9>/run/nc-recognize-models.lock; flock -n 9 || exit 0
docker exec -u www-data nextcloud php occ recognize:download-models
echo \"Terminé : \$(date -Is)\""

            nextcloud_vm_script nc-recognize-classify.sh "#!/usr/bin/env bash
# Classification de toute la bibliothèque (long), puis regroupement des visages. Priorité basse.
exec 9>/run/nc-recognize-classify.lock; flock -n 9 || exit 0
OCC='nice -n 15 docker exec -u www-data nextcloud php occ'
\$OCC recognize:classify
for i in 1 2 3 4 5 6 7 8; do \$OCC recognize:cluster-faces; sleep 5; done
echo \"Terminé : \$(date -Is)\""

            nextcloud_vm_bg nc-recognize-models.sh
            info "Recognize : téléchargement des modèles lancé dans la VM (journal : qm guest exec ${VMID} -- tail -n 5 /var/log/nc-recognize-models.sh.log)."
            info "Recognize : les nouvelles photos sont traitées par le cron (toutes les 5 min). Pour traiter toute la bibliothèque tout de suite : ./install.sh --run nextcloud_photos_classify start"
        fi
    fi

    nextcloud_vm_bg nc-photos-index.sh
    info "Memories : scan + indexation de ${path} lancés en arrière-plan (journal : qm guest exec ${VMID} -- tail -n 5 /var/log/nc-photos-index.sh.log)."
    info "Ouvre ensuite https://${NEXTCLOUD_SUBDOMAIN}.${DOMAIN}/apps/memories/ (comparaison avec Immich : https://${IMMICH_SUBDOMAIN}.${DOMAIN}/)."
    info "Les stockages externes ne sont relus que par « files:scan » : après un ajout de photos hors de Nextcloud (Samba) : ./install.sh --run nextcloud_photos_scan"
}

nextcloud_photos_scan() {

    nextcloud_vm_bg nc-photos-index.sh
    info "Scan + indexation relancés (journal : qm guest exec ${DOCKER_ID} -- tail -n 5 /var/log/nc-photos-index.sh.log)."
}

# ./install.sh --run nextcloud_photos_classify start|stop|status
nextcloud_photos_classify() {

    local action="${1:-status}"

    case "$action" in
        start)
            nextcloud_vm_bg nc-recognize-classify.sh
            info "Classification lancée en arrière-plan (priorité basse). Suivi : ./install.sh --run nextcloud_photos_classify status" ;;
        stop)
            vm_run "$DOCKER_ID" 30 "pkill -f nc-recognize-classify.sh; docker exec nextcloud pkill -f recognize:classify; echo arrêté" ;;
        status)
            vm_run "$DOCKER_ID" 30 "pgrep -af 'recognize:|nc-recognize' | head -n 5 || echo '(aucune classification en cours)'; echo '--- journal :'; tail -n 8 /var/log/nc-recognize-classify.sh.log 2>/dev/null" ;;
        *) die "Usage : nextcloud_photos_classify start|stop|status" ;;
    esac
}

nextcloud_photos_status() {

    local sql="docker exec nextcloud-db psql -U nextcloud -d nextcloud -tAc"

    echo "--- Applications"
    nc_occ app:list --enabled 2>/dev/null | grep -E '^\s*- (memories|recognize|photos):' || echo "(Memories / Recognize / Photos non actives)"

    echo "--- Recognize (réglages)"
    nc_occ config:list recognize 2>/dev/null | grep -E 'enabled|cores|gpu|purejs' | sed 's/^/  /' || true

    echo "--- Contenu (si les tables existent)"
    vm_run "$DOCKER_ID" 60 "
echo -n '  photos indexées par Memories : '; ${sql} 'select count(*) from oc_memories' 2>/dev/null || echo '?'
echo -n '  visages détectés             : '; ${sql} 'select count(*) from oc_recognize_face_detections' 2>/dev/null || echo '?'
echo -n '  groupes de visages           : '; ${sql} 'select count(*) from oc_recognize_face_clusters' 2>/dev/null || echo '?'
echo -n '  fichiers en attente (queue)  : '; ${sql} 'select count(*) from oc_recognize_queue_files' 2>/dev/null || echo '?'
echo '--- Processus Recognize (conteneurs)'; docker top nextcloud-cron 2>/dev/null | grep -c node | sed 's/^/  node : /'"

    echo "--- Traitements en arrière-plan"
    vm_run "$DOCKER_ID" 30 "for f in nc-photos-index nc-recognize-models nc-recognize-classify; do echo \"  \$f : \$(tail -n 1 /var/log/\$f.sh.log 2>/dev/null || echo 'jamais lancé')\"; done"
}

# Enchaînement appelé par main() et par nextcloud_reinstall : optimisation, photos/IA, contrôle PHP.
nextcloud_post_install() {

    [[ "$ENABLE_DOCKER" == "true" && "$ENABLE_NEXTCLOUD" == "true" ]] || return 0

    nextcloud_optimize || warn "Nextcloud : optimisation incomplète (./install.sh --run nextcloud_optimize pour réessayer)."
    nextcloud_photos_setup || warn "Nextcloud : photos/IA incomplets (./install.sh --run nextcloud_photos_setup pour réessayer)."
    php_cve_check || true
    return 0
}


###############################################################################
#     TEST DE RESTAURATION MENSUEL + MISES À JOUR DES IMAGES DOCKER           #
###############################################################################

# --- Test de restauration ----------------------------------------------------
# Une sauvegarde qui n'a jamais été restaurée n'est qu'une hypothèse. Chaque mois
# (RESTORE_TEST_CALENDAR), homelab-restore-test vérifie, sans toucher à la production :
#   1. chaque invité a une sauvegarde vzdump récente et lisible (zstd -t / gzip -t) ;
#   2. un CT est réellement RESTAURÉ sous l'ID RESTORE_TEST_ID (jamais démarré), son
#      système de fichiers est monté et contrôlé, puis il est détruit ;
#   3. les dumps de bases sont valides ; Nextcloud (PostgreSQL) et Sync-in (MariaDB)
#      sont rechargés dans une base jetable de la VM DOCKER et leurs tables comptées ;
#   4. si la copie hors site (restic) est configurée : un fichier témoin est restauré
#      et comparé à l'original.
# Résultat : /var/lib/homelab/restore-test.status, notification (ntfy), journal
# /var/log/homelab-restore-test.log.  À la demande : ./install.sh --run restore_test_now

# --- Mises à jour des images Docker -------------------------------------------
# DOCKER_UPDATE_MODE : off | notify | safe  (hebdomadaire, DOCKER_UPDATE_CALENDAR)
#   notify : télécharge les nouvelles images, signale celles qui diffèrent, ne redémarre RIEN.
#   safe   : applique seulement aux projets "safe" (Jellyfin, SWAG, MONITOR, *arr) ;
#            les autres (Nextcloud, Immich, Sync-in, Home Assistant, mail, MongoDB) sont
#            signalés. Ils se mettent à jour à la main, après un dump des bases :
#            ./install.sh --run docker_update_apply <projet>   (ex. nextcloud)

docker_update_projects() {

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        [[ "${ENABLE_NEXTCLOUD:-true}" == "true" ]] && printf 'vm:%s:/opt/apps/nextcloud:manual\n' "$DOCKER_ID"
        printf 'vm:%s:/opt/apps/syncin:manual\n' "$DOCKER_ID"
        [[ "$ENABLE_IMMICH" == "true" ]] && printf 'vm:%s:/opt/apps/immich:manual\n' "$DOCKER_ID"
        [[ "$ENABLE_HOMEASSISTANT" == "true" ]] && printf 'vm:%s:/opt/apps/homeassistant:manual\n' "$DOCKER_ID"
        [[ "$ENABLE_JELLYFIN" == "true" ]] && printf 'vm:%s:/opt/apps/jellyfin:safe\n' "$DOCKER_ID"
        [[ "$ENABLE_COLLABORA" == "true" ]] && printf 'vm:%s:/opt/apps/collabora:manual\n' "$DOCKER_ID"
        [[ "$ENABLE_ONLYOFFICE" == "true" ]] && printf 'vm:%s:/opt/apps/onlyoffice:manual\n' "$DOCKER_ID"
        [[ "${ENABLE_ARR:-false}" == "true" ]] && printf 'vm:%s:/opt/apps/arr:safe\n' "$DOCKER_ID"
    fi

    [[ "$ENABLE_SWAG" == "true" ]] && printf 'ct:%s:/opt/swag:safe\n' "$SWAG_ID"
    [[ "$ENABLE_NODE" == "true" ]] && printf 'ct:%s:/opt/node:manual\n' "$NODE_ID"
    [[ "$ENABLE_MAIL" == "true" ]] && printf 'ct:%s:/opt/mail:manual\n' "$MAIL_ID"
    [[ "${ENABLE_MONITOR:-false}" == "true" ]] && printf 'ct:%s:/opt/monitor:safe\n' "$MONITOR_ID"

    return 0
}

install_restore_test_script() {

    cat > /usr/local/sbin/homelab-restore-test <<'RT_EOF'
#!/usr/bin/env bash
# Test de restauration du homelab (voir host/60-maintenance.sh). Ne modifie pas la production.
set -uo pipefail

CONF=/etc/homelab/homelab.conf
. "$CONF" || exit 1

STATUS=/var/lib/homelab/restore-test.status
LOG=/var/log/homelab-restore-test.log
TID="${RESTORE_TEST_ID:-990}"
TSTORE="${RESTORE_TEST_STORAGE:-local-lvm}"
now="$(date +%s)"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) : test de restauration ==="

results=()   # lignes "test|OK|FAIL|détail"
ok()   { results+=("$1|OK|$now|$2");   echo "OK    $1 : $2"; }
fail() { results+=("$1|FAIL|$now|$2"); echo "ÉCHEC $1 : $2"; }

cleanup_ct() {
    if pct status "$TID" >/dev/null 2>&1; then
        pct unmount "$TID" >/dev/null 2>&1 || true
        pct destroy "$TID" --purge >/dev/null 2>&1 || true
    fi
}
trap cleanup_ct EXIT

# Dernière archive de sauvegarde d'un invité : chemin sur le disque.
latest_archive() {
    local vmid="$1" volid
    volid="$(pvesm list "$BACKUP_STORAGE" --content backup --vmid "$vmid" 2>/dev/null | awk 'NR>1 {print $1}' | sort | tail -n 1)"
    [[ -n "$volid" ]] || return 1
    pvesm path "$volid" 2>/dev/null
}

test_archive() {
    local a="$1"
    case "$a" in
        *.zst)  zstd -tq "$a" ;;
        *.gz)   gzip -t "$a" ;;
        *.lzo)  lzop -t "$a" ;;
        *)      [[ -s "$a" ]] ;;
    esac
}

# ---- 1. Archives présentes, récentes et lisibles --------------------------------
smallest_ct=""; smallest_size=0
for g in ${HEALTH_GUESTS:-}; do
    kind="${g%%:*}" id="${g#*:}"
    a="$(latest_archive "$id")" || { fail "archive-$g" "aucune sauvegarde vzdump pour ${g}"; continue; }

    age_h=$(( (now - $(stat -c %Y "$a")) / 3600 ))
    if (( age_h > 72 )); then fail "archive-$g" "sauvegarde trop ancienne (${age_h} h) : $(basename "$a")"; continue; fi

    if [[ "$kind" == "vm" && "${RESTORE_TEST_VERIFY_VM:-true}" != "true" ]]; then
        ok "archive-$g" "présente (${age_h} h), lecture non vérifiée (RESTORE_TEST_VERIFY_VM=false)"
    elif test_archive "$a"; then
        ok "archive-$g" "lisible, ${age_h} h, $(du -h "$a" | cut -f1)"
    else
        fail "archive-$g" "archive illisible ou corrompue : $(basename "$a")"
        continue
    fi

    if [[ "$kind" == "ct" ]]; then
        sz="$(stat -c %s "$a")"
        if [[ -z "$smallest_ct" ]] || (( sz < smallest_size )); then smallest_ct="$id"; smallest_size="$sz"; fi
    fi
done

# ---- 2. Restauration réelle d'un CT (le plus petit) ------------------------------
if [[ -n "$smallest_ct" ]]; then
    a="$(latest_archive "$smallest_ct")"
    if pct status "$TID" >/dev/null 2>&1; then
        fail "restauration-ct" "l'ID ${TID} (RESTORE_TEST_ID) est déjà utilisé : choisis-en un autre"
    elif pct restore "$TID" "$a" --storage "$TSTORE" --unprivileged 1 >/dev/null 2>&1; then
        pct set "$TID" --onboot 0 --hostname restore-test >/dev/null 2>&1 || true
        mp="$(pct mount "$TID" 2>&1 | grep -o "/var/lib/lxc/${TID}/rootfs" | head -n 1)"
        mp="${mp:-/var/lib/lxc/${TID}/rootfs}"
        if [[ -f "${mp}/etc/os-release" ]] && (( $(find "${mp}/etc" -maxdepth 1 | wc -l) > 10 )); then
            ok "restauration-ct" "CT ${smallest_ct} restauré sous ${TID} et système de fichiers contrôlé"
        else
            fail "restauration-ct" "CT ${smallest_ct} restauré mais système de fichiers incohérent (${mp})"
        fi
        pct unmount "$TID" >/dev/null 2>&1 || true
        pct destroy "$TID" --purge >/dev/null 2>&1 || true
    else
        fail "restauration-ct" "pct restore du CT ${smallest_ct} impossible (espace sur ${TSTORE} ?)"
        cleanup_ct
    fi
else
    echo "(aucun CT sauvegardé : test de restauration de CT ignoré)"
fi

# ---- 3. Dumps de bases -----------------------------------------------------------
DUMPDIR="${APPS_DIR}/backups/db"

vm_exec() {
    local raw code
    raw="$(qm guest exec "$DOCKER_ID" --timeout "${2:-900}" -- bash -c "$1" 2>&1)" || true
    code="$(jq -r 'if .exitcode == null then 1 else .exitcode end' <<< "$raw" 2>/dev/null || echo 1)"
    VM_OUT="$(jq -r '.["out-data"] // empty' <<< "$raw" 2>/dev/null)"
    [[ "$code" == "0" ]]
}

for t in ${DB_DUMP_TARGETS:-}; do
    f="$(ls -1t "$DUMPDIR/$t"/* 2>/dev/null | head -n 1)"
    if [[ -z "$f" ]]; then fail "dump-$t" "aucun dump"; continue; fi
    age_h=$(( (now - $(stat -c %Y "$f")) / 3600 ))
    if (( age_h > 72 )); then fail "dump-$t" "dernier dump trop ancien (${age_h} h)"; continue; fi
    case "$f" in *.gz | *.tgz) gzip -t "$f" 2>/dev/null || { fail "dump-$t" "fichier gzip corrompu"; continue; } ;; esac
    case "$t" in
        nextcloud | immich)
            zcat "$f" | tail -n 5 | grep -q "PostgreSQL database dump complete" \
                && ok "dump-$t" "valide (fin de dump présente, ${age_h} h)" || fail "dump-$t" "dump incomplet (marqueur de fin absent)" ;;
        syncin)
            zcat "$f" | tail -n 3 | grep -q "Dump completed" \
                && ok "dump-$t" "valide (fin de dump présente, ${age_h} h)" || fail "dump-$t" "dump incomplet (marqueur de fin absent)" ;;
        *)  ok "dump-$t" "archive lisible (${age_h} h)" ;;
    esac
done

# Rechargement réel dans une base jetable (images déjà présentes dans la VM : aucun téléchargement).
if [[ "${ENABLE_DOCKER:-false}" == "true" ]] && qm status "$DOCKER_ID" 2>/dev/null | grep -q running; then

    f="$(ls -1t "$DUMPDIR/nextcloud"/*.sql.gz 2>/dev/null | head -n 1)"
    if [[ -n "$f" ]]; then
        vf="${DOCKER_APPS_MOUNT}/backups/db/nextcloud/$(basename "$f")"
        if vm_exec "set -e; cid=\$(docker run -d --rm -e POSTGRES_PASSWORD=t postgres:16-alpine); trap 'docker rm -f \$cid >/dev/null 2>&1' EXIT; for i in \$(seq 40); do docker exec \$cid pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done; zcat '${vf}' | docker exec -i \$cid psql -U postgres -q -o /dev/null >/dev/null 2>&1 || true; docker exec \$cid psql -U postgres -tAc \"select count(*) from pg_tables where schemaname='public'\"" 1200; then
            n="$(tr -dc '0-9' <<< "$VM_OUT")"
            if [[ -n "$n" ]] && (( n > 20 )); then ok "rechargement-nextcloud" "dump rechargé dans une base jetable (${n} tables)"; else fail "rechargement-nextcloud" "dump rechargé mais seulement ${n:-0} tables"; fi
        else
            fail "rechargement-nextcloud" "échec du rechargement dans la base jetable"
        fi
    fi

    f="$(ls -1t "$DUMPDIR/syncin"/*.sql.gz 2>/dev/null | head -n 1)"
    if [[ -n "$f" ]]; then
        vf="${DOCKER_APPS_MOUNT}/backups/db/syncin/$(basename "$f")"
        if vm_exec "set -e; cid=\$(docker run -d --rm -e MARIADB_ROOT_PASSWORD=t mariadb:11); trap 'docker rm -f \$cid >/dev/null 2>&1' EXIT; for i in \$(seq 40); do docker exec \$cid healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break; sleep 2; done; zcat '${vf}' | docker exec -i \$cid mariadb -uroot -pt >/dev/null 2>&1 || true; docker exec \$cid mariadb -uroot -pt -N -e \"select count(*) from information_schema.tables where table_schema='syncin'\"" 1200; then
            n="$(tr -dc '0-9' <<< "$VM_OUT")"
            if [[ -n "$n" ]] && (( n > 5 )); then ok "rechargement-syncin" "dump rechargé dans une base jetable (${n} tables)"; else fail "rechargement-syncin" "dump rechargé mais seulement ${n:-0} tables"; fi
        else
            fail "rechargement-syncin" "échec du rechargement dans la base jetable"
        fi
    fi
fi

# ---- 4. Copie hors site : un fichier témoin revient identique ----------------------
if [[ -n "${BACKUP_RESTIC_REPO:-}" && -x /usr/local/sbin/homelab-offsite-backup.sh ]]; then
    tmp="$(mktemp -d)"
    export RESTIC_REPOSITORY="$BACKUP_RESTIC_REPO" RESTIC_PASSWORD_FILE=/root/.config/homelab/restic-password
    opt=()
    sftp_cmd="$(grep -o "sftp.command='[^']*'" /usr/local/sbin/homelab-offsite-backup.sh | head -n 1 | sed "s/^sftp.command='//; s/'\$//")"
    [[ -n "$sftp_cmd" ]] && opt=(-o "sftp.command=${sftp_cmd}")
    # Un fichier témoin par site (SITE_APPS_DIRS = « domaine|dossier apps » ; sans la liste : site principal seulement).
    for _s in ${SITE_APPS_DIRS:-${DOMAIN}|${APPS_DIR}}; do
        _dom="${_s%%|*}"; _apps="${_s#*|}"
        [[ -f "${_apps}/00_temoin/temoin.docx" ]] || { fail "restic-temoin ${_dom}" "fichier témoin absent (${_apps}/00_temoin)"; continue; }
        rm -rf "$tmp"; tmp="$(mktemp -d)"
        if restic "${opt[@]}" restore latest --target "$tmp" --include "${_apps}/00_temoin" >/dev/null 2>&1 \
            && [[ -f "${tmp}${_apps}/00_temoin/temoin.docx" ]] \
            && cmp -s "${tmp}${_apps}/00_temoin/temoin.docx" "${_apps}/00_temoin/temoin.docx"; then
            ok "restic-temoin ${_dom}" "fichier témoin restauré depuis la copie hors site, identique"
        else
            fail "restic-temoin ${_dom}" "restauration du fichier témoin depuis restic impossible ou différente"
        fi
    done
    rm -rf "$tmp"
fi

# ---- Bilan ---------------------------------------------------------------------
printf '%s\n' "${results[@]}" > "$STATUS"
nfail="$(grep -c '|FAIL|' "$STATUS" || true)"
nok="$(grep -c '|OK|' "$STATUS" || true)"

if (( nfail > 0 )); then
    /usr/local/sbin/homelab-notify -p high -t warning,rotating_light "Test de restauration : ${nfail} échec(s)" \
        "$(grep '|FAIL|' "$STATUS" | cut -d'|' -f1,4 | tr '|' ':' | head -n 8)"
    exit 1
fi

/usr/local/sbin/homelab-notify -p low -t white_check_mark "Test de restauration réussi" "${nok} contrôles OK (archives, restauration de CT, dumps, rechargement des bases)."
exit 0
RT_EOF
    chmod 755 /usr/local/sbin/homelab-restore-test

    cat > /etc/systemd/system/homelab-restore-test.service <<'EOF'
[Unit]
Description=Test de restauration du homelab

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-restore-test
Nice=10
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/homelab-restore-test.timer <<EOF
[Unit]
Description=Test de restauration mensuel du homelab

[Timer]
OnCalendar=${RESTORE_TEST_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

configure_restore_test() {

    [[ "$ENABLE_RESTORE_TEST" == "true" ]] || { info "Test de restauration : ENABLE_RESTORE_TEST=false, ignoré."; return 0; }
    [[ "$ENABLE_BACKUP" == "true" ]] || { info "Test de restauration : ENABLE_BACKUP=false, rien à tester."; return 0; }

    info "Test de restauration mensuel (${RESTORE_TEST_CALENDAR})..."

    command -v zstd >/dev/null 2>&1 || apt-get install -y zstd >/dev/null 2>&1 || warn "zstd indisponible : vérification des archives .zst impossible."

    write_homelab_runtime_conf
    install_restore_test_script

    systemctl daemon-reload
    systemctl enable --now homelab-restore-test.timer >/dev/null 2>&1 || warn "Timer homelab-restore-test non activé."

    info "Test de restauration : lance un essai avec  ./install.sh --run restore_test_now  (journal : /var/log/homelab-restore-test.log)."
}

# ./install.sh --run restore_test_now
restore_test_now() {

    [[ -x /usr/local/sbin/homelab-restore-test ]] || die "Test de restauration non installé (./install.sh --run configure_restore_test)."
    /usr/local/sbin/homelab-restore-test
}

# ./install.sh --run restore_test_status
restore_test_status() {
    column -s'|' -t /var/lib/homelab/restore-test.status 2>/dev/null || echo "(aucun test réalisé)"
}

# ---- Mises à jour Docker ----------------------------------------------------------

install_docker_update_script() {

    cat > /usr/local/sbin/homelab-docker-update <<'DU_EOF'
#!/usr/bin/env bash
# Mises à jour des images Docker du homelab.
#   homelab-docker-update            selon DOCKER_UPDATE_MODE (notify | safe | off)
#   homelab-docker-update --check    télécharge et signale, ne redémarre rien
#   homelab-docker-update --apply <projet>   dump des bases, puis pull + up -d du projet
#   homelab-docker-update --list     projets connus
set -uo pipefail

CONF=/etc/homelab/homelab.conf
. "$CONF" || exit 1
LOG=/var/log/homelab-docker-update.log
exec > >(tee -a "$LOG") 2>&1

gexec() {   # kind id timeout commande -> sortie sur stdout, code retour = celui de la commande
    local kind="$1" id="$2" to="$3" cmd="$4" raw code
    if [[ "$kind" == "ct" ]]; then
        timeout "$to" pct exec "$id" -- bash -c "$cmd"
    else
        raw="$(qm guest exec "$id" --timeout "$to" -- bash -c "$cmd" 2>&1)" || true
        jq -r '.["out-data"] // empty' <<< "$raw" 2>/dev/null
        code="$(jq -r 'if .exitcode == null then 1 else .exitcode end' <<< "$raw" 2>/dev/null || echo 1)"
        return "$code"
    fi
}

CHECK_CMD='cd "$D" || exit 3
docker compose pull -q --ignore-buildable >/dev/null 2>&1 || exit 4
docker compose build --pull -q >/dev/null 2>&1 || true
for c in $(docker compose ps -q); do
  ref=$(docker inspect -f "{{.Config.Image}}" "$c"); cur=$(docker inspect -f "{{.Image}}" "$c")
  new=$(docker image inspect -f "{{.Id}}" "$ref" 2>/dev/null)
  [ -n "$new" ] && [ "$cur" != "$new" ] && echo "$ref"
done
exit 0'

APPLY_CMD='cd "$D" || exit 3
docker compose pull -q --ignore-buildable >/dev/null 2>&1 || true
docker compose build --pull -q >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1 || exit 5
sleep 20
bad=$(docker compose ps --status exited --status restarting -q 2>/dev/null | wc -l)
docker image prune -f >/dev/null 2>&1
docker builder prune -f --filter until=72h >/dev/null 2>&1
[ "$bad" = "0" ] || { echo "$bad conteneur(s) arrêté(s) ou en boucle"; exit 6; }
exit 0'

mode="${DOCKER_UPDATE_MODE:-notify}"
action="auto" target=""
case "${1:-}" in
    --check) action=check ;;
    --apply) action=apply; target="${2:-}" ;;
    --list) action=list ;;
esac

[[ "$action" == "auto" && "$mode" == "off" ]] && exit 0

echo "=== $(date -Is) docker-update (${action}, mode ${mode}) ==="

updates=() applied=() failed=()

while IFS=: read -r kind id dir cls; do
    [[ -n "$kind" ]] || continue
    name="$(basename "$dir")"

    if [[ "$action" == "list" ]]; then echo "${name}  (${kind} ${id}, ${dir}, ${cls})"; continue; fi
    [[ "$action" == "apply" && "$name" != "$target" ]] && continue

    if [[ "$action" == "apply" ]]; then
        [[ "$cls" == "manual" ]] && /usr/local/sbin/homelab-db-dump >/dev/null 2>&1 || true
        if out="$(gexec "$kind" "$id" 1800 "D='${dir}'; ${APPLY_CMD}")"; then
            applied+=("$name")
        else
            failed+=("$name : ${out:-échec}")
        fi
        continue
    fi

    out="$(gexec "$kind" "$id" 1800 "D='${dir}'; ${CHECK_CMD}")" || { echo "$name : contrôle impossible"; continue; }
    [[ -n "$out" ]] || { echo "$name : à jour"; continue; }

    img="$(tr '\n' ' ' <<< "$out")"
    echo "$name : mise à jour disponible (${img})"

    if [[ "$action" == "auto" && "$mode" == "safe" && "$cls" == "safe" ]]; then
        if o2="$(gexec "$kind" "$id" 1800 "D='${dir}'; ${APPLY_CMD}")"; then
            applied+=("$name")
        else
            failed+=("$name : ${o2:-échec}")
        fi
    else
        updates+=("${name} (${img% })")
    fi
done <<< "${DOCKER_UPDATE_PROJECTS:-}"

[[ "$action" == "list" ]] && exit 0

if [[ "$action" == "apply" && ${#applied[@]} -eq 0 && ${#failed[@]} -eq 0 ]]; then
    echo "Projet inconnu : ${target} (voir --list)"; exit 2
fi

if (( ${#applied[@]} > 0 )); then
    /usr/local/sbin/homelab-notify -p low -t arrow_up "Docker : mis à jour" "Appliqué : ${applied[*]}"
fi
if (( ${#failed[@]} > 0 )); then
    /usr/local/sbin/homelab-notify -p high -t warning "Docker : échec de mise à jour" "${failed[*]}"
    exit 1
fi
if (( ${#updates[@]} > 0 )); then
    /usr/local/sbin/homelab-notify -p default -t package "Docker : mises à jour disponibles" \
        "${updates[*]} — à appliquer : homelab-docker-update --apply <projet> (dump des bases inclus)."
fi
exit 0
DU_EOF
    chmod 755 /usr/local/sbin/homelab-docker-update

    cat > /etc/systemd/system/homelab-docker-update.service <<'EOF'
[Unit]
Description=Mises à jour des images Docker du homelab

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-docker-update
Nice=10
EOF

    cat > /etc/systemd/system/homelab-docker-update.timer <<EOF
[Unit]
Description=Mises à jour des images Docker (hebdomadaire)

[Timer]
OnCalendar=${DOCKER_UPDATE_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

configure_docker_update() {

    if [[ "$DOCKER_UPDATE_MODE" == "off" ]]; then
        systemctl disable --now homelab-docker-update.timer >/dev/null 2>&1 || true
        info "Mises à jour Docker : DOCKER_UPDATE_MODE=off."
        return 0
    fi

    case "$DOCKER_UPDATE_MODE" in notify | safe) ;; *) die "DOCKER_UPDATE_MODE='${DOCKER_UPDATE_MODE}' invalide (off | notify | safe)." ;; esac

    if [[ -z "$(docker_update_projects)" ]]; then
        info "Mises à jour Docker : aucun projet Docker installé."
        return 0
    fi

    info "Mises à jour des images Docker : mode ${DOCKER_UPDATE_MODE}, ${DOCKER_UPDATE_CALENDAR}..."

    write_homelab_runtime_conf
    install_docker_update_script

    systemctl daemon-reload
    systemctl enable --now homelab-docker-update.timer >/dev/null 2>&1 || warn "Timer homelab-docker-update non activé."

    info "Mises à jour Docker : ./install.sh --run docker_update_check | docker_update_apply <projet> | docker_update_list"
}

docker_update_check() {
    [[ -x /usr/local/sbin/homelab-docker-update ]] || die "Non installé (./install.sh --run configure_docker_update)."
    /usr/local/sbin/homelab-docker-update --check
}

docker_update_list() {
    [[ -x /usr/local/sbin/homelab-docker-update ]] || die "Non installé (./install.sh --run configure_docker_update)."
    /usr/local/sbin/homelab-docker-update --list
}

# ./install.sh --run docker_update_apply <projet>   (ex. nextcloud, immich, jellyfin, swag)
docker_update_apply() {
    [[ -n "${1:-}" ]] || die "usage : docker_update_apply <projet> (voir docker_update_list)"
    [[ -x /usr/local/sbin/homelab-docker-update ]] || die "Non installé (./install.sh --run configure_docker_update)."
    /usr/local/sbin/homelab-docker-update --apply "$1"
}

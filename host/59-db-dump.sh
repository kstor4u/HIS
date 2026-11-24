###############################################################################
#            DUMP DES BASES DE DONNÉES AVANT CHAQUE SAUVEGARDE                #
###############################################################################

# Pourquoi : une sauvegarde de VM "à chaud" copie les fichiers d'une base en cours d'écriture ;
# elle est en général récupérable (journal de la base) mais sans garantie. Un dump logique
# (pg_dump, mariadb-dump, mongodump) est cohérent, portable et restaurable sur une autre
# machine, et il est tiré par le serveur de sauvegarde avec le reste de APPS_DIR.
#
#  - Hook vzdump (/etc/vzdump.conf : script) : exécuté au début de la tâche homelab-daily.
#    Il ne bloque JAMAIS la sauvegarde (toute erreur est notifiée, le script rend 0).
#  - Sortie : ${APPS_DIR}/backups/db/<cible>/<cible>-AAAAMMJJ-HHMMSS.*  (DB_DUMP_KEEP derniers).
#  - État : /var/lib/homelab/db-dump.status ; échec => notification (ntfy) + alerte de santé.
#  - À la main : ./install.sh --run db_dump_now [cible...]   (cibles : voir db_dump_targets)
#  - Restauration : ./install.sh --run db_restore_help

# Cibles actives, séparées par des espaces.
db_dump_targets() {

    local -a t=()

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        [[ "${ENABLE_NEXTCLOUD:-true}" == "true" ]] && t+=(nextcloud)
        t+=(syncin)
        [[ "$ENABLE_IMMICH" == "true" ]] && t+=(immich)
        [[ "${ENABLE_ARR:-false}" == "true" ]] && t+=(arr)
    fi

    [[ "$ENABLE_NODE" == "true" ]] && t+=(mongo)
    [[ "$ENABLE_MAIL" == "true" ]] && t+=(mail-config)
    [[ "$ENABLE_DNS" == "true" ]] && t+=(dns-config)
    [[ "${ENABLE_MONITOR:-false}" == "true" ]] && t+=(monitor)

    printf '%s' "${t[*]:-}"
}

install_db_dump_script() {

    cat > /usr/local/sbin/homelab-db-dump <<'DUMP_EOF'
#!/usr/bin/env bash
# Dump logique des bases du homelab. Usage : homelab-db-dump [cible...]  (sans argument : toutes)
set -uo pipefail

CONF=/etc/homelab/homelab.conf
. "$CONF" || exit 1

OUT="${APPS_DIR}/backups/db"
VMOUT="${DOCKER_APPS_MOUNT}/backups/db"       # même dossier, vu depuis la VM DOCKER (VirtioFS)
STATUS=/var/lib/homelab/db-dump.status
TS="$(date +%Y%m%d-%H%M%S)"
KEEP="${DB_DUMP_KEEP:-7}"
LOCK=/var/lock/homelab-db-dump.lock

exec 9> "$LOCK"
flock -n 9 || { echo "Un dump est déjà en cours."; exit 0; }

mkdir -p "$OUT"
chmod 750 "$OUT" "${APPS_DIR}/backups" 2>/dev/null || true
umask 077

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || read -ra targets <<< "${DB_DUMP_TARGETS:-}"

declare -A result=()
failed=()

# Exécute une commande dans la VM DOCKER (bash -c). Échoue si le code retour n'est pas 0.
vm_exec() {
    local raw code
    raw="$(qm guest exec "$DOCKER_ID" --timeout "${2:-1800}" -- bash -c "$1" 2>&1)" || true
    code="$(jq -r 'if .exitcode == null then 1 else .exitcode end' <<< "$raw" 2>/dev/null || echo 1)"
    if [[ "$code" != "0" ]]; then
        jq -r '.["err-data"] // empty' <<< "$raw" 2>/dev/null | tail -n 5 >&2
        return 1
    fi
}

finish_file() {   # $1 = dossier cible, $2 = fichier ; contrôle de base puis rotation
    local dir="$1" f="$2"
    [[ -s "$f" ]] || return 1
    case "$f" in
        *.gz | *.tgz) gzip -t "$f" 2>/dev/null || return 1 ;;
    esac
    chmod 600 "$f"
    ls -1t "$dir"/* 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f --
    return 0
}

dump_one() {

    local t="$1" dir="$OUT/$1" f

    mkdir -p "$dir"

    case "$t" in

        nextcloud)
            f="$dir/nextcloud-${TS}.sql.gz"
            vm_exec "set -o pipefail; mkdir -p '${VMOUT}/nextcloud'; docker exec nextcloud-db sh -c 'pg_dump -U \"\$POSTGRES_USER\" --clean --if-exists \"\$POSTGRES_DB\"' | gzip > '${VMOUT}/nextcloud/nextcloud-${TS}.sql.gz'" || return 1
            ;;

        syncin)
            f="$dir/syncin-${TS}.sql.gz"
            vm_exec "set -o pipefail; mkdir -p '${VMOUT}/syncin'; docker exec syncin-db sh -c 'mariadb-dump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --all-databases --single-transaction --routines' | gzip > '${VMOUT}/syncin/syncin-${TS}.sql.gz'" || return 1
            ;;

        immich)
            f="$dir/immich-${TS}.sql.gz"
            vm_exec "set -o pipefail; mkdir -p '${VMOUT}/immich'; docker exec immich-db sh -c 'pg_dumpall --clean --if-exists -U \"\$POSTGRES_USER\"' | gzip > '${VMOUT}/immich/immich-${TS}.sql.gz'" || return 1
            ;;

        arr)
            # Bases SQLite des *arr : arrêt de quelques secondes pour une copie cohérente.
            f="$dir/arr-${TS}.tgz"
            vm_exec "set -e; cd /opt/apps/arr; docker compose stop >/dev/null 2>&1 || true; tar czf '${VMOUT}/arr-${TS}.tgz.part' --exclude=gluetun/servers.json . ; docker compose start >/dev/null 2>&1 || true; mkdir -p '${VMOUT}/arr'; mv '${VMOUT}/arr-${TS}.tgz.part' '${VMOUT}/arr/arr-${TS}.tgz'" 600 || return 1
            ;;

        mongo)
            f="$dir/mongo-${TS}.archive.gz"
            pct exec "$NODE_ID" -- bash -c 'cd /opt/node && set -a && . ./.env && set +a && docker exec mongo mongodump --username "$MONGO_ADMIN_USER" --password "$MONGO_ADMIN_PASSWORD" --authenticationDatabase admin --archive --gzip' > "$f" || return 1
            ;;

        mail-config)
            f="$dir/mail-config-${TS}.tgz"
            pct exec "$MAIL_ID" -- tar czf - -C /opt/mail . > "$f" || return 1
            ;;

        dns-config)
            f="$dir/dns-config-${TS}.tgz"
            pct exec "$DNS_ID" -- tar czf - -C /opt/AdGuardHome AdGuardHome.yaml > "$f" || return 1
            ;;

        monitor)
            f="$dir/monitor-${TS}.tgz"
            pct exec "$MONITOR_ID" -- bash -c 'cd /opt/monitor && docker compose stop >/dev/null 2>&1; tar czf - . ; docker compose start >/dev/null 2>&1' > "$f" || return 1
            ;;

        *)
            echo "cible inconnue : $t" >&2
            return 1
            ;;
    esac

    finish_file "$dir" "$f" || { rm -f "$f"; return 1; }

    # Pour les dumps réalisés depuis la VM, le fichier est déjà dans $dir (même dossier).
    printf '%s' "$f"
}

for t in "${targets[@]}"; do

    echo "dump : ${t}..."

    if f="$(dump_one "$t" 2> >(tee -a /var/log/homelab-db-dump.log >&2))" && [[ -n "$f" ]]; then
        result["$t"]="${t}|OK|$(date +%s)|${f}|$(stat -c %s "$f")"
        echo "  OK $(basename "$f") ($(numfmt --to=iec "$(stat -c %s "$f")"))"
    else
        result["$t"]="${t}|FAIL|$(date +%s)|échec du dump|0"
        failed+=("$t")
        echo "  ÉCHEC"
    fi
done

# Fusionne avec l'état précédent (les cibles non relancées gardent leur ligne).
{
    for t in "${targets[@]}"; do echo "${result[$t]}"; done
    [[ -r "$STATUS" ]] && grep -v -E "^($(IFS='|'; echo "${targets[*]}"))\|" "$STATUS"
} > "${STATUS}.new" 2>/dev/null
mv "${STATUS}.new" "$STATUS"

if (( ${#failed[@]} > 0 )); then
    /usr/local/sbin/homelab-notify -p high -t warning,floppy_disk "Dump des bases : échec" "Cibles en échec : ${failed[*]} (voir /var/log/homelab-db-dump.log)."
    exit 1
fi
exit 0
DUMP_EOF
    chmod 755 /usr/local/sbin/homelab-db-dump

    cat > /usr/local/sbin/homelab-vzdump-hook <<'HOOK_EOF'
#!/usr/bin/env bash
# Hook vzdump : dump des bases au démarrage de la tâche + alertes (début, fin avec le détail par
# VM/CT). Ne bloque jamais la sauvegarde.
phase="${1:-}"
STATE=/run/homelab-vzdump.state
N=/usr/local/sbin/homelab-notify

summary() {
    awk -F'|' -v start="$(cat "${STATE}.start" 2>/dev/null || date +%s)" -v now="$(date +%s)" '
        function h(b) { return (b >= 1073741824) ? sprintf("%.1f Gio", b/1073741824) : sprintf("%.0f Mio", b/1048576) }
        { n++; if ($1 == "FAIL") { f++; printf "  ÉCHEC  %s %s\n", $2, $3 } else { printf "  OK     %s %s : %s\n", $2, $3, h($4); tot += $4 } }
        END { if (n == 0) print "  (aucun détail)"; printf "Total : %s · durée %d min · %d échec(s)\n", h(tot), (now-start)/60, f }' "$STATE" 2>/dev/null
}

case "$phase" in
    job-start)
        : > "$STATE"; date +%s > "${STATE}.start"
        [[ -x "$N" ]] && "$N" -p default -t floppy_disk -c backup "Sauvegarde vzdump démarrée" "Stockage ${STOREID:-?} ($(hostname -s))." || true
        /usr/local/sbin/homelab-db-dump >> /var/log/homelab-db-dump.log 2>&1 || true ;;
    backup-end)
        printf 'OK|%s|%s|%s\n' "${3:-?}" "${HOSTNAME:-}" "$(stat -c %s "${TARGET:-/nonexistent}" 2>/dev/null || echo 0)" >> "$STATE" ;;
    backup-abort)
        printf 'FAIL|%s|%s|0\n' "${3:-?}" "${HOSTNAME:-}" >> "$STATE" ;;
    job-end)
        if [[ -x "$N" ]]; then
            s="$(summary)"
            if grep -q 'ÉCHEC' <<< "$s"; then "$N" -p high -t warning -c backup "Sauvegarde vzdump terminée avec ÉCHEC" "$s" || true
            else "$N" -p default -t white_check_mark -c backup "Sauvegarde vzdump terminée" "$s" || true; fi
        fi ;;
    job-abort)
        [[ -x "$N" ]] && "$N" -p high -t warning -c backup "Sauvegarde vzdump INTERROMPUE" "$(summary)" || true ;;
esac
exit 0
HOOK_EOF
    chmod 755 /usr/local/sbin/homelab-vzdump-hook
}

configure_db_dump() {

    [[ "$ENABLE_DB_DUMP" == "true" ]] || { info "Dump des bases : ENABLE_DB_DUMP=false, ignoré."; return 0; }

    if [[ -z "$(db_dump_targets)" ]]; then
        info "Dump des bases : aucune base à sauvegarder."
        return 0
    fi

    info "Dump des bases avant sauvegarde (cibles : $(db_dump_targets))..."

    install -d -m 0755 /var/lib/homelab
    local _s
    for _s in $(sites_apps_list); do   # un dossier de dumps par site (les bases par site arrivent avec leurs applications)
        mkdir -p "${_s#*|}/backups/db"
        chmod 750 "${_s#*|}/backups" "${_s#*|}/backups/db"
    done

    install_db_dump_script
    write_homelab_runtime_conf

    # Hook vzdump global (une seule ligne "script:" dans /etc/vzdump.conf).
    touch /etc/vzdump.conf
    if grep -q '^script:' /etc/vzdump.conf; then
        sed -i 's|^script:.*|script: /usr/local/sbin/homelab-vzdump-hook|' /etc/vzdump.conf
    else
        printf 'script: /usr/local/sbin/homelab-vzdump-hook\n' >> /etc/vzdump.conf
    fi

    info "Dump des bases : hook vzdump installé (dumps dans ${APPS_DIR}/backups/db, ${DB_DUMP_KEEP} conservés par cible)."
    info "Dump des bases : essai immédiat avec  ./install.sh --run db_dump_now"
}

# ./install.sh --run db_dump_now [cible...]
db_dump_now() {

    [[ -x /usr/local/sbin/homelab-db-dump ]] || die "Dump non installé (./install.sh --run configure_db_dump)."
    /usr/local/sbin/homelab-db-dump "$@"
}

# ./install.sh --run db_dump_status
db_dump_status() {

    echo "--- Dernier état par cible"
    column -s'|' -t /var/lib/homelab/db-dump.status 2>/dev/null || echo "(aucun dump encore réalisé)"
    local _s
    for _s in $(sites_apps_list); do
        echo "--- Fichiers, site ${_s%%|*} (${_s#*|}/backups/db)"
        ls -lh "${_s#*|}/backups/db"/* 2>/dev/null | head -n 40 || true
    done
}

# Mémo de restauration (ne modifie rien).
db_restore_help() {

    cat <<EOF
Restauration d'un dump (exemples, à adapter ; les dumps sont dans ${APPS_DIR}/backups/db/<cible>/) :

  Nextcloud (VM ${DOCKER_ID}) :
    zcat nextcloud-AAAA.sql.gz | docker exec -i nextcloud-db sh -c 'psql -U "\$POSTGRES_USER" "\$POSTGRES_DB"'
    (avant : docker exec -u www-data nextcloud php occ maintenance:mode --on ; après : --off)

  Sync-in (VM ${DOCKER_ID}) :
    zcat syncin-AAAA.sql.gz | docker exec -i syncin-db sh -c 'mariadb -uroot -p"\$MARIADB_ROOT_PASSWORD"'

  Immich (VM ${DOCKER_ID}) : arrêter immich-server puis
    zcat immich-AAAA.sql.gz | docker exec -i immich-db sh -c 'psql -U "\$POSTGRES_USER" -d postgres'

  MongoDB (CT ${NODE_ID}) :
    docker exec -i mongo sh -c 'mongorestore -u "\$MONGO_INITDB_ROOT_USERNAME" -p "\$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --drop' < mongo-AAAA.archive.gz

  Configurations (*arr, monitor, mail-config, dns-config) : arrêter le compose, extraire l'archive .tgz
  dans le dossier d'origine (/opt/apps/arr, /opt/monitor, /opt/mail, /opt/AdGuardHome), redémarrer.

Le test automatique mensuel recharge réellement les dumps Nextcloud et Sync-in dans une base jetable :
  ./install.sh --run restore_test_now
EOF
}

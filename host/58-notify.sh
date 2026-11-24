###############################################################################
#        NOTIFICATIONS, SURVEILLANCE DE L'HÔTE (SMART, DISQUES, SERVICES)     #
###############################################################################

# Fichier de configuration d'exécution lu par les scripts installés sur l'hôte
# (/usr/local/sbin/homelab-*). Il est RÉGÉNÉRÉ à chaque installation ou par
# ./install.sh --run configure_notify : ne le modifie pas à la main.
HOMELAB_RUNTIME_CONF="/etc/homelab/homelab.conf"

# URL interne de ntfy (CT MONITOR) ou URL fournie (NOTIFY_NTFY_URL), sinon vide.
notify_ntfy_url() {

    if [[ -n "${NOTIFY_NTFY_URL:-}" ]]; then
        printf '%s' "$NOTIFY_NTFY_URL"
    elif [[ "${ENABLE_MONITOR:-false}" == "true" && "${MONITOR_NTFY:-true}" == "true" ]]; then
        printf 'http://%s:%s' "${MONITOR_IP%%/*}" "$NTFY_PORT"
    fi
}

# Adresses (nom|url) surveillées par le script de santé : celles qui existent vraiment.
health_url_list() {

    local ip

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        ip="${DOCKER_IP%%/*}"
        [[ "$ENABLE_NEXTCLOUD" != "false" ]] && printf 'Nextcloud|http://%s:%s/status.php\n' "$ip" "$NEXTCLOUD_HTTP_PORT"
        printf 'Sync-in|http://%s:%s/\n' "$ip" "$SYNCIN_HTTP_PORT"
        [[ "$ENABLE_IMMICH" == "true" ]] && printf 'Immich|http://%s:%s/api/server/ping\n' "$ip" "$IMMICH_HTTP_PORT"
        [[ "$ENABLE_HOMEASSISTANT" == "true" ]] && printf 'Home Assistant|http://%s:%s/\n' "$ip" "$HOMEASSISTANT_HTTP_PORT"
        [[ "$ENABLE_JELLYFIN" == "true" ]] && printf 'Jellyfin|http://%s:%s/health\n' "$ip" "$JELLYFIN_HTTP_PORT"
    fi

    [[ "$ENABLE_SWAG" == "true" ]] && printf 'SWAG (HTTPS)|https://%s/\n' "${SWAG_IP%%/*}"
    [[ "$ENABLE_NODE" == "true" ]] && printf 'Node|http://%s:%s/\n' "${NODE_IP%%/*}" "$NODE_HTTP_PORT"
    [[ "$ENABLE_DNS" == "true" ]] && printf 'DNS (AdGuard Home)|http://%s/\n' "${DNS_IP%%/*}"

    if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
        [[ "$MONITOR_KUMA" == "true" ]] && printf 'Uptime Kuma|http://%s:%s/\n' "${MONITOR_IP%%/*}" "$KUMA_PORT"
        [[ "$MONITOR_NTFY" == "true" ]] && printf 'ntfy|http://%s:%s/v1/health\n' "${MONITOR_IP%%/*}" "$NTFY_PORT"
        [[ "$MONITOR_HOMEPAGE" == "true" ]] && printf 'Homepage|http://%s:%s/\n' "${MONITOR_IP%%/*}" "$HOMEPAGE_PORT"
    fi

    if [[ "${ENABLE_ARR:-false}" == "true" && "$ENABLE_DOCKER" == "true" ]]; then
        ip="${DOCKER_IP%%/*}"
        printf 'Sonarr|http://%s:%s/ping\n' "$ip" "$SONARR_PORT"
        printf 'Radarr|http://%s:%s/ping\n' "$ip" "$RADARR_PORT"
        printf 'Prowlarr|http://%s:%s/ping\n' "$ip" "$PROWLARR_PORT"
    fi
}

# Invités (VM/CT) installés : "vm:ID" ou "ct:ID".
health_guest_list() {

    [[ "$ENABLE_SWAG" == "true" ]]      && printf 'ct:%s\n' "$SWAG_ID"
    [[ "$ENABLE_DOCKER" == "true" ]]    && printf 'vm:%s\n' "$DOCKER_ID"
    [[ "$ENABLE_FILES" == "true" ]]     && printf 'vm:%s\n' "$FILES_ID"
    [[ "$ENABLE_WIREGUARD" == "true" ]] && printf 'ct:%s\n' "$WG_ID"
    [[ "$ENABLE_NODE" == "true" ]]      && printf 'ct:%s\n' "$NODE_ID"
    [[ "$ENABLE_MAIL" == "true" ]]      && printf 'ct:%s\n' "$MAIL_ID"
    [[ "$ENABLE_DNS" == "true" ]]       && printf 'ct:%s\n' "$DNS_ID"
    [[ "${ENABLE_MONITOR:-false}" == "true" ]] && printf 'ct:%s\n' "$MONITOR_ID"
    [[ "$ENABLE_XMRIG" == "true" ]]     && printf 'ct:%s\n' "$XMRIG_ID"

    return 0
}

# Écrit /etc/homelab/homelab.conf (0600 : contient le jeton ntfy).
write_homelab_runtime_conf() {

    install -d -m 0755 /etc/homelab /var/lib/homelab

    local f="$HOMELAB_RUNTIME_CONF" tmp
    tmp="$(mktemp)"

    {
        echo "# Généré par l'installateur homelab (v${SCRIPT_VERSION}) : ne pas modifier."
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'DATA_MOUNT=%q\n' "$DATA_MOUNT"
        printf 'SHARED_DIR=%q\n' "$SHARED_DIR"
        printf 'APPS_DIR=%q\n' "$APPS_DIR"
        printf 'SITE_APPS_DIRS=%q\n' "$(sites_apps_list)"
        printf 'PROXMOX_DATA_DIR=%q\n' "$PROXMOX_DATA_DIR"
        printf 'BACKUP_STORAGE=%q\n' "$BACKUP_STORAGE"
        printf 'ENABLE_BACKUP=%q\n' "$ENABLE_BACKUP"
        printf 'BACKUP_RESTIC_REPO=%q\n' "$BACKUP_RESTIC_REPO"
        printf 'SWAG_ID=%q\nDOCKER_ID=%q\nFILES_ID=%q\nWG_ID=%q\nNODE_ID=%q\nMAIL_ID=%q\nDNS_ID=%q\nMONITOR_ID=%q\nXMRIG_ID=%q\n' \
            "$SWAG_ID" "$DOCKER_ID" "$FILES_ID" "$WG_ID" "$NODE_ID" "$MAIL_ID" "$DNS_ID" "$MONITOR_ID" "$XMRIG_ID"
        printf 'ENABLE_SWAG=%q\nENABLE_DOCKER=%q\nENABLE_FILES=%q\nENABLE_NODE=%q\nENABLE_MAIL=%q\nENABLE_DNS=%q\nENABLE_MONITOR=%q\nENABLE_ARR=%q\nENABLE_CROWDSEC=%q\n' \
            "$ENABLE_SWAG" "$ENABLE_DOCKER" "$ENABLE_FILES" "$ENABLE_NODE" "$ENABLE_MAIL" "$ENABLE_DNS" "${ENABLE_MONITOR:-false}" "${ENABLE_ARR:-false}" "${ENABLE_CROWDSEC:-false}"
        printf 'ENABLE_IMMICH=%q\nENABLE_NEXTCLOUD=%q\n' "$ENABLE_IMMICH" "${ENABLE_NEXTCLOUD:-true}"
        printf 'DOCKER_APPS_MOUNT=%q\n' "$DOCKER_APPS_MOUNT"
        printf 'NTFY_URL=%q\nNTFY_TOPIC=%q\nNTFY_TOKEN=%q\n' "$(notify_ntfy_url)" "$NOTIFY_NTFY_TOPIC" "${NOTIFY_NTFY_TOKEN:-}"
        printf 'KUMA_PUSH_URL=%q\n' "${NOTIFY_KUMA_PUSH_URL:-}"
        printf 'DB_DUMP_KEEP=%q\nDB_DUMP_TARGETS=%q\n' "$DB_DUMP_KEEP" "$(db_dump_targets)"
        printf 'HEALTH_PUBLIC_IP=%q\n' "${HEALTH_PUBLIC_IP:-true}"
        printf 'HEALTH_DISK_PCT=%q\nHEALTH_BACKUP_MAX_H=%q\nHEALTH_DISK_STEP=%q\n' "$HEALTH_DISK_PCT" "$HEALTH_BACKUP_MAX_H" "${HEALTH_DISK_STEP:-10}"
        printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\nTELEGRAM_ALERTS=%q\nXMRIG_ID_RT=%q\n' \
            "${TELEGRAM_BOT_TOKEN:-}" "${TELEGRAM_CHAT_ID:-}" "${TELEGRAM_ALERTS:-miner disk usb backup system network security}" "$XMRIG_ID"
        printf 'TELEGRAM_ACTIONS=%q\nACTIONS_DELAY=%q\n' "${TELEGRAM_ACTIONS:-}" "${TELEGRAM_ACTION_DELAY:-60}"
        printf 'BACKUP_MODE=%q\nBACKUP_COMPRESS=%q\nBACKUP_KEEP=%q\nBACKUP_VMIDS=%q\nBACKUP_SCHEDULE_RT=%q\n' \
            "$BACKUP_MODE" "$BACKUP_COMPRESS" "$BACKUP_KEEP" "$(backup_vmid_list)" "$BACKUP_SCHEDULE"
        printf 'GUEST_MAP=%q\n' "$(guest_map_list | tr '\n' ' ')"
        printf 'HEALTH_GUESTS=%q\n' "$(health_guest_list | tr '\n' ' ')"
        printf 'HEALTH_URLS=%q\n' "$(health_url_list)"
        printf 'RESTORE_TEST_ID=%q\nRESTORE_TEST_STORAGE=%q\nRESTORE_TEST_VERIFY_VM=%q\n' \
            "$RESTORE_TEST_ID" "$RESTORE_TEST_STORAGE" "$RESTORE_TEST_VERIFY_VM"
        printf 'DOCKER_UPDATE_MODE=%q\nDOCKER_UPDATE_PROJECTS=%q\n' "$DOCKER_UPDATE_MODE" "$(docker_update_projects)"
    } > "$tmp"

    install -m 0600 "$tmp" "$f"
    rm -f "$tmp"
}

install_homelab_notify() {

    cat > /usr/local/sbin/homelab-notify <<'NOTIFY_EOF'
#!/usr/bin/env bash
# Envoie une notification : ntfy si configuré, toujours le journal système et /var/log/homelab-notify.log.
# Usage : homelab-notify [-p min|low|default|high|urgent] [-t étiquettes] [-c catégorie] <titre> <message>
# Telegram (si configuré) ne reçoit que les catégories listées dans TELEGRAM_ALERTS (ou « all »).
set -u
CONF=/etc/homelab/homelab.conf
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && . "$CONF"

prio=default tags="" cat=""
while getopts "p:t:c:" o; do
    case "$o" in
        p) prio="$OPTARG" ;;
        t) tags="$OPTARG" ;;
        c) cat="$OPTARG" ;;
        *) ;;
    esac
done
shift $((OPTIND - 1))

title="${1:-homelab}"
msg="${2:-}"

logger -t homelab-notify "[${prio}] ${title} : ${msg}" 2>/dev/null || true
printf '%s [%s] %s : %s\n' "$(date '+%F %T')" "$prio" "$title" "$msg" >> /var/log/homelab-notify.log 2>/dev/null || true

# --- Telegram (jeton passé à curl par stdin : absent de la liste des processus) ---
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    send_tg=0
    case " ${TELEGRAM_ALERTS:-} " in *" all "*) send_tg=1 ;; esac
    [[ -n "$cat" && " ${TELEGRAM_ALERTS:-} " == *" ${cat} "* ]] && send_tg=1
    if (( send_tg )); then
        case "$cat:$tags" in
            miner:*) emoji="⛏️" ;;
            *:*warning*) emoji="⚠️" ;;
            *:*white_check_mark*) emoji="✅" ;;
            *:*tada*) emoji="🎉" ;;
            disk:* | backup:*) emoji="💾" ;;
            usb:*) emoji="💽" ;;
            system:*) emoji="🟢" ;;
            network:*) emoji="🌐" ;;
            *) emoji="🔔" ;;
        esac
        for chat in ${TELEGRAM_CHAT_ID//,/ }; do
            printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
                curl -fsS --max-time 15 -K - --data-urlencode "chat_id=${chat}" \
                    --data-urlencode "text=${emoji} ${title}"$'\n'"${msg}" > /dev/null 2>&1 \
                || echo "homelab-notify : échec de l'envoi Telegram (${chat})" >&2
        done
    fi
fi

[[ -n "${NTFY_URL:-}" ]] || exit 0

case "$prio" in
    min) p=1 ;; low) p=2 ;; high) p=4 ;; urgent | max) p=5 ;; *) p=3 ;;
esac

esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

tagjson=""
if [[ -n "$tags" ]]; then
    IFS=, read -ra tl <<< "$tags"
    for t in "${tl[@]}"; do tagjson+="${tagjson:+,}\"$(esc "$t")\""; done
fi

body="{\"topic\":\"$(esc "${NTFY_TOPIC:-homelab}")\",\"title\":\"$(esc "$title")\",\"message\":\"$(esc "$msg")\",\"priority\":${p},\"tags\":[${tagjson}]}"

args=(-fsS --max-time 15 -H "Content-Type: application/json")
[[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")

curl "${args[@]}" -d "$body" "${NTFY_URL%/}/" > /dev/null 2>&1 \
    || { echo "homelab-notify : échec de l'envoi ntfy (${NTFY_URL})" >&2; exit 0; }
NOTIFY_EOF
    chmod 755 /usr/local/sbin/homelab-notify

    cat > /usr/local/sbin/homelab-smartd-notify <<'SMART_EOF'
#!/usr/bin/env bash
# Appelé par smartd (-M exec) : transmet l'alerte SMART à homelab-notify.
exec /usr/local/sbin/homelab-notify -p high -t warning,floppy_disk -c smart \
    "SMART : ${SMARTD_DEVICE:-disque} (${SMARTD_FAILTYPE:-alerte})" "${SMARTD_MESSAGE:-alerte SMART}"
SMART_EOF
    chmod 755 /usr/local/sbin/homelab-smartd-notify

    # Alerte de démarrage du serveur (coupure de courant, redémarrage non prévu...)
    cat > /usr/local/sbin/homelab-boot-notify <<'BOOT_EOF'
#!/usr/bin/env bash
# Envoie « serveur démarré » (le réseau peut mettre quelques secondes : 3 essais).
for _ in 1 2 3; do
    last="$(journalctl -b -1 -n 1 -o short-iso --no-pager 2>/dev/null | tail -n 1 | cut -c1-25)"
    /usr/local/sbin/homelab-notify -p default -t tada -c system "Serveur démarré" "$(hostname -s) a démarré (noyau $(uname -r)). Dernière trace du démarrage précédent : ${last:-inconnue}." && exit 0
    sleep 20
done
exit 0
BOOT_EOF
    chmod 755 /usr/local/sbin/homelab-boot-notify

    cat > /etc/systemd/system/homelab-boot-notify.service <<'UNIT'
[Unit]
Description=Alerte de démarrage du homelab
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-boot-notify

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable homelab-boot-notify.service >/dev/null 2>&1 || true
}

# smartd surveille tous les disques (état SMART, secteurs réalloués/en attente, températures)
# et lance un test court chaque nuit à 3h, un test long le 1er du mois à 4h.
configure_smartd() {

    command -v smartd >/dev/null 2>&1 || {
        info "Installation de smartmontools..."
        apt-get install -y smartmontools >/dev/null || { warn "Installation de smartmontools impossible : alertes SMART non configurées."; return 0; }
    }

    if [[ -f /etc/smartd.conf && ! -f /etc/smartd.conf.homelab-orig ]]; then
        cp -a /etc/smartd.conf /etc/smartd.conf.homelab-orig
    fi

    cat > /etc/smartd.conf <<'SMARTD_EOF'
# Généré par l'installateur homelab (original : /etc/smartd.conf.homelab-orig).
# Tous les disques ; veille respectée ; tests courts quotidiens (3h), longs le 1er du mois (4h) ;
# toute alerte est transmise à homelab-notify (ntfy + journal).
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././03|L/../01/./04) -m root -M exec /usr/local/sbin/homelab-smartd-notify
SMARTD_EOF

    systemctl enable smartmontools >/dev/null 2>&1 || systemctl enable smartd >/dev/null 2>&1 || true
    systemctl restart smartmontools >/dev/null 2>&1 || systemctl restart smartd >/dev/null 2>&1 \
        || warn "smartd n'a pas pu être (re)démarré : vérifie systemctl status smartmontools."

    info "SMART : smartd surveille les disques (alertes -> homelab-notify)."
}

install_homelab_health() {

    cat > /usr/local/sbin/homelab-health <<'HEALTH_EOF'
#!/usr/bin/env bash
# Contrôle de santé du homelab (toutes les 10 min) : invités démarrés, services joignables,
# espace disque, RAID/ZFS, fraîcheur des sauvegardes, dump des bases, test de restauration.
# Notifie à l'apparition d'un problème, à sa résolution, puis un rappel toutes les 24 h.
set -u
CONF=/etc/homelab/homelab.conf
. "$CONF" || exit 1

STATE=/var/lib/homelab/health.state
now="$(date +%s)"
declare -A cur=()      # clé -> message
declare -A first=() last=()

add() { cur["$1"]="$2"; }

# Utilisation de / dans un invité : affiche « total_Kio libre_Kio pourcent » (code 1 si indisponible).
guest_root_df() {   # vm|ct id
    local out
    if [[ "$1" == "vm" ]]; then
        qm status "$2" 2>/dev/null | grep -q running || return 1
        out="$(qm guest exec "$2" --timeout 20 -- df -Pk / 2>/dev/null | jq -r '.["out-data"] // empty' 2>/dev/null)"
    else
        pct status "$2" 2>/dev/null | grep -q running || return 1
        out="$(timeout 20 pct exec "$2" -- df -Pk / 2>/dev/null)"
    fi
    awk 'NR==2 {gsub("%","",$5); print $2, $4, $5; ok=1} END {exit !ok}' <<< "$out"
}

# 1. VM/CT démarrés
for g in ${HEALTH_GUESTS:-}; do
    kind="${g%%:*}" id="${g#*:}"
    if [[ "$kind" == "vm" ]]; then st="$(qm status "$id" 2>/dev/null)"; else st="$(pct status "$id" 2>/dev/null)"; fi
    grep -q running <<< "$st" || add "guest-$g" "${kind^^} ${id} n'est pas démarré (${st:-introuvable})."
done

# 2. Services joignables (tout code HTTP < 500 hors 000 = répond)
while IFS='|' read -r name url; do
    [[ -n "$name" ]] || continue
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
    if [[ -z "$code" || "$code" == "000" || "$code" -ge 500 ]]; then
        add "url-$name" "${name} ne répond pas (${url} : HTTP ${code:-aucun})."
    fi
done <<< "${HEALTH_URLS:-}"

# 3. Espace disque
while read -r mp pct_used; do
    [[ -n "$mp" ]] || continue
    (( pct_used >= HEALTH_DISK_PCT )) && add "disk-$mp" "${mp} utilisé à ${pct_used}% (seuil ${HEALTH_DISK_PCT}%)."
done < <(df -P / "${DATA_MOUNT:-/}" 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $6, $5}' | sort -u)

while read -r name used; do
    [[ -n "$name" ]] || continue
    used="${used%%.*}"
    (( used >= HEALTH_DISK_PCT )) && add "storage-$name" "Stockage Proxmox ${name} rempli à ${used}% (seuil ${HEALTH_DISK_PCT}%)."
done < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {gsub("%","",$7); print $1, $7}')

# 3a. Disque des invités : alerte au seuil HEALTH_DISK_PCT
for g in ${HEALTH_GUESTS:-}; do
    gk="${g%%:*}"
    gl="$(guest_root_df "$gk" "${g#*:}")" || continue
    read -r _ _ gpu <<< "$gl"
    [[ "$gpu" =~ ^[0-9]+$ ]] && (( gpu >= HEALTH_DISK_PCT )) && add "guestdisk-$g" "Disque de ${gk^^} ${g#*:} utilisé à ${gpu}% (seuil ${HEALTH_DISK_PCT}%)."
done

# 3b. Paliers de remplissage : une alerte à chaque franchissement d'un multiple de HEALTH_DISK_STEP %
#     (montée) et au retour clairement en dessous (2 % de marge contre les va-et-vient). 0 = désactivé.
STEP="${HEALTH_DISK_STEP:-10}"
if [[ "$STEP" =~ ^[0-9]+$ ]] && (( STEP > 0 && STEP < 100 )); then
    TIER_STATE=/var/lib/homelab/disk-tier.state
    declare -A tier_old=() tier_new=()
    if [[ -r "$TIER_STATE" ]]; then
        while IFS='|' read -r k t; do [[ -n "$k" ]] && tier_old["$k"]="$t"; done < "$TIER_STATE"
    fi

    check_tier() {   # nom, pourcentage, libellé, total (Kio), libre (Kio)
        local k="$1" u="${2%%.*}" label="$3" tot="$4" free="$5" t old detail
        [[ "$u" =~ ^[0-9]+$ ]] || return 0
        t=$(( u / STEP * STEP ))
        old="${tier_old[$k]:-}"
        tier_new["$k"]="${old:-$t}"
        [[ -n "$old" ]] || { tier_new["$k"]="$t"; return 0; }
        detail="$(awk -v f="$free" -v t="$tot" 'BEGIN { printf "%.1f Gio libres sur %.1f Gio", f/1048576, t/1048576 }')"
        if (( t > old )); then
            /usr/local/sbin/homelab-notify -p default -t warning,floppy_disk -c disk "Stockage : palier ${t}% franchi" "${label} est rempli à ${u}% (${detail})."
            tier_new["$k"]="$t"
        elif (( u + 2 <= old )); then
            /usr/local/sbin/homelab-notify -p low -t white_check_mark,floppy_disk -c disk "Stockage : retour sous ${old}%" "${label} est à ${u}% (${detail})."
            tier_new["$k"]="$t"
        fi
    }

    while read -r mp pu tot free; do
        [[ -n "$mp" ]] || continue
        check_tier "fs:${mp}" "${pu%\%}" "Disque ${mp}" "$tot" "$free"
    done < <(df -Pk / "${DATA_MOUNT:-/}" 2>/dev/null | awk 'NR>1 {print $6, $5, $2, $4}' | sort -u)

    while read -r name tot free pu; do
        [[ -n "$name" ]] || continue
        check_tier "pve:${name}" "${pu%\%}" "Stockage Proxmox ${name}" "$tot" "$free"
    done < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1, $4, $6, $7}')

    # Disque racine des invités (VM via l'agent, CT via pct exec) : une VM Docker pleine fait tomber Immich/Postgres.
    for g in ${HEALTH_GUESTS:-}; do
        gk="${g%%:*}" gid="${g#*:}"
        gl="$(guest_root_df "$gk" "$gid")" || continue
        read -r gtot gfree gpu <<< "$gl"
        check_tier "guest:${g}" "$gpu" "Disque de $([[ $gk == vm ]] && echo la VM || echo le CT) ${gid}" "$gtot" "$gfree"
    done

    new_tiers=""
    for k in "${!tier_new[@]}"; do new_tiers+="${k}|${tier_new[$k]}"$'\n'; done
    printf '%s' "$new_tiers" > "$TIER_STATE"
fi

# 4. RAID logiciel / ZFS
if [[ -r /proc/mdstat ]] && grep -Eq '\[[U_]*_[U_]*\]' /proc/mdstat; then
    add "raid" "Grappe RAID dégradée (cat /proc/mdstat)."
fi
if command -v zpool >/dev/null 2>&1 && [[ "$(zpool status -x 2>/dev/null)" != "all pools are healthy" && -n "$(zpool list -H 2>/dev/null)" ]]; then
    add "zfs" "Pool ZFS en défaut (zpool status -x)."
fi

# 5. Sauvegardes
if [[ "${ENABLE_BACKUP:-false}" == "true" ]]; then
    newest="$(find "${PROXMOX_DATA_DIR:-/nonexistent}/dump" -maxdepth 1 -type f \( -name 'vzdump-*.zst' -o -name 'vzdump-*.gz' -o -name 'vzdump-*.lzo' -o -name 'vzdump-*.vma' -o -name 'vzdump-*.tar' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    if [[ -z "$newest" ]]; then
        add "backup-none" "Aucune sauvegarde vzdump trouvée dans ${PROXMOX_DATA_DIR}/dump."
    elif (( now - ${newest%%.*} > HEALTH_BACKUP_MAX_H * 3600 )); then
        add "backup-old" "La dernière sauvegarde vzdump a plus de ${HEALTH_BACKUP_MAX_H} h."
    fi
fi

for f in db-dump restore-test; do
    s="/var/lib/homelab/${f}.status"
    [[ -r "$s" ]] || continue
    grep -q '|FAIL|' "$s" && add "$f" "$(grep '|FAIL|' "$s" | cut -d'|' -f1,4 | tr '|' ' ' | tr '\n' ';')"
done
if [[ -r /var/lib/homelab/restore-test.status ]]; then
    ts="$(stat -c %Y /var/lib/homelab/restore-test.status)"
    (( now - ts > 40 * 86400 )) && add "restore-test-old" "Le test de restauration n'a pas tourné depuis plus de 40 jours."
fi

# 6. IP publique (si elle change : zone DNS, redirection WireGuard, certificats)
if [[ "${HEALTH_PUBLIC_IP:-true}" == "true" ]]; then
    pub="$(curl -s4 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$pub" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        oldpub="$(cat /var/lib/homelab/public-ip 2>/dev/null || true)"
        if [[ -n "$oldpub" && "$oldpub" != "$pub" ]]; then
            /usr/local/sbin/homelab-notify -p high -t warning -c network "IP publique modifiée" "${oldpub} -> ${pub}. Mets à jour tes enregistrements DNS (./install.sh --run dns_zone_generate) et ton DDNS ; le tunnel WireGuard et le serveur de sauvegarde pointent sur cette adresse."
        fi
        printf '%s' "$pub" > /var/lib/homelab/public-ip
    fi
fi

# --- comparaison avec l'état précédent ---
if [[ -r "$STATE" ]]; then
    while IFS='|' read -r k f l; do
        [[ -n "$k" ]] || continue
        first["$k"]="$f"; last["$k"]="$l"
    done < "$STATE"
fi

new_state=""
for k in "${!cur[@]}"; do
    f="${first[$k]:-$now}" l="${last[$k]:-0}"
    if [[ -z "${first[$k]:-}" ]]; then
        /usr/local/sbin/homelab-notify -p high -t warning -c health "Homelab : problème" "${cur[$k]}"
        l="$now"
    elif (( now - l >= 86400 )); then
        /usr/local/sbin/homelab-notify -p default -t warning -c health "Homelab : toujours en défaut" "${cur[$k]}"
        l="$now"
    fi
    new_state+="${k}|${f}|${l}"$'\n'
done

for k in "${!first[@]}"; do
    [[ -n "${cur[$k]:-}" ]] || /usr/local/sbin/homelab-notify -p low -t white_check_mark -c health "Homelab : résolu" "${k} : de nouveau normal."
done

printf '%s' "$new_state" > "$STATE"

# Battement de cœur vers un moniteur "Push" d'Uptime Kuma (alerte si l'hôte cesse de répondre).
if [[ -n "${KUMA_PUSH_URL:-}" ]]; then
    if (( ${#cur[@]} == 0 )); then
        curl -fsS --max-time 10 "${KUMA_PUSH_URL%%\?*}?status=up&msg=OK" > /dev/null 2>&1 || true
    else
        curl -fsS --max-time 10 -G --data-urlencode "status=down" --data-urlencode "msg=${#cur[@]} probleme(s)" "${KUMA_PUSH_URL%%\?*}" > /dev/null 2>&1 || true
    fi
fi

if [[ "${1:-}" == "--print" ]]; then
    if (( ${#cur[@]} == 0 )); then echo "Tout est normal."; else for k in "${!cur[@]}"; do echo "- ${cur[$k]}"; done; fi
fi
exit 0
HEALTH_EOF
    chmod 755 /usr/local/sbin/homelab-health

    cat > /etc/systemd/system/homelab-health.service <<'EOF'
[Unit]
Description=Contrôle de santé du homelab

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-health
EOF

    cat > /etc/systemd/system/homelab-health.timer <<'EOF'
[Unit]
Description=Contrôle de santé du homelab (toutes les 10 minutes)

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now homelab-health.timer >/dev/null 2>&1 || warn "Timer homelab-health non activé."
}

configure_notify() {

    [[ "$ENABLE_HEALTH" == "true" ]] || { info "Surveillance : ENABLE_HEALTH=false, ignorée."; return 0; }

    info "Notifications et surveillance de l'hôte..."

    install_homelab_notify
    write_homelab_runtime_conf
    install_homelab_health
    configure_smartd
    configure_telegram

    if [[ -n "$(notify_ntfy_url)" ]]; then
        info "Notifications : ntfy $(notify_ntfy_url) (sujet ${NOTIFY_NTFY_TOPIC})."
    else
        info "Notifications : pas de serveur ntfy (journal /var/log/homelab-notify.log uniquement). Active ENABLE_MONITOR ou renseigne NOTIFY_NTFY_URL."
    fi
}

# ./install.sh --run notify_test : envoie une notification de test et affiche l'état de santé.
notify_test() {

    [[ -x /usr/local/sbin/homelab-notify ]] || die "Notifications non installées (./install.sh --run configure_notify)."

    /usr/local/sbin/homelab-notify -p default -t tada "Homelab : test" "Notification de test depuis $(hostname -s)."
    info "Notification de test envoyée (journal : /var/log/homelab-notify.log)."
    /usr/local/sbin/homelab-health --print
}

# ./install.sh --run health_check : contrôle immédiat, détail affiché.
health_check() {
    [[ -x /usr/local/sbin/homelab-health ]] || die "Surveillance non installée (./install.sh --run configure_notify)."
    /usr/local/sbin/homelab-health --print
}

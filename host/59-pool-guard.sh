###############################################################################
#     GARDE-FOU DE STOCKAGE : ARRÊT DES INVITÉS QUAND LE STOCKAGE EST PLEIN    #
###############################################################################

# Surveille (toutes les minutes) l'occupation des thin pools LVM (données ET métadonnées) et du système de
# fichiers DATA. Au seuil POOL_GUARD_PCT (98 % par défaut) : arrête les sauvegardes en cours, éteint TOUTES les
# VM et tous les CT proprement (arrêt forcé après 90 s), désactive leur démarrage automatique et notifie.
# Rien ne redémarre seul, même après un reboot de l'hôte : on fait le ménage, puis on relance À LA MAIN :
#   sudo homelab-pool-guard --resume        (refuse tant que le stockage est encore au-dessus du seuil ; --force passe outre)
#   sudo homelab-pool-guard --status
# Un pool plein bloque tous les invités en même temps et risque de corrompre leurs disques : mieux vaut un arrêt propre.
# Réarmement automatique quand l'occupation repasse 5 points sous le seuil (même si on a relancé les invités à la main).
POOL_GUARD_CONF="/etc/homelab/pool-guard.conf"

install_pool_guard() {

    install -d -m 0755 /etc/homelab /var/lib/homelab

    {
        echo "# Généré par l'installateur homelab (v${SCRIPT_VERSION}) : ne pas modifier."
        printf 'POOL_GUARD_PCT=%q\n' "${POOL_GUARD_PCT:-98}"
        printf 'DATA_MOUNT=%q\n' "$DATA_MOUNT"
    } > "${POOL_GUARD_CONF}.tmp"
    install -m 0644 "${POOL_GUARD_CONF}.tmp" "$POOL_GUARD_CONF"
    rm -f "${POOL_GUARD_CONF}.tmp"

    cat > /usr/local/sbin/homelab-pool-guard <<'POOL_GUARD_EOF'
#!/usr/bin/env bash
# homelab-pool-guard : éteint les VM/CT quand un thin pool LVM ou le volume DATA atteint le seuil (voir l'installateur).
# Usage : homelab-pool-guard            contrôle (appelé par le timer, chaque minute)
#         homelab-pool-guard --status   occupation actuelle et état du garde-fou
#         homelab-pool-guard --resume [--force]   relance les invités arrêtés (après le ménage)
set -u
export LC_ALL=C
CONF=/etc/homelab/pool-guard.conf
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && . "$CONF"
PCT="${POOL_GUARD_PCT:-98}"
REARM=$(( PCT > 10 ? PCT - 5 : PCT ))
DIR=/var/lib/homelab
TRIPPED="$DIR/pool-guard.tripped"
GUESTS="$DIR/pool-guard.guests"
ONBOOT="$DIR/pool-guard.onboot"
mkdir -p "$DIR"

exec 9> /run/homelab-pool-guard.lock
flock -n 9 || exit 0

notify() {   # priorité étiquette titre message
    if [[ -x /usr/local/sbin/homelab-notify ]]; then
        /usr/local/sbin/homelab-notify -p "$1" -t "$2" -c disk "$3" "$4"
    else
        logger -t homelab-pool-guard "$3 : $4"
    fi
}

ge() { awk -v p="$1" -v t="$2" 'BEGIN { exit !(p + 0 >= t + 0) }'; }

# Lignes « libellé pourcentage » : thin pools (données, métadonnées) puis système de fichiers de DATA.
usage_pools() {
    lvs --noheadings --separator '|' -o vg_name,lv_name,lv_attr,data_percent,metadata_percent 2> /dev/null |
        awk -F'|' '{ for (i = 1; i <= 5; i++) gsub(/ /, "", $i)
                     if (substr($3, 1, 1) == "t" && $4 != "") { printf "pool-%s/%s-donnees %s\npool-%s/%s-metadonnees %s\n", $1, $2, $4, $1, $2, $5 } }'
}
usage_data() {
    df -P "${DATA_MOUNT:-/}" 2> /dev/null | awk 'NR > 1 { gsub("%", "", $5); print "fs-" $6, $5 }'
}

# Affiche les lignes au-dessus (ou égal) du seuil $1 ; code 0 s'il y en a.
over_threshold() {
    local t="$1" label p found=1
    while read -r label p; do
        [[ -n "$p" ]] || continue
        if ge "$p" "$t"; then echo "${label} ${p}%"; found=0; fi
    done < <(usage_pools; usage_data)
    return "$found"
}

list_guests() {   # invités démarrés : vm:ID / ct:ID
    qm list 2> /dev/null | awk 'NR > 1 && $3 == "running" { print "vm:" $1 }'
    pct list 2> /dev/null | awk 'NR > 1 && $2 == "running" { print "ct:" $1 }'
}
all_guests() {
    qm list 2> /dev/null | awk 'NR > 1 { print "vm:" $1 }'
    pct list 2> /dev/null | awk 'NR > 1 { print "ct:" $1 }'
}
set_onboot() {   # vm|ct id 0|1
    if [[ "$1" == "vm" ]]; then qm set "$2" --onboot "$3" > /dev/null 2>&1; else pct set "$2" --onboot "$3" > /dev/null 2>&1; fi
}
has_onboot() {
    if [[ "$1" == "vm" ]]; then qm config "$2" 2> /dev/null | grep -q '^onboot: 1'; else pct config "$2" 2> /dev/null | grep -q '^onboot: 1'; fi
}

trip() {
    local reasons="$1" g k id n=0
    list_guests > "$GUESTS"
    : > "$ONBOOT"
    # Une sauvegarde en cours remplit le stockage : on l'arrête d'abord.
    if pgrep -x vzdump > /dev/null 2>&1; then pkill -TERM -x vzdump; sleep 5; fi
    # Démarrage automatique coupé pour tous (les invités arrêtés à la main aussi : un reboot ne doit rien relancer).
    while read -r g; do
        k="${g%%:*}"; id="${g#*:}"
        if has_onboot "$k" "$id"; then echo "$g" >> "$ONBOOT"; set_onboot "$k" "$id" 0; fi
    done < <(all_guests)
    while read -r g; do
        [[ -n "$g" ]] || continue
        k="${g%%:*}"; id="${g#*:}"; n=$((n + 1))
        if [[ "$k" == "vm" ]]; then
            { qm shutdown "$id" --timeout 90 --forceStop 1 || qm stop "$id" --skiplock 1; } > /dev/null 2>&1 &
        else
            { pct shutdown "$id" --timeout 90 --forceStop 1 || pct stop "$id"; } > /dev/null 2>&1 &
        fi
    done < "$GUESTS"
    wait
    date '+%F %T' > "$TRIPPED"
    echo "$reasons" >> "$TRIPPED"
    notify urgent rotating_light "Homelab : stockage plein, invités arrêtés" \
        "${reasons}. ${n} invité(s) éteint(s) pour protéger les données ; ils ne redémarreront PAS seuls. Fais le ménage puis : sudo homelab-pool-guard --resume"
}

status() {
    local label p
    while read -r label p; do [[ -n "$p" ]] && printf '%-40s %s%%\n' "$label" "$p"; done < <(usage_pools; usage_data)
    echo "Seuil d'arrêt : ${PCT}% (réarmement sous ${REARM}%)."
    if [[ -e "$TRIPPED" ]]; then
        echo "ÉTAT : DÉCLENCHÉ le $(head -1 "$TRIPPED") ($(sed -n 2p "$TRIPPED"))."
        echo "Invités arrêtés : $(tr '\n' ' ' < "$GUESTS" 2> /dev/null)"
        echo "Relancer : sudo homelab-pool-guard --resume"
    else
        echo "ÉTAT : armé, rien à signaler."
    fi
}

resume() {
    local force="${1:-}" over g k id ids=""
    [[ -e "$TRIPPED" ]] || { echo "Rien à relancer : le garde-fou n'a rien arrêté."; return 0; }
    if over="$(over_threshold "$PCT")" && [[ "$force" != "--force" ]]; then
        echo "Stockage encore trop plein : ${over//$'\n'/ ; }" >&2
        echo "Fais le ménage d'abord (ou --force pour relancer malgré tout)." >&2
        return 1
    fi
    # Démarrage automatique rétabli, puis relance dans l'ordre de démarrage de Proxmox.
    while read -r g; do [[ -n "$g" ]] && set_onboot "${g%%:*}" "${g#*:}" 1; done < "$ONBOOT" 2> /dev/null
    while read -r g; do [[ -n "$g" ]] && ids+="${g#*:},"; done < "$GUESTS" 2> /dev/null
    ids="${ids%,}"
    if [[ -n "$ids" ]]; then
        if ! pvesh create "/nodes/$(hostname -s)/startall" --vms "$ids" --force 1 > /dev/null 2>&1; then
            while read -r g; do
                [[ -n "$g" ]] || continue
                k="${g%%:*}"; id="${g#*:}"
                if [[ "$k" == "vm" ]]; then qm start "$id" > /dev/null 2>&1; else pct start "$id" > /dev/null 2>&1; fi
                sleep 3
            done < "$GUESTS"
        fi
    fi
    rm -f "$TRIPPED" "$GUESTS" "$ONBOOT"
    echo "Invités relancés : ${ids:-aucun}. Le garde-fou est réarmé."
    notify low white_check_mark "Homelab : invités relancés" "Relance manuelle après arrêt pour stockage plein (${ids:-aucun})."
}

case "${1:-}" in
    --status) status; exit 0 ;;
    --resume) resume "${2:-}"; exit $? ;;
esac

if [[ -e "$TRIPPED" ]]; then
    # Déjà déclenché : on ne rééteint pas ce qu'on a relancé à la main ; réarmement quand le stockage a été vidé.
    if ! over_threshold "$REARM" > /dev/null; then
        rm -f "$TRIPPED" "$GUESTS" "$ONBOOT"
        notify low white_check_mark "Homelab : stockage redescendu" "Occupation sous ${REARM}% : garde-fou réarmé (les invités se relancent avec --resume s'ils sont encore arrêtés)."
    fi
    exit 0
fi

if over="$(over_threshold "$PCT")"; then
    trip "${over//$'\n'/ ; }"
fi
exit 0
POOL_GUARD_EOF
    chmod 755 /usr/local/sbin/homelab-pool-guard

    cat > /etc/systemd/system/homelab-pool-guard.service <<'EOF'
[Unit]
Description=Garde-fou de stockage du homelab (arrêt des invités si le stockage est plein)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-pool-guard
EOF

    cat > /etc/systemd/system/homelab-pool-guard.timer <<'EOF'
[Unit]
Description=Garde-fou de stockage du homelab (toutes les minutes)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now homelab-pool-guard.timer > /dev/null 2>&1 || warn "Timer homelab-pool-guard non activé."
}

configure_pool_guard() {

    if [[ "${POOL_GUARD:-true}" != "true" ]]; then
        if [[ -e /etc/systemd/system/homelab-pool-guard.timer ]]; then
            systemctl disable --now homelab-pool-guard.timer > /dev/null 2>&1 || true
            info "Garde-fou de stockage : POOL_GUARD=false, timer désactivé."
        fi
        return 0
    fi

    [[ "${POOL_GUARD_PCT:-98}" =~ ^[0-9]+$ ]] && (( POOL_GUARD_PCT >= 50 && POOL_GUARD_PCT <= 99 )) \
        || die "POOL_GUARD_PCT='${POOL_GUARD_PCT:-}' invalide (nombre entre 50 et 99)."

    info "Garde-fou de stockage : arrêt des VM/CT à ${POOL_GUARD_PCT:-98}% (thin pools et ${DATA_MOUNT})."
    install_pool_guard
}

# ./install.sh --run pool_guard_status : occupation et état.
pool_guard_status() {
    [[ -x /usr/local/sbin/homelab-pool-guard ]] || die "Garde-fou non installé (./install.sh --run configure_pool_guard)."
    /usr/local/sbin/homelab-pool-guard --status
}

# ./install.sh --run pool_guard_resume [--force] : relance les invités arrêtés par le garde-fou.
pool_guard_resume() {
    [[ -x /usr/local/sbin/homelab-pool-guard ]] || die "Garde-fou non installé (./install.sh --run configure_pool_guard)."
    /usr/local/sbin/homelab-pool-guard --resume "${1:-}"
}


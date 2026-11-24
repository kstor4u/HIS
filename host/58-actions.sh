###############################################################################
#     ACTIONS À DISTANCE PAR TELEGRAM (sauvegarde, VM/CT, hôte) : SÉCURISÉES   #
###############################################################################

# Principe : un compte Telegram piraté (ou un jeton de bot volé) ne doit PAS suffire à agir.
#
#   1. Aucune action n'est active par défaut : TELEGRAM_ACTIONS liste les groupes autorisés
#        backup  : /sauvegarder /dumpbases /testrestauration
#        guests  : /invite_demarrer /invite_arreter /invite_redemarrer
#        host    : /hote_redemarrer /hote_eteindre
#   2. Seul TELEGRAM_ADMIN_ID, en discussion PRIVÉE, peut les demander (pas un groupe, pas un autre compte).
#   3. Chaque action exige un code à usage unique (TOTP, application d'authentification sur ton téléphone,
#      secret conservé sur le serveur uniquement) : le contrôle ne dépend plus de Telegram.
#      3 codes faux = actions verrouillées 30 min + alerte. Un code déjà utilisé est refusé.
#   4. Le bot lui-même n'a AUCUN privilège (utilisateur « homelab-bot ») : il ne peut appeler que
#      homelab-actions, qui n'exécute qu'une liste fermée de verbes, avec des cibles contrôlées
#      (jamais de commande libre, pas de suppression, pas de restauration, pas de réglages).
#   5. Chaque action est journalisée (/var/log/homelab-actions.log) et notifiée sur TOUS les canaux (ntfy
#      compris), donc visible même si Telegram est compromis. Arrêt/redémarrage de l'hôte : délai
#      (TELEGRAM_ACTION_DELAY, 60 s) pendant lequel /annuler est possible.
#
# Volontairement ABSENT : acquitter une alerte de sauvegarde, restaurer, supprimer, modifier la configuration.

guest_map_list() {

    [[ "$ENABLE_SWAG" == "true" ]]      && printf 'swag:ct:%s\n' "$SWAG_ID"
    [[ "$ENABLE_DOCKER" == "true" ]]    && printf 'docker:vm:%s\n' "$DOCKER_ID"
    [[ "$ENABLE_FILES" == "true" ]]     && printf 'files:vm:%s\n' "$FILES_ID"
    [[ "$ENABLE_WIREGUARD" == "true" ]] && printf 'wireguard:ct:%s\n' "$WG_ID"
    [[ "$ENABLE_NODE" == "true" ]]      && printf 'node:ct:%s\n' "$NODE_ID"
    [[ "$ENABLE_MAIL" == "true" ]]      && printf 'mail:ct:%s\n' "$MAIL_ID"
    [[ "$ENABLE_DNS" == "true" ]]       && printf 'dns:ct:%s\n' "$DNS_ID"
    [[ "${ENABLE_MONITOR:-false}" == "true" ]] && printf 'monitor:ct:%s\n' "$MONITOR_ID"
    [[ "$ENABLE_XMRIG" == "true" ]]     && printf 'xmrig:ct:%s\n' "$XMRIG_ID"
    return 0
}

install_totp_helper() {

    install -d -m 0755 /usr/local/lib/homelab
    cat > /usr/local/lib/homelab/totp.py <<'TOTP_EOF'
#!/usr/bin/env python3
"""TOTP (RFC 6238, SHA-1, 6 chiffres, 30 s) sans dépendance.
  totp.py new                              affiche un nouveau secret (base32)
  totp.py verify <secret> <état> <code>    0 = bon ; 1 = faux ; 2 = déjà utilisé (rejeu)
  totp.py uri <secret> <libellé> <émetteur>
La variable TOTP_NOW (secondes) sert aux tests."""
import base64, hashlib, hmac, os, secrets, struct, sys, time
from urllib.parse import quote


def hotp(key, counter):
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    return (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000


def load(path):
    s = open(path).read().strip().replace(" ", "").upper()
    return base64.b32decode(s + "=" * (-len(s) % 8))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "new":
        print(base64.b32encode(secrets.token_bytes(20)).decode().rstrip("="))
    elif cmd == "uri":
        secret = open(sys.argv[2]).read().strip()
        label, issuer = quote(sys.argv[3]), quote(sys.argv[4])
        print("otpauth://totp/%s:%s?secret=%s&issuer=%s&period=30&digits=6&algorithm=SHA1" % (issuer, label, secret, issuer))
    elif cmd == "verify":
        key, state, code = load(sys.argv[2]), sys.argv[3], sys.argv[4]
        if len(code) != 6 or not code.isdigit():
            sys.exit(1)
        step = int(float(os.environ.get("TOTP_NOW", time.time()))) // 30
        try:
            last = int(open(state).read().strip() or 0)
        except Exception:
            last = 0
        found = None
        for s in (step - 1, step, step + 1):
            if hmac.compare_digest("%06d" % hotp(key, s), code):
                found = s
        if found is None:
            sys.exit(1)
        if found <= last:
            sys.exit(2)
        tmp = state + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(str(found))
        os.replace(tmp, state)
        sys.exit(0)
    else:
        sys.exit(64)


main()
TOTP_EOF
    chmod 755 /usr/local/lib/homelab/totp.py
}

install_homelab_actions() {

    cat > /usr/local/sbin/homelab-actions <<'ACT_EOF'
#!/usr/bin/env bash
# Seul point d'entrée du bot Telegram vers le système (appelé par sudo, liste fermée de verbes).
# Usage : homelab-actions <verbe> <cible|-> <code|-> <identifiant Telegram|->
# Lecture seule : cpu mem disk guests backups status cancel
# Avec code TOTP : backup-run db-dump restore-test | guest-start guest-stop guest-reboot | host-reboot host-shutdown
set -u
umask 077
CONF=/etc/homelab/homelab.conf
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null || { echo "Configuration illisible."; exit 1; }

verb="${1:-}" target="${2:--}" code="${3:--}" who="${4:--}"
LOG=/var/log/homelab-actions.log
LOCK=/var/lib/homelab/actions.lock
TOTP=/usr/local/lib/homelab/totp.py
TOTP_SECRET=/etc/homelab/totp.secret
TOTP_STATE=/var/lib/homelab/totp.last
NOTIFY=/usr/local/sbin/homelab-notify
DELAY="${ACTIONS_DELAY:-60}"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$who" "$*" >> "$LOG" 2>/dev/null || true; }

[[ "$verb" =~ ^[a-z-]{2,20}$ ]]    || { echo "Action invalide."; exit 2; }
[[ "$target" =~ ^([a-z0-9_-]{1,24}|-)$ ]] || { echo "Cible invalide."; exit 2; }
[[ "$code" =~ ^([0-9]{6}|-)$ ]]    || { echo "Code invalide (6 chiffres)."; exit 2; }
[[ "$who" =~ ^([0-9]{1,15}|-)$ ]]  || { echo "Identifiant invalide."; exit 2; }

gio() { awk -v k="$1" 'BEGIN { printf "%.1f", k/1048576 }'; }

cpu_percent() {
    local u n s i w q sq st id1 id2 t1 t2 dt di
    read -r _ u n s i w q sq st _ < /proc/stat; id1=$((i + w)); t1=$((u + n + s + i + w + q + sq + st))
    sleep 1
    read -r _ u n s i w q sq st _ < /proc/stat; id2=$((i + w)); t2=$((u + n + s + i + w + q + sq + st))
    dt=$((t2 - t1)); di=$((id2 - id1))
    (( dt > 0 )) && echo $(( 100 * (dt - di) / dt )) || echo 0
}

miner_state() {
    [[ -n "${XMRIG_ID_RT:-}" ]] && pct status "$XMRIG_ID_RT" >/dev/null 2>&1 || return 0
    if ! pct status "$XMRIG_ID_RT" 2>/dev/null | grep -q running; then echo "Mineur : CT arrêté"
    elif pct exec "$XMRIG_ID_RT" -- systemctl is-active --quiet xmrig 2>/dev/null; then echo "Mineur : en marche"
    elif [[ -f /run/xmrig-monitor.state ]]; then echo "Mineur : en pause (charge CPU des autres machines)"
    else echo "Mineur : arrêté"; fi
}

v_cpu() {
    local n l1 l5 l15
    n="$(nproc)"; read -r l1 l5 l15 _ < /proc/loadavg
    echo "CPU : $(cpu_percent)% (sur 1 s) · ${n} cœurs"
    echo "Charge moyenne 1/5/15 min : ${l1} / ${l5} / ${l15}"
    echo "Processus les plus gourmands :"
    ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && NR<=5 {printf "  %s%%  %s\n", $1, $2}'
    miner_state
}

v_mem() {
    awk '
        /^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
        END {
            u=t-a
            printf "Mémoire : %.1f / %.1f Gio utilisés (%d%%), %.1f Gio disponibles\n", u/1048576, t/1048576, (t>0 ? 100*u/t : 0), a/1048576
            if (st > 0) printf "Swap : %.1f / %.1f Gio utilisés\n", (st-sf)/1048576, st/1048576
            else print "Swap : aucun"
        }' /proc/meminfo
}

v_disk() {
    echo "Disques :"
    df -Pk / "${DATA_MOUNT:-/}" 2>/dev/null | awk 'NR>1 {print $6, $5, $2, $4}' | sort -u |
        while read -r mp pu tot free; do printf '  %s : %s utilisé · %s Gio libres sur %s Gio\n' "$mp" "$pu" "$(gio "$free")" "$(gio "$tot")"; done
    local st
    st="$(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {printf "  %s (%s) : %s · %.1f Gio libres sur %.1f Gio\n", $1, $2, $7, $6/1048576, $4/1048576}')"
    [[ -z "$st" ]] || { echo "Stockages Proxmox :"; echo "$st"; }
    if [[ -r /proc/mdstat ]] && grep -Eq '\[[U_]*_[U_]*\]' /proc/mdstat; then echo "⚠️ RAID dégradé (cat /proc/mdstat)"; fi
}

v_guests() {
    local g kind id st
    echo "VM/CT :"
    for g in ${HEALTH_GUESTS:-}; do
        kind="${g%%:*}" id="${g#*:}"
        if [[ "$kind" == "vm" ]]; then st="$(qm status "$id" 2>/dev/null)"; else st="$(pct status "$id" 2>/dev/null)"; fi
        printf '  %s %s : %s\n' "${kind^^}" "$id" "${st#status: }"
    done
}

v_backups() {
    local newest age f
    newest="$(find "${PROXMOX_DATA_DIR:-/nonexistent}/dump" -maxdepth 1 -type f -name 'vzdump-*' ! -name '*.log' ! -name '*.notes' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    if [[ -n "$newest" ]]; then
        age=$(( ( $(date +%s) - ${newest%%.*} ) / 3600 ))
        echo "Dernière sauvegarde vzdump : il y a ${age} h (planifiée : ${BACKUP_SCHEDULE_RT:-?})."
    else
        echo "Aucune sauvegarde vzdump trouvée."
    fi
    if pgrep -x vzdump >/dev/null 2>&1; then echo "Une sauvegarde vzdump est EN COURS."; fi
    for f in db-dump restore-test; do
        [[ -r "/var/lib/homelab/${f}.status" ]] || continue
        printf '%s : %s (le %s)\n' "$f" "$(grep -q '|FAIL|' "/var/lib/homelab/${f}.status" && echo "ÉCHEC" || echo "OK")" "$(date -r "/var/lib/homelab/${f}.status" '+%F %H:%M')"
    done
}

v_status() { v_cpu; echo; v_mem; echo; v_disk; echo; v_guests; echo; v_backups; }

v_cancel() {
    if systemctl is-active --quiet homelab-host-power.timer; then
        systemctl stop homelab-host-power.timer && echo "Action sur l'hôte annulée."
    else
        echo "Aucune action sur l'hôte n'est programmée."
    fi
}

case "$verb" in
    cpu|mem|disk|guests|backups|status) "v_${verb}"; exit 0 ;;
    cancel) v_cancel; log "cancel"; exit 0 ;;
    backup-run|db-dump|restore-test) group=backup ;;
    guest-start|guest-stop|guest-reboot) group=guests ;;
    host-reboot|host-shutdown) group=host ;;
    *) echo "Action inconnue."; exit 2 ;;
esac

# --- Actions : groupe activé, verrou, code TOTP --------------------------------------------------
if [[ " ${TELEGRAM_ACTIONS:-} " != *" ${group} "* ]]; then
    echo "Action désactivée : « ${group} » n'est pas dans TELEGRAM_ACTIONS."; exit 3
fi
[[ -r "$TOTP_SECRET" ]] || { echo "Double authentification non configurée sur le serveur (./install.sh --run telegram_totp_show)."; exit 3; }

now="$(date +%s)"
fails=0 first=0 until=0
[[ -r "$LOCK" ]] && IFS='|' read -r fails first until < "$LOCK"
[[ "$fails" =~ ^[0-9]+$ && "$first" =~ ^[0-9]+$ && "$until" =~ ^[0-9]+$ ]] || { fails=0 first=0 until=0; }

if (( until > now )); then
    echo "Actions verrouillées encore $(( (until - now) / 60 + 1 )) min (trop de codes faux)."; log "verrouillé : ${verb}"; exit 4
fi
if [[ "$code" == "-" ]]; then
    echo "Code requis : ajoute à la commande les 6 chiffres de ton application d'authentification."; exit 5
fi

python3 "$TOTP" verify "$TOTP_SECRET" "$TOTP_STATE" "$code"
rc=$?
if (( rc != 0 )); then
    (( now - first > 600 )) && { fails=0; first=$now; }
    (( first == 0 )) && first=$now
    fails=$(( fails + 1 ))
    if (( fails >= 3 )); then until=$(( now + 1800 )); fails=0; first=0; fi
    printf '%s|%s|%s\n' "$fails" "$first" "$until" > "$LOCK"
    log "CODE REFUSÉ (rc=${rc}) pour ${verb} ${target}"
    [[ -x "$NOTIFY" ]] && "$NOTIFY" -p high -t warning,rotating_light -c security "Telegram : code refusé" \
        "Tentative d'action « ${verb} ${target} » avec un mauvais code (utilisateur Telegram ${who}).$( (( until > now )) && echo ' Actions verrouillées 30 min.')"
    if (( rc == 2 )); then echo "Code déjà utilisé : attends le suivant (30 s)."; else echo "Code refusé."; fi
    exit 5
fi
rm -f "$LOCK"

log "OK ${verb} ${target}"
[[ -x "$NOTIFY" ]] && "$NOTIFY" -p high -t warning,rotating_light -c security "Telegram : action ${verb} ${target}" \
    "Exécutée à la demande de l'utilisateur Telegram ${who} (code valide)."

guest_lookup() {   # nom -> "ct:101" | "vm:103"
    local e name kind id
    for e in ${GUEST_MAP:-}; do
        IFS=: read -r name kind id <<< "$e"
        [[ "$name" == "$1" ]] && { echo "${kind}:${id}"; return 0; }
    done
    return 1
}

run_unit() {   # nom-d-unité commande...
    local unit="$1"; shift
    systemctl is-active --quiet "$unit" && { echo "Déjà en cours (${unit})."; return 6; }
    systemd-run --unit="$unit" --collect --quiet "$@"
}

case "$verb" in
    backup-run)
        pgrep -x vzdump >/dev/null 2>&1 && { echo "Une sauvegarde vzdump est déjà en cours."; exit 6; }
        if [[ "$target" == "-" || "$target" == "tout" ]]; then
            ids="${BACKUP_VMIDS//,/ }"
        else
            g="$(guest_lookup "$target")" || { echo "Cible inconnue. Possibles : tout ou $(for e in ${GUEST_MAP:-}; do printf '%s ' "${e%%:*}"; done)"; exit 2; }
            ids="${g#*:}"
        fi
        [[ -n "${ids// /}" ]] || { echo "Aucune VM/CT à sauvegarder."; exit 2; }
        # shellcheck disable=SC2086
        run_unit homelab-vzdump-manual vzdump $ids --storage "$BACKUP_STORAGE" --mode "${BACKUP_MODE:-snapshot}" \
            --compress "${BACKUP_COMPRESS:-zstd}" --prune-backups "${BACKUP_KEEP:-keep-daily=7}" || exit $?
        echo "Sauvegarde lancée (VM/CT : ${ids}). Tu recevras le début puis le rapport de fin." ;;
    db-dump)
        run_unit homelab-dbdump-manual /usr/local/sbin/homelab-db-dump || exit $?
        echo "Dump des bases lancé (résultat : /sauvegardes)." ;;
    restore-test)
        run_unit homelab-restoretest-manual /usr/local/sbin/homelab-restore-test || exit $?
        echo "Test de restauration lancé (plusieurs minutes ; résultat par notification)." ;;
    guest-start|guest-stop|guest-reboot)
        [[ "$target" != "-" ]] || { echo "Précise l'invité : $(for e in ${GUEST_MAP:-}; do printf '%s ' "${e%%:*}"; done)"; exit 2; }
        g="$(guest_lookup "$target")" || { echo "Invité inconnu. Possibles : $(for e in ${GUEST_MAP:-}; do printf '%s ' "${e%%:*}"; done)"; exit 2; }
        kind="${g%%:*}" id="${g#*:}"
        case "$verb" in guest-start) op=start; extra=() ;; guest-stop) op=shutdown; extra=(--timeout 60) ;; *) op=reboot; extra=(--timeout 60) ;; esac
        if [[ "$kind" == "vm" ]]; then cmd=(qm "$op" "$id" "${extra[@]}"); else cmd=(pct "$op" "$id" "${extra[@]}"); fi
        out="$(timeout 120 "${cmd[@]}" 2>&1)"; rc=$?
        if (( rc == 0 )); then echo "${target} (${kind^^} ${id}) : ${op} effectué."; else echo "${target} : échec de ${op} : $(tail -n 2 <<< "$out" | tr '\n' ' ')"; exit 7; fi ;;
    host-reboot|host-shutdown)
        systemctl is-active --quiet homelab-host-power.timer && { echo "Une action sur l'hôte est déjà programmée : /annuler pour l'interrompre."; exit 6; }
        if [[ "$verb" == "host-reboot" ]]; then op=reboot; msg="Redémarrage"; else op=poweroff; msg="Extinction"; fi
        systemd-run --unit=homelab-host-power --on-active="${DELAY}s" --collect --quiet systemctl "$op"
        echo "${msg} de l'hôte dans ${DELAY} s (VM/CT arrêtés proprement). /annuler pour interrompre."
        [[ "$op" == "poweroff" ]] && echo "Pour le rallumer : bouton physique ou Wake-on-LAN (impossible par Telegram)." ;;
esac
exit 0
ACT_EOF
    chmod 755 /usr/local/sbin/homelab-actions
}

# Prépare le compte du bot, sudo restreint, le fichier de configuration du bot et le secret TOTP.
configure_actions() {

    id homelab-bot >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin homelab-bot
    command -v sudo >/dev/null 2>&1 || apt-get install -y sudo >/dev/null || die "sudo est nécessaire au bot Telegram."

    install -d -m 0755 /etc/homelab /var/lib/homelab

    printf 'homelab-bot ALL=(root) NOPASSWD: /usr/local/sbin/homelab-actions\n' > /etc/sudoers.d/homelab-bot.tmp
    chmod 0440 /etc/sudoers.d/homelab-bot.tmp
    if visudo -cf /etc/sudoers.d/homelab-bot.tmp >/dev/null 2>&1; then
        mv /etc/sudoers.d/homelab-bot.tmp /etc/sudoers.d/homelab-bot
    else
        rm -f /etc/sudoers.d/homelab-bot.tmp
        die "Règle sudo du bot invalide (visudo) : abandon, rien n'a été activé."
    fi

    # Configuration du bot (lisible par lui seul) : jeton, discussions, administrateur, groupes d'actions
    {
        printf 'TELEGRAM_BOT_TOKEN=%q\n' "$TELEGRAM_BOT_TOKEN"
        printf 'TELEGRAM_CHAT_ID=%q\n' "$TELEGRAM_CHAT_ID"
        printf 'TELEGRAM_ADMIN_ID=%q\n' "${TELEGRAM_ADMIN_ID:-}"
        printf 'TELEGRAM_ACTIONS=%q\n' "${TELEGRAM_ACTIONS:-}"
    } > /etc/homelab/telegram.conf
    chown root:homelab-bot /etc/homelab/telegram.conf
    chmod 0640 /etc/homelab/telegram.conf

    install_totp_helper
    install_homelab_actions

    if [[ -n "${TELEGRAM_ACTIONS// /}" ]]; then
        if [[ ! -s /etc/homelab/totp.secret ]]; then
            ( umask 077; python3 /usr/local/lib/homelab/totp.py new > /etc/homelab/totp.secret )
            chmod 600 /etc/homelab/totp.secret
            info "Actions Telegram : secret de double authentification créé."
            telegram_totp_show
        fi
        info "Actions Telegram activées : ${TELEGRAM_ACTIONS} (administrateur Telegram ${TELEGRAM_ADMIN_ID}, code TOTP à chaque action)."
    else
        info "Actions Telegram : aucune (TELEGRAM_ACTIONS vide) : le bot reste en lecture seule."
    fi
}

# ./install.sh --run telegram_totp_show : secret et QR code à ajouter dans ton application d'authentification
telegram_totp_show() {

    [[ -s /etc/homelab/totp.secret ]] || die "Pas de secret : renseigne TELEGRAM_ACTIONS puis ./install.sh --run configure_notify"

    local uri
    uri="$(python3 /usr/local/lib/homelab/totp.py uri /etc/homelab/totp.secret "$(hostname -s)" Homelab)"

    echo
    echo "=== Double authentification des actions Telegram ==="
    echo "Ajoute ce secret dans une application d'authentification (Aegis, Google Authenticator, 2FAS...) :"
    echo "  Secret : $(cat /etc/homelab/totp.secret)   (base32, 6 chiffres, 30 s)"
    echo "  URI    : ${uri}"
    if command -v qrencode >/dev/null 2>&1 || apt-get install -y qrencode >/dev/null 2>&1; then
        qrencode -t ansiutf8 "$uri" || true
    fi
    echo "Ne le stocke PAS dans Telegram ni dans un fichier synchronisé avec lui. Régénérer : ./install.sh --run telegram_totp_reset"
    echo
}

# ./install.sh --run telegram_totp_reset : nouveau secret (l'ancien code cesse de fonctionner)
telegram_totp_reset() {

    rm -f /etc/homelab/totp.secret /var/lib/homelab/totp.last /var/lib/homelab/actions.lock
    ( umask 077; python3 /usr/local/lib/homelab/totp.py new > /etc/homelab/totp.secret )
    chmod 600 /etc/homelab/totp.secret
    info "Nouveau secret créé : l'ancienne entrée de ton application ne fonctionne plus."
    telegram_totp_show
}

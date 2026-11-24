###############################################################################
#           TELEGRAM : ALERTES + BOT DE QUESTIONS (CPU, MÉMOIRE, STOCKAGE)    #
###############################################################################

# Alertes : homelab-notify envoie sur Telegram les catégories listées dans TELEGRAM_ALERTS
#   miner   mineur arrêté (ou relancé) à cause de la charge CPU
#   disk    palier de remplissage franchi (tous les HEALTH_DISK_STEP %, 10 par défaut)
#   usb     disque USB branché, export démarré / terminé
#   backup  sauvegarde vzdump : début, fin avec le détail par VM/CT (taille, échecs)
#   system  serveur démarré (après une coupure ou un redémarrage)
#   network IP publique modifiée (zone DNS, tunnel WireGuard à mettre à jour)
#   health  problèmes détectés par la surveillance (invité arrêté, service muet, RAID...)
#   smart   alertes SMART des disques       |   all = tout
#
# Bot : un service (homelab-telegram-bot) interroge Telegram en sortie uniquement (aucun port
# à ouvrir) et répond, à la seule discussion autorisée (TELEGRAM_CHAT_ID), à :
#   /cpu  /memoire  /stockage  /invites  /sauvegardes  /status  /aide     (lecture seule)
# + actions protégées par code TOTP (host/58-actions.sh), désactivées par défaut.
#
# Mise en place : 1. dans Telegram, parle à @BotFather : /newbot -> jeton (TELEGRAM_BOT_TOKEN)
#                 2. envoie un message à ton bot, puis ./install.sh --run telegram_chat_id
#                 3. TELEGRAM_CHAT_ID=... ; ENABLE_TELEGRAM=true ; ./install.sh --run configure_notify

install_homelab_telegram_bot() {

    cat > /usr/local/sbin/homelab-telegram-bot <<'BOT_EOF'
#!/usr/bin/env bash
# Bot Telegram du homelab. Tourne SANS privilège (utilisateur homelab-bot) : il ne fait qu'analyser les
# messages et appeler « sudo homelab-actions <verbe> <cible> <code> <id> », seul point d'entrée autorisé.
set -u
CONF="${BOT_CONF:-/etc/homelab/telegram.conf}"
# shellcheck disable=SC1090
. "$CONF" || exit 1
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || { echo "Telegram non configuré." >&2; exit 1; }

ACTIONS_BIN="${ACTIONS_BIN:-sudo -n /usr/local/sbin/homelab-actions}"
OFFSET_FILE="${OFFSET_FILE:-/var/lib/homelab-bot/telegram.offset}"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Appel d'API : le jeton passe par stdin (-K -), jamais dans la liste des processus.
tg() { local method="$1"; shift; printf 'url = "%s/%s"\n' "$API" "$method" | curl -sS --max-time "${TG_TIMEOUT:-20}" -K - "$@"; }
send() { tg sendMessage --data-urlencode "chat_id=$1" --data-urlencode "text=$2" -o /dev/null || true; }
# Efface le message contenant un code (sans effet si Telegram refuse : le code est de toute façon à usage unique)
wipe() { tg deleteMessage -d "chat_id=$1" -d "message_id=$2" -o /dev/null 2>&1 || true; }

authorized() { local c; for c in ${TELEGRAM_CHAT_ID//,/ }; do [[ "$c" == "$1" ]] && return 0; done; return 1; }
group_enabled() { [[ " ${TELEGRAM_ACTIONS:-} " == *" $1 "* ]]; }

act() {   # verbe cible code uid -> sortie texte
    local out
    out="$($ACTIONS_BIN "$1" "$2" "$3" "$4" 2>&1)" || true
    printf '%s' "${out:-Pas de réponse.}"
}

cmd_help() {
    cat <<'H'
Lecture seule :
/cpu  /memoire  /stockage  /invites  /sauvegardes  /status
Actions (discussion privée, administrateur, code à 6 chiffres de ton application d'authentification, groupes activés sur le serveur) :
/sauvegarder [tout|nom] CODE
/dumpbases CODE
/testrestauration CODE
/invite_demarrer nom CODE
/invite_arreter nom CODE
/invite_redemarrer nom CODE
/hote_redemarrer CODE
/hote_eteindre CODE
/annuler : annule un arrêt/redémarrage programmé
H
}

# Actions : tableau commande -> verbe:groupe:cible_requise
handle_action() {
    local chat="$1" ctype="$2" from="$3" mid="$4" cmd="$5" rest="$6"
    local verb group
    case "$cmd" in
        /sauvegarder)         verb=backup-run;    group=backup ;;
        /dumpbases)           verb=db-dump;       group=backup ;;
        /testrestauration)    verb=restore-test;  group=backup ;;
        /invite_demarrer)     verb=guest-start;   group=guests ;;
        /invite_arreter)      verb=guest-stop;    group=guests ;;
        /invite_redemarrer)   verb=guest-reboot;  group=guests ;;
        /hote_redemarrer)     verb=host-reboot;   group=host ;;
        /hote_eteindre)       verb=host-shutdown; group=host ;;
        *) return 1 ;;
    esac
    local -a w; read -r -a w <<< "$rest"
    local code="-" target="-" t
    for t in "${w[@]}"; do
        if [[ "$t" =~ ^[0-9]{6}$ ]]; then code="$t"
        elif [[ "$target" == "-" && "$t" =~ ^[a-z0-9_-]{1,24}$ ]]; then target="${t,,}"
        else send "$chat" "Argument non reconnu."; return 0; fi
    done
    [[ "$code" != "-" ]] && wipe "$chat" "$mid"
    # Défense en profondeur : le serveur revérifie tout ; ici on refuse tôt
    if [[ "$ctype" != "private" || -z "${TELEGRAM_ADMIN_ID:-}" || "$from" != "$TELEGRAM_ADMIN_ID" || "$chat" != "$TELEGRAM_ADMIN_ID" ]]; then
        logger -t homelab-telegram-bot "Action ${verb} refusée : ${from} dans ${chat} (${ctype})"
        send "$chat" "Les actions ne sont possibles que pour l'administrateur, en discussion privée."
        return 0
    fi
    group_enabled "$group" || { send "$chat" "Action désactivée : « ${group} » n'est pas dans TELEGRAM_ACTIONS."; return 0; }
    send "$chat" "$(act "$verb" "$target" "$code" "$from")"
}

handle() {
    local chat="$1" ctype="$2" from="$3" mid="$4" text="$5" cmd rest
    cmd="${text%% *}"; cmd="${cmd%%@*}"; cmd="${cmd,,}"
    rest=""; [[ "$text" == *" "* ]] && rest="${text#* }"
    case "$cmd" in
        /cpu)                         send "$chat" "$(act cpu - - "$from")" ;;
        /memoire | /mem | /ram)       send "$chat" "$(act mem - - "$from")" ;;
        /stockage | /disque | /disk)  send "$chat" "$(act disk - - "$from")" ;;
        /invites | /vm | /ct)         send "$chat" "$(act guests - - "$from")" ;;
        /sauvegardes | /backups)      send "$chat" "$(act backups - - "$from")" ;;
        /status | /etat)              send "$chat" "$(act status - - "$from")" ;;
        /annuler | /cancel)
            if [[ "$ctype" == "private" && -n "${TELEGRAM_ADMIN_ID:-}" && "$from" == "$TELEGRAM_ADMIN_ID" ]]; then send "$chat" "$(act cancel - - "$from")"
            else send "$chat" "Réservé à l'administrateur, en discussion privée."; fi ;;
        /start | /aide | /help)       send "$chat" "$(cmd_help)" ;;
        /sauvegarder | /dumpbases | /testrestauration | /invite_demarrer | /invite_arreter | /invite_redemarrer | /hote_redemarrer | /hote_eteindre)
            handle_action "$chat" "$ctype" "$from" "$mid" "$cmd" "$rest" ;;
        /*)                           send "$chat" "Commande inconnue. /aide pour la liste." ;;
        *)                            : ;;
    esac
}

tg setMyCommands --data-urlencode 'commands=[{"command":"status","description":"Vue d ensemble"},{"command":"cpu","description":"Charge CPU et mineur"},{"command":"memoire","description":"Mémoire"},{"command":"stockage","description":"Disques et stockages"},{"command":"invites","description":"État des VM et CT"},{"command":"sauvegardes","description":"État des sauvegardes"},{"command":"aide","description":"Liste des commandes"}]' -o /dev/null 2>&1 || true

offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
[[ "$offset" =~ ^[0-9]+$ ]] || offset=0

while true; do
    resp="$(TG_TIMEOUT=65 tg getUpdates -d "offset=${offset}" -d timeout=50 --data-urlencode 'allowed_updates=["message"]' 2>/dev/null)" || resp=""
    if ! jq -e '.ok == true' >/dev/null 2>&1 <<< "$resp"; then
        [[ -n "${BOT_ONCE:-}" ]] && exit 1
        sleep 15; continue
    fi
    while IFS=$'\t' read -r uid cid ctype from mid text; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        offset=$((uid + 1))
        [[ "$from" =~ ^[0-9]+$ ]] || from=0
        if authorized "$cid"; then
            handle "$cid" "$ctype" "$from" "$mid" "$text"
        else
            logger -t homelab-telegram-bot "Message ignoré : discussion non autorisée ${cid}"
        fi
    done < <(jq -r '.result[] | [.update_id, (.message.chat.id // ""), (.message.chat.type // ""), (.message.from.id // ""), (.message.message_id // ""), ((.message.text // "") | gsub("[\\t\\n]"; " "))] | @tsv' <<< "$resp")
    printf '%s' "$offset" > "$OFFSET_FILE"
    [[ -n "${BOT_ONCE:-}" ]] && exit 0
done
BOT_EOF
    chmod 755 /usr/local/sbin/homelab-telegram-bot

    cat > /etc/systemd/system/homelab-telegram-bot.service <<'UNIT'
[Unit]
Description=Bot Telegram du homelab (sans privilège, actions via sudo restreint)
After=network-online.target
Wants=network-online.target

[Service]
User=homelab-bot
Group=homelab-bot
StateDirectory=homelab-bot
ExecStart=/usr/local/sbin/homelab-telegram-bot
Restart=always
RestartSec=10
ProtectHome=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT
}

configure_telegram() {

    if [[ "${ENABLE_TELEGRAM:-false}" != "true" ]]; then
        if [[ -f /etc/systemd/system/homelab-telegram-bot.service ]]; then
            systemctl disable --now homelab-telegram-bot.service >/dev/null 2>&1 || true
            info "Telegram : désactivé (service du bot arrêté)."
        fi
        return 0
    fi

    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "ENABLE_TELEGRAM=true : renseigne TELEGRAM_BOT_TOKEN (jeton donné par @BotFather)."
    [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "TELEGRAM_BOT_TOKEN : format invalide (attendu 123456789:AAAA...)."
    [[ -z "${TELEGRAM_ADMIN_ID:-}" || "$TELEGRAM_ADMIN_ID" =~ ^[0-9]{1,15}$ ]] || die "TELEGRAM_ADMIN_ID : identifiant numérique attendu."
    [[ -z "${TELEGRAM_ACTIONS// /}" || -n "${TELEGRAM_ADMIN_ID:-}" ]] || die "TELEGRAM_ACTIONS demande TELEGRAM_ADMIN_ID (ton identifiant Telegram)."
    local g; for g in ${TELEGRAM_ACTIONS:-}; do [[ "$g" =~ ^(backup|guests|host)$ ]] || die "TELEGRAM_ACTIONS : « $g » inconnu (backup | guests | host)."; done
    [[ "${TELEGRAM_CHAT_ID:-}" =~ ^-?[0-9]+([ ,]+-?[0-9]+)*$ ]] \
        || die "TELEGRAM_CHAT_ID : identifiant(s) numérique(s) attendu(s). Envoie un message à ton bot puis : ./install.sh --run telegram_chat_id"

    command -v jq >/dev/null 2>&1 || apt-get install -y jq >/dev/null || die "jq est nécessaire au bot Telegram."

    configure_actions
    install_homelab_telegram_bot
    systemctl daemon-reload
    systemctl enable homelab-telegram-bot.service >/dev/null 2>&1
    systemctl restart homelab-telegram-bot.service

    sleep 2
    systemctl is-active --quiet homelab-telegram-bot.service \
        && info "Telegram : bot actif (alertes : ${TELEGRAM_ALERTS:-miner disk usb backup system network security} ; commandes /aide)." \
        || warn "Telegram : le service du bot n'est pas actif (journalctl -u homelab-telegram-bot)."
}

# ./install.sh --run telegram_chat_id : affiche les discussions qui ont écrit au bot (après lui avoir envoyé un message).
telegram_chat_id() {

    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "Renseigne TELEGRAM_BOT_TOKEN dans le fichier de réponses."

    local resp
    resp="$(printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$TELEGRAM_BOT_TOKEN" | curl -sS --max-time 20 -K - 2>/dev/null || true)"
    jq -e '.ok == true' >/dev/null 2>&1 <<< "$resp" || die "Réponse de Telegram invalide : jeton incorrect ? (le bot doit être arrêté pour lire les messages : systemctl stop homelab-telegram-bot)"

    echo "Discussions ayant écrit au bot :"
    jq -r '[.result[].message.chat | select(. != null) | "\(.id)  \(.first_name // .title // "")  (\(.type))"] | unique | .[]' <<< "$resp" | sed 's/^/  /'
    echo "TELEGRAM_ADMIN_ID = ton identifiant en discussion privée (type private).
  Mets l'identifiant voulu dans TELEGRAM_CHAT_ID. Si la liste est vide : envoie d'abord un message à ton bot."
}

# ./install.sh --run telegram_test : message de test sur Telegram.
telegram_test() {

    [[ -x /usr/local/sbin/homelab-notify ]] || die "Notifications non installées (./install.sh --run configure_notify)."
    /usr/local/sbin/homelab-notify -p default -t tada -c all "Homelab : test Telegram" "Si tu lis ceci, les alertes Telegram fonctionnent (${NODE_NAME:-$(hostname -s)})." 
    info "Test envoyé ; l'envoi est tenté sur Telegram seulement si TELEGRAM_ALERTS contient « all » ou la catégorie."
}

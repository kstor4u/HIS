#!/usr/bin/env bash
# Fonctions communes du serveur de sauvegarde homelab (N54L).
# Chargé par homelab-backup-run / -export / -ctl. Ne s'exécute pas seul.

HB_VERSION="2.0.0"
HB_ETC="${HB_ETC:-/etc/homelab-backup}"
HB_STATE="${HB_STATE:-/var/lib/homelab-backup}"
HB_LOG="${HB_LOG:-/var/log/homelab-backup.log}"
HB_SCHEMA="${HB_SCHEMA:-/usr/local/share/homelab-backup/schema.txt}"

# --- Valeurs par défaut (surchargées par /etc/homelab-backup/backup.json) -----
BACKUP_ROOT="/mnt/backups"
BACKUP_MOUNT=""              # point de montage du volume (vide = BACKUP_ROOT) ; BACKUP_ROOT peut être un sous-dossier
CHANGE_THRESHOLD=10          # % de fichiers modifiés/supprimés au-delà duquel on alerte
KEEP_LAST=8                  # derniers instantanés valides conservés
KEEP_MONTHLY=12              # + le premier instantané de chacun des N derniers mois
WAKE_DAY="Sunday"            # jour du réveil (nom anglais : Sunday, Monday...)
WAKE_TIME="03:00"
MAX_RUNTIME_H=8              # durée maximale d'une sauvegarde avant arrêt forcé
POWER_OFF="true"             # s'éteindre et programmer le réveil suivant
WAKE_TOLERANCE_MIN=180       # un démarrage proche du réveil prévu (±) = démarrage automatique
EXPORT_MARKER="HOMELAB-BACKUP"
EXPORT_KEEP=1                # exports conservés par cluster sur le disque externe
EXPORT_ALLOWED_UUIDS=""      # vide = tout disque portant le fichier marqueur
MAIL_TO=""
MAIL_FROM=""
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASSWORD=""
SMTP_TLS="starttls"          # starttls | tls | off
REPORT_ALWAYS="true"         # mail récapitulatif à chaque sauvegarde (sinon : seulement alertes)
HEARTBEAT_URL=""             # ex. URL « push » d'Uptime Kuma, appelée après une sauvegarde réussie
CHECK_MONTHLY="true"         # contrôle périodique du RAID et de l'intégrité des sauvegardes
CHECK_INTERVAL_DAYS=28       # intervalle entre deux contrôles complets
CHECK_RAID="true"            # scrub mdadm / ZFS / btrfs
CHECK_DATA="true"            # relecture de tous les fichiers + comparaison aux empreintes mémorisées
CHECK_MAX_H=20               # durée maximale d'un contrôle ; au-delà il est interrompu et REPREND au prochain démarrage
NETWORK_MODE=""              # "dhcp" = passe le pont réseau du N54L en DHCP (voir homelab-backup-net)
NETWORK_BRIDGE="vmbr0"

# --- Lecture d'un fichier JSON : variables (noms en majuscules), null = valeur par défaut ------------
# Les groupes du JSON sont organisationnels : seul le nom de la variable compte (clés « _... » ignorées).
# Booléens et nombres deviennent du texte (true/false, 8). Aucune valeur n'est interprétée par le shell.
hb_json_vars() {
    local f="$1" rec name val
    jq -e 'type == "object"' "$f" > /dev/null 2>&1 || { echo "JSON invalide : $f" >&2; return 1; }
    while IFS= read -r -d $'\x1e' rec; do
        name="${rec%%$'\x1f'*}"
        val="${rec#*$'\x1f'}"
        [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        case "$name" in PATH | IFS | HOME | SHELL | USER | LD_* | BASH* | HB_*) continue ;; esac
        printf -v "$name" '%s' "$val"
    done < <(jq -j 'paths(scalars) as $p | ($p | last) as $k | getpath($p) as $v
                    | select(($k | type) == "string") | select($k | startswith("_") | not) | select($v != null)
                    | "\($k)\u001f\($v | tostring)\u001e"' "$f")
}

hb_load_conf() {
    local f="$HB_ETC/backup.json"
    [[ -f "$f" ]] || { echo "Configuration absente : $f (relance ./install.sh pour la créer)" >&2; return 1; }
    command -v jq > /dev/null 2>&1 || { echo "jq est requis (apt install jq)." >&2; return 1; }
    hb_json_vars "$f" || return 1
    mkdir -p "$HB_STATE"
}

# Modifie une valeur de backup.json (le type existant, nombre ou booléen, est conservé) ; l'ajoute au groupe « volume » si absente.
hb_conf_set() {
    local k="$1" v="$2" f="$HB_ETC/backup.json" tmp
    [[ -f "$f" ]] || { echo "$f introuvable : lance d'abord ./install.sh." >&2; return 1; }
    tmp="$(mktemp)"
    if jq --arg k "$k" --arg v "$v" '
            ([paths(scalars) | select(.[-1] == $k)] | first) as $p
            | if $p == null then .volume[$k] = $v
              else (getpath($p) | type) as $t
                   | setpath($p; if $t == "number" then ($v | tonumber) elif $t == "boolean" then ($v == "true") else $v end)
              end' "$f" > "$tmp"; then
        cat "$tmp" > "$f"
        rm -f "$tmp"
    else
        rm -f "$tmp"; echo "Impossible de modifier $k dans $f." >&2; return 1
    fi
}

# --- Schéma des variables (conf/schema.txt : V^groupe^NOM^type^défaut^description) ---------------------
# Source unique du fichier neuf, de la fusion après mise à jour et de « homelab-backup-ctl describe ».
hb_schema_json() {
    local schema="${1:-$HB_SCHEMA}"
    awk -F'^' '$1 == "V" { printf "%s\037%s\037%s\037%s\n", $2, $3, $4, $5 }' "$schema" |
        jq -R -s --arg v "$HB_VERSION" '
            split("\n") | map(select(length > 0) | split("\u001f"))
            | reduce .[] as $r ({};
                .[$r[0]][$r[1]] = (if $r[2] == "int" then ($r[3] | tonumber)
                                   elif $r[2] == "bool" then ($r[3] == "true")
                                   else $r[3] end))
            | {_version: $v,
               _note: "Réglages du serveur de sauvegarde. Les groupes sont organisationnels : seul le nom de la variable compte. homelab-backup-ctl describe NOM explique chaque variable."} + .'
}

hb_describe() {   # [motif] : NOM  type  défaut  description
    local schema="${HB_SCHEMA}" pat="${1:-}"
    awk -F'^' -v p="$pat" '$1 == "V" && (p == "" || index($3, p) == 1) { printf "%s  [%s, défaut : %s]  (%s)\n    %s\n", $3, $4, ($5 == "" ? "vide" : $5), $2, $6 }' "$schema"
}

# --- Fusion après une mise à jour --------------------------------------------------------------------
# hb_merge_conf <schéma> <backup.json>
# Conserve TES valeurs, ajoute les variables apparues depuis (listées dans « _nouveau »), garde ce que le schéma ne
# connaît pas. Ancien fichier : <fichier>.bak-<date>. Code retour : 0 = à jour, 10 = variables ajoutées.
hb_merge_conf() {
    local schema="$1" file="$2" tpl out tmp bak mode names
    tpl="$(hb_schema_json "$schema")" || return 1
    tmp="$(mktemp)"
    jq --argjson tpl "$tpl" '
        . as $u
        | ([$u | paths(scalars) | select((.[-1] | type) == "string") | .[-1]]) as $have
        | [$tpl | paths(scalars) | select((.[-1] | startswith("_")) | not) | select(.[-1] as $n | ($have | index($n)) == null)] as $miss
        | reduce $miss[] as $p ($u; setpath($p; ($tpl | getpath($p))))
        | if ($miss | length) > 0 then ._nouveau = [$miss[] | .[-1]] else . end' "$file" > "$tmp" || { rm -f "$tmp"; echo "Fusion impossible : $file n'est pas un JSON valide." >&2; return 1; }

    names="$(jq -r '(._nouveau // []) | join(" ")' "$tmp")"
    if [[ "$names" == "$(jq -r '(._nouveau // []) | join(" ")' "$file")" ]]; then
        rm -f "$tmp"; echo "backup.json à jour : aucune variable nouvelle."; return 0
    fi
    bak="${file}.bak-$(date +%Y%m%d-%H%M%S)"; mode="$(stat -c %a "$file" 2> /dev/null || echo 600)"
    cp -p "$file" "$bak"; cat "$tmp" > "$file"; chmod "$mode" "$file" 2> /dev/null || true; rm -f "$tmp"
    echo "backup.json mis à jour : tes valeurs sont conservées (ancien fichier : $bak)."
    echo "Variables ajoutées (liste « _nouveau » dans le fichier ; homelab-backup-ctl describe NOM) : ${names}"
    return 10
}

log() { local m; m="$(date '+%F %T') $*"; echo "$m"; echo "$m" >> "$HB_LOG" 2> /dev/null || true; }

# --- Mail ---------------------------------------------------------------------
# hb_mail "sujet" "corps"  (corps sur stdin si 2e argument absent)
hb_mail() {
    local subject="$1" body
    if [[ $# -ge 2 ]]; then body="$2"; else body="$(cat)"; fi

    if [[ -z "$MAIL_TO" ]] || ! command -v msmtp > /dev/null 2>&1 || [[ ! -f "$HB_ETC/msmtprc" ]]; then
        log "MAIL (non envoyé, mail non configuré) : $subject"
        return 0
    fi

    local subj_b64
    subj_b64="$(printf '%s' "$subject" | base64 -w0)"
    {
        printf 'From: %s\n' "${MAIL_FROM:-$MAIL_TO}"
        printf 'To: %s\n' "$MAIL_TO"
        printf 'Subject: =?UTF-8?B?%s?=\n' "$subj_b64"
        printf 'Date: %s\n' "$(date -R)"
        printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n'
        printf '%s\n' "$body"
    } | msmtp -C "$HB_ETC/msmtprc" -t || log "ATTENTION : l'envoi du mail a échoué ($subject)"
}

# --- Telegram ---------------------------------------------------------------------
# hb_notify <catégorie> <titre> <message>
# Catégories : usb (disque branché, export) | backup (démarrage, début/fin de chaque source, rapport,
# extinction) | check (RAID + intégrité) | restore (test de restauration) | alert (échecs et alertes).
# N'envoie que celles de TELEGRAM_EVENTS (« all » = tout). Jamais bloquant ; le mail reste inchangé.
hb_notify() {
    local cat="$1" title="$2" msg="${3:-}" emoji chat
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
    case " ${TELEGRAM_EVENTS:-usb backup check restore alert power security} " in
        *" all "* | *" ${cat} "*) ;;
        *) return 0 ;;
    esac
    case "$cat" in
        usb) emoji="💽" ;; power) emoji="🔌" ;; backup) emoji="💾" ;; check) emoji="🔎" ;; restore) emoji="♻️" ;; alert) emoji="⚠️" ;; security) emoji="🚨" ;; *) emoji="🔔" ;;
    esac
    (( ${#msg} > 3500 )) && msg="${msg:0:3500}…"
    for chat in ${TELEGRAM_CHAT_ID//,/ }; do
        printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
            curl -fsS --max-time 15 -K - --data-urlencode "chat_id=${chat}" \
                --data-urlencode "text=${emoji} [$(hostname -s)] ${title}"$'\n'"${msg}" > /dev/null 2>&1 \
            || log "Telegram : envoi impossible (${title})"
    done
    return 0
}

# --- Prochain réveil ----------------------------------------------------------
# Epoch du prochain WAKE_DAY WAKE_TIME strictement dans le futur (+ 10 min de marge).
hb_next_wake_epoch() {
    local now cand
    now="$(date +%s)"
    cand="$(date -d "${WAKE_DAY} ${WAKE_TIME}" +%s)"          # prochain jour (aujourd'hui inclus)
    while (( cand <= now + 600 )); do cand=$(( cand + 604800 )); done
    echo "$cand"
}

hb_snap_valid_list() {   # instantanés valides d'un cluster, du plus ancien au plus récent
    local dir="$BACKUP_ROOT/$1/snaps"
    [[ -d "$dir" ]] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '*.SUSPECT' ! -name '.tmp-*' -printf '%f\n' | sort
}

# --- Sources (un fichier JSON par serveur sauvegardé : sources.d/<nom>.json) -----------------------
hb_source_names() {
    local f
    for f in "$HB_ETC"/sources.d/*.json; do
        [[ -e "$f" ]] || continue
        basename "$f" .json
    done
}

# hb_source_load <nom> : positionne HOST USER PORT PATHS SSH_KEY THRESHOLD EXCLUDES CANARIES WG_CONF dans l'appelant
# (déclarer ces variables « local » avant l'appel). Les listes du JSON (tableaux) deviennent des mots séparés par des espaces.
# Code retour 1 et message dans HB_SRC_ERR si le fichier est absent, invalide ou contient une valeur dangereuse.
hb_source_load() {
    local name="$1" f="$HB_ETC/sources.d/$1.json" rec k v item
    local -a items=()
    HB_SRC_ERR=""
    [[ -f "$f" ]] || { HB_SRC_ERR="source inconnue ($f absent)"; return 1; }
    jq -e 'type == "object"' "$f" > /dev/null 2>&1 || { HB_SRC_ERR="JSON invalide ($f)"; return 1; }

    HOST="" USER="backup-pull" PORT=22 PATHS="" SSH_KEY="/root/.ssh/homelab-pull" THRESHOLD="" EXCLUDES="" CANARIES="" WG_CONF=""
    while IFS= read -r -d $'\x1e' rec; do
        k="${rec%%$'\x1f'*}"
        v="${rec#*$'\x1f'}"
        case "$k" in HOST | USER | PORT | PATHS | SSH_KEY | THRESHOLD | EXCLUDES | CANARIES | WG_CONF) printf -v "$k" '%s' "$v" ;; esac
    done < <(jq -j 'to_entries[] | select(.key | startswith("_") | not) | select(.value != null)
                    | "\(.key)\u001f\(if (.value | type) == "array" then (.value | map(tostring) | join(" ")) else (.value | tostring) end)\u001e"' "$f")

    [[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || { HB_SRC_ERR="HOST absent ou invalide"; return 1; }
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { HB_SRC_ERR="PORT invalide"; return 1; }
    [[ "$USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { HB_SRC_ERR="USER invalide"; return 1; }
    [[ -z "$WG_CONF" || "$WG_CONF" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || { HB_SRC_ERR="WG_CONF invalide"; return 1; }
    [[ -z "$THRESHOLD" || "$THRESHOLD" =~ ^[0-9]+$ ]] || { HB_SRC_ERR="THRESHOLD invalide"; return 1; }
    [[ -n "$PATHS" ]] || { HB_SRC_ERR="PATHS vide"; return 1; }
    # Chemins relatifs à la racine de tirage : pas de « .. », pas de chemin absolu, caractères sûrs (pas de globbing).
    read -ra items <<< "$PATHS $CANARIES"
    for item in "${items[@]}"; do
        [[ "$item" =~ ^[A-Za-z0-9._@+-][A-Za-z0-9._@+/-]*$ && "$item" != *..* ]] || { HB_SRC_ERR="chemin invalide : ${item}"; return 1; }
    done
    return 0
}

# Chemins d'un fichier source : sites (premier niveau du chemin) qui ont des applications, pour les tests.
hb_source_sites() {   # <dossier d'instantané> : un chemin « <site>/apps/backups/db » par ligne (ou « apps/backups/db » sans site)
    local root="$1"
    find "$root" -mindepth 3 -maxdepth 4 -type d -path '*/apps/backups/db' 2> /dev/null | sort
}

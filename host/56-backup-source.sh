###############################################################################
#     SERVEUR DE SAUVEGARDE : GÉNÉRATION AUTOMATIQUE DU FICHIER « SOURCE »    #
###############################################################################

# But : ne plus rien recopier à la main entre ce serveur et le serveur de sauvegarde (N54L).
# Les CLÉS PRIVÉES NE VOYAGENT JAMAIS : chaque côté génère les siennes.
#
#   1. Sur le N54L :     homelab-backup-ctl request <nom>
#                        -> affiche une demande « HBREQ1:... » (clé SSH publique + clé WireGuard publique)
#   2. Sur ce serveur :  ./install.sh --run backup_source_export <nom> 'HBREQ1:...'
#                        -> autorise la clé SSH (lecture seule), crée le pair WireGuard (profil backup),
#                           et fabrique le paquet « HBSRC2:... » (fichier source JSON + config WireGuard SANS clé privée)
#   3. Sur le N54L :     homelab-backup-ctl add-source 'HBSRC2:...'
#                        -> installe sources.d/<nom>.json et /etc/wireguard/<nom>.conf (avec SA clé privée)
#                           puis teste le tunnel, l'accès SSH, les dossiers et les fichiers témoins.
#
# Autres commandes : backup_source_list | backup_source_revoke <nom>

BACKUP_SOURCES_DIR="/var/lib/homelab/backup-sources"

# Fichier source JSON du serveur de sauvegarde (N54L ≥ 2.0.0) : backup_source_json HOST PORT USER WG_CONF "chemins" "témoins"
# (chemins et témoins : listes séparées par des espaces, relatives au point de montage des données ; tous les sites).
backup_source_json() {
    local host="$1" port="$2" user="$3" wg="$4" paths="$5" canaries="$6"
    jq -n --arg host "$host" --argjson port "$port" --arg user "$user" --arg wg "$wg" \
        --arg paths "$paths" --arg canaries "$canaries" --arg note "Généré le $(date '+%F %T') par $(hostname -s) (installateur ${SCRIPT_VERSION}) : aucun secret." \
        '{_note: $note, HOST: $host, PORT: $port, USER: $user}
         + (if $wg != "" then {WG_CONF: $wg} else {} end)
         + {PATHS: ($paths | split(" ") | map(select(. != ""))), CANARIES: ($canaries | split(" ") | map(select(. != "")))}'
}

# Ligne authorized_keys d'une clé de tirage : lecture seule, rrsync sur DATA_MOUNT, rien d'autre.
backup_pull_key_line() {

    local keytype="$1" keydata="$2" comment="$3" from_opt=""

    [[ -n "${BACKUP_PULL_FROM:-}" ]] && from_opt=",from=\"${BACKUP_PULL_FROM}\""

    printf 'command="env PATH=/usr/local/lib/homelab/bin:/usr/bin:/bin /usr/local/lib/homelab/rrsync -ro %s",restrict%s %s %s %s\n' \
        "$DATA_MOUNT" "$from_opt" "$keytype" "$keydata" "$comment"
}

# Décode et valide une demande HBREQ1 -> REQ_NAME, REQ_SSH, REQ_WG
backup_source_parse_request() {

    local token="$1" raw line

    [[ "$token" == HBREQ1:* ]] || die "Demande invalide : elle doit commencer par HBREQ1: (voir sur le N54L : homelab-backup-ctl request <nom>)."

    raw="$(printf '%s' "${token#HBREQ1:}" | base64 -d 2>/dev/null)" || die "Demande illisible (base64)."

    REQ_NAME="" REQ_SSH="" REQ_WG=""
    while IFS= read -r line; do
        case "$line" in
            name=*) REQ_NAME="${line#name=}" ;;
            ssh=*)  REQ_SSH="${line#ssh=}" ;;
            wg=*)   REQ_WG="${line#wg=}" ;;
        esac
    done <<< "$raw"

    [[ "$REQ_NAME" =~ ^[a-z0-9][a-z0-9-]{0,11}$ ]] || die "Nom de source invalide dans la demande ('${REQ_NAME}') : 1 à 12 caractères a-z 0-9 -."
    [[ "$REQ_SSH" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)\ [A-Za-z0-9+/=]+$ ]] || die "Clé SSH publique invalide dans la demande."
    [[ "$REQ_WG" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "Clé WireGuard publique invalide dans la demande."
}

# Ajoute (ou remplace) la clé de tirage d'une source dans le compte de tirage.
backup_pull_add_key() {

    local name="$1" sshkey="$2" user="${BACKUP_PULL_USER:-backup-pull}"
    local home="/var/lib/${user}" file keytype keydata tmp

    file="${home}/.ssh/authorized_keys"
    read -r keytype keydata _ <<< "$sshkey"

    install -d -m 755 -o root -g root "$home" "${home}/.ssh"
    tmp="$(mktemp)"
    { grep -v " homelab-pull-${name}\$" "$file" 2>/dev/null || true; } > "$tmp"
    backup_pull_key_line "$keytype" "$keydata" "homelab-pull-${name}" >> "$tmp"
    install -m 644 -o root -g root "$tmp" "$file"
    rm -f "$tmp"
}

# Chemins à sauvegarder qui existent réellement.
backup_source_paths() {

    local out="" p

    for p in proxmox/dump $(sites_data_dirs | awk '!s[$0]++' | sed "s|^${DATA_MOUNT}/||"); do
        [[ -d "${DATA_MOUNT}/${p}" ]] && out+="${out:+ }${p}"
    done
    printf '%s' "$out"
}

backup_source_canaries() {

    local out="" f

    [[ "$BACKUP_CANARY" == "true" ]] || return 0

    local d rel
    for d in "${SITE_LIST[@]}"; do
        rel="${SITE_SHARED[$d]#"${DATA_MOUNT}"/}"
        for f in "${rel}/00_temoin/temoin.docx" "${rel}/00_temoin/temoin.jpg" "${rel}/00_temoin/temoin.avi" "${SITE_APPS[$d]#"${DATA_MOUNT}"/}/00_temoin/temoin.docx"; do
            [[ -f "${DATA_MOUNT}/${f}" ]] && out+="${out:+ }${f}"
        done
    done
    printf '%s' "$out"
}

# Nom de source par défaut : le nom d'hôte du serveur (nettoyé, 12 caractères au plus).
backup_source_default_name() {
    local n
    n="$(hostname -s | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-' | cut -c1-12)"
    [[ "$n" =~ ^[a-z0-9] ]] || n="srv${n}"
    printf '%s' "${n:0:12}"
}

# Fichier source prêt à copier, produit à chaque installation quand le tirage est activé
# (sans demande du N54L : pas de tunnel WireGuard propre à ce serveur ; pour l'avoir, utiliser backup_source_export).
backup_source_auto() {

    [[ "${ENABLE_BACKUP_PULL:-false}" == "true" ]] || return 0

    local name host paths canaries out
    name="$(backup_source_default_name)"
    paths="$(backup_source_paths)"
    [[ -n "$paths" ]] || { warn "Fichier source N54L non généré : aucun dossier à sauvegarder dans ${DATA_MOUNT}."; return 0; }
    canaries="$(backup_source_canaries)"

    if [[ "$ENABLE_WIREGUARD" == "true" ]]; then host="${PRIVATE_GW}"; else host="${WG_ENDPOINT:-$DOMAIN}"; fi

    install -d -m 700 "$BACKUP_SOURCES_DIR"
    out="${BACKUP_SOURCES_DIR}/${name}.json"
    ( umask 077; backup_source_json "$host" 22 "${BACKUP_PULL_USER:-backup-pull}" "" "$paths" "$canaries" > "$out" )
    chmod 600 "$out"
    info "Serveur de sauvegarde : fichier source généré -> ${out} (à copier dans /etc/homelab-backup/sources.d/${name}.json du N54L ; sans tunnel WireGuard propre : le plus simple est « homelab-backup-ctl request ${name} » puis backup_source_export)."
    [[ "$ENABLE_WIREGUARD" == "true" ]] || warn "Sans WireGuard, ce serveur doit être joignable en SSH sur ${host}:22 : à éviter sur Internet."
}

# Fichiers marqueurs pour les disques USB :
#   serveur : disque branché SUR CE SERVEUR (export de ses sauvegardes) -> ${BACKUP_USB_MARKER}
#   n54l    : disque branché sur le serveur de sauvegarde (export des instantanés de cette source)
# Usage : ./install.sh --run usb_marker_generate [serveur|n54l|tous] [/point/de/montage-du-disque]
usb_marker_generate() {

    local which="${1:-tous}" dest="${2:-}" dir="/var/lib/homelab/usb-marker" name marker_n54l
    name="$(backup_source_default_name)"
    marker_n54l="${BACKUP_USB_MARKER}"
    install -d -m 755 "$dir"

    if [[ "$which" == "serveur" || "$which" == "tous" ]]; then
        cat > "${dir}/${BACKUP_USB_MARKER}" <<MK
# Marqueur d'export USB de ${NODE_NAME:-$(hostname -s)} : à copier à la racine du disque (le disque n'est utilisé que s'il porte ce fichier).
content=${BACKUP_USB_CONTENT// /,}
keep=${BACKUP_USB_KEEP}
# fresh=yes     # yes = nouvelle sauvegarde vzdump avant l'export
MK
        info "Marqueur USB (ce serveur) : ${dir}/${BACKUP_USB_MARKER}"
    fi

    if [[ "$which" == "n54l" || "$which" == "tous" ]]; then
        cat > "${dir}/${marker_n54l}.n54l" <<MK
# Marqueur d'export USB du serveur de sauvegarde (N54L) : à copier à la racine du disque, sous le nom ${marker_n54l}.
clusters=${name}
keep=${BACKUP_USB_KEEP}
MK
        info "Marqueur USB (serveur de sauvegarde) : ${dir}/${marker_n54l}.n54l  (à renommer ${marker_n54l} sur le disque)"
    fi

    if [[ -n "$dest" ]]; then
        [[ -d "$dest" ]] || die "usb_marker_generate : '${dest}' n'est pas un dossier (point de montage du disque)."
        [[ "$which" == "tous" ]] && die "usb_marker_generate : précise 'serveur' ou 'n54l' pour copier sur un disque."
        if [[ "$which" == "serveur" ]]; then cp "${dir}/${BACKUP_USB_MARKER}" "${dest}/${BACKUP_USB_MARKER}"
        else cp "${dir}/${marker_n54l}.n54l" "${dest}/${marker_n54l}"; fi
        info "Marqueur copié sur ${dest}."
    fi
}

# backup_source_export [nom] [HBREQ1:...]
backup_source_export() {

    local name="${1:-}" token="${2:-}"

    # Forme courte : backup_source_export 'HBREQ1:...' (le nom vient de la demande)
    if [[ "$name" == HBREQ1:* ]]; then
        token="$name"
        backup_source_parse_request "$token"
        name="$REQ_NAME"
    fi
    [[ -n "$name" ]] || name="$(backup_source_default_name)"

    local user="${BACKUP_PULL_USER:-backup-pull}" host port=22 use_wg=false
    local peer="bk-${name}" conf="" srv_conf bundle_dir out_file paths canaries

    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,11}$ ]] \
        || die "usage : backup_source_export [nom] [HBREQ1:...]   (nom : 1 à 12 caractères a-z 0-9 -, défaut : nom d'hôte)"

    paths="$(backup_source_paths)"
    [[ -n "$paths" ]] || die "Aucun dossier à sauvegarder trouvé dans ${DATA_MOUNT}."

    # Accès de tirage (compte sans root, rsync à capacité de lecture, témoins) : mis en place si besoin.
    ENABLE_BACKUP_PULL=true
    configure_backup_pull_access

    if [[ -n "$token" ]]; then

        backup_source_parse_request "$token"
        [[ "$REQ_NAME" == "$name" ]] || die "La demande est faite pour la source '${REQ_NAME}', pas '${name}'."

        backup_pull_add_key "$name" "$REQ_SSH"
        info "Sauvegardes : clé SSH de '${name}' autorisée (lecture seule, ${DATA_MOUNT})."
    else
        warn "Pas de demande (HBREQ1) : seul le fichier source sera produit, sans clé SSH ni WireGuard. Pour tout automatiser : sur le N54L, homelab-backup-ctl request ${name}"
    fi

    if [[ "$ENABLE_WIREGUARD" == "true" && -n "$token" ]]; then

        use_wg=true
        wg_ensure_backup_peer "$peer" "$REQ_WG"

        # wg-homelab show ajoute un QR code après une ligne vide si qrencode est présent : on le coupe.
        srv_conf="$(wg_show_peer "$peer" | awk '/^$/{exit} {print}')"
        conf="${srv_conf//<CLE_PRIVEE_DU_CLIENT>/@WG_PRIVATE_KEY@}"
        grep -q '@WG_PRIVATE_KEY@' <<< "$conf" || die "Configuration WireGuard du pair '${peer}' inattendue (clé privée du client absente du modèle)."
        host="${PRIVATE_GW}"
    else
        host="${WG_ENDPOINT:-$DOMAIN}"
        warn "Sans tunnel WireGuard, le N54L devra joindre ${host}:${port} en SSH : à éviter sur Internet. Active ENABLE_WIREGUARD et refais la demande."
    fi

    canaries="$(backup_source_canaries)"
    install -d -m 700 "$BACKUP_SOURCES_DIR"
    out_file="${BACKUP_SOURCES_DIR}/${name}.hbsrc"

    {
        echo "#HBSRC2"
        echo "name=${name}"
        echo "@@FILE sources.d/${name}.json"
        backup_source_json "$host" "$port" "$user" "$([[ "$use_wg" == "true" ]] && echo "$name")" "$paths" "$canaries"
        echo "@@END"
        if [[ "$use_wg" == "true" ]]; then
            echo "@@FILE wireguard/${name}.conf"
            printf '%s\n' "$conf"
            echo "@@END"
        fi
    } > "$out_file"
    chmod 600 "$out_file"

    echo
    echo "Paquet source pour '${name}' : ${out_file}"
    echo "  Chemins   : ${paths}"
    echo "  Témoins   : ${canaries:-aucun}"
    echo "  Tunnel    : $([[ "$use_wg" == "true" ]] && echo "WireGuard (profil backup, pair ${peer}), HOST=${host} dans le tunnel" || echo "aucun")"
    echo
    echo "Sur le N54L, colle cette ligne (ou copie le fichier et donne son chemin) :"
    echo
    echo "  homelab-backup-ctl add-source 'HBSRC2:$(base64 -w0 "$out_file")'"
    echo
    echo "Le paquet ne contient aucune clé privée (la clé WireGuard du N54L est ajoutée sur place)."
}

# Crée le pair WireGuard (profil backup) avec la clé publique fournie ; idempotent.
wg_ensure_backup_peer() {

    local peer="$1" pub="$2" cur

    cur="$(pct exec "$WG_ID" -- awk -v n="$peer" '$1==n{print $4}' /etc/wireguard/peers.list 2>/dev/null || true)"

    if [[ -n "$cur" ]]; then
        if [[ "$cur" == "$pub" ]]; then
            info "WireGuard : pair '${peer}' déjà présent avec la même clé."
            return 0
        fi
        warn "WireGuard : pair '${peer}' existant avec une AUTRE clé : remplacé (nouvelle demande)."
        wg_remove_peer "$peer"
    fi

    # Le profil backup doit pouvoir joindre l'hôte (rrsync) : environnement du CT à jour avant d'ajouter le pair.
    wg_push_files
    wg_add_peer "$peer" backup --pubkey "$pub" >/dev/null
    info "WireGuard : pair '${peer}' créé (profil backup)."
}

backup_source_list() {

    local user="${BACKUP_PULL_USER:-backup-pull}" f="/var/lib/${BACKUP_PULL_USER:-backup-pull}/.ssh/authorized_keys"

    echo "Clés de tirage autorisées (${f}) :"
    awk '{print "  " $NF}' "$f" 2>/dev/null || echo "  (aucune)"
    echo
    echo "Paquets générés (${BACKUP_SOURCES_DIR}) :"
    ls -1 "$BACKUP_SOURCES_DIR" 2>/dev/null | sed 's/^/  /' || true
    : "$user"
}

backup_source_revoke() {

    local name="${1:-}" user="${BACKUP_PULL_USER:-backup-pull}" f

    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,11}$ ]] || die "usage : backup_source_revoke <nom>"
    f="/var/lib/${user}/.ssh/authorized_keys"

    if [[ -f "$f" ]]; then
        sed -i "/ homelab-pull-${name}\$/d" "$f"
    fi
    pct exec "$WG_ID" -- grep -q "^bk-${name} " /etc/wireguard/peers.list 2>/dev/null && wg_remove_peer "bk-${name}" || true
    rm -f "${BACKUP_SOURCES_DIR}/${name}.hbsrc" "${BACKUP_SOURCES_DIR}/${name}.json"

    info "Source '${name}' révoquée : clé SSH retirée, pair WireGuard supprimé."
}

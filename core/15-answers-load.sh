###############################################################################
#                              FICHIER DE RÉPONSES                            #
###############################################################################

# Charge le fichier de réponses (JSON) s'il existe, pour éviter de retaper mots de passe / email / wallet à chaque test.
# Chaque variable (clé feuille du JSON, quel que soit son groupe) devient une variable du script ; null = défaut du script.
# Format : voir core/05-answers.sh et proxmox-homelab-variables.md.

# Affecte les variables d'un fichier JSON. Retourne 1 si le fichier est invalide.
answers_load_json() {

    local file="$1" tmp k v i
    local -a unknown=() ref_k=() ref_v=()

    answers_require_jq || return 1
    answers_schema_load

    if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
        warn "${file} n'est pas un JSON valide :"
        jq . "$file" 2>&1 | head -3 | sed 's/^/    /' >&2 || true
        return 1
    fi

    tmp="$(mktemp)"
    if ! jq -j "$ANSWERS_JQ_LEAVES" "$file" > "$tmp" 2> /dev/null; then
        rm -f "$tmp"
        warn "${file} : valeur non prise en charge (une liste ne peut contenir que des textes, nombres ou true/false)."
        return 1
    fi

    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
        if [[ ! "$k" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            warn "${file} : clé ignorée (nom de variable invalide) : ${k}"
            continue
        fi
        if answers_forbidden_name "$k"; then
            warn "${file} : variable réservée ignorée : ${k}"
            continue
        fi
        [[ -n "${SCHEMA_GROUP[$k]+x}" ]] || unknown+=("$k")
        if [[ "${SCHEMA_TYPE[$k]:-}" == "ref" ]]; then
            ref_k+=("$k"); ref_v+=("$v")          # références ${AUTRE} résolues après les autres variables
        else
            printf -v "$k" '%s' "$v"
        fi
    done < "$tmp"
    rm -f "$tmp"

    for i in "${!ref_k[@]}"; do
        printf -v "${ref_k[$i]}" '%s' "$(answers_expand_refs "${ref_v[$i]}")"
    done

    if (( ${#unknown[@]} > 0 )); then
        warn "Variables inconnues du modèle (appliquées telles quelles ; faute de frappe ?) : ${unknown[*]}"
    fi
    return 0
}

# Remplace ${NOM} par la valeur de la variable NOM (rien d'autre n'est évalué).
answers_expand_refs() {
    local rest="$1" out="" n
    local re='^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$'
    while [[ "$rest" =~ $re ]]; do
        n="${BASH_REMATCH[2]}"
        out+="${BASH_REMATCH[1]}${!n-}"
        rest="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${rest}"
}

load_answers_file() {

    if [[ -f "$ANSWERS_FILE" ]]; then

        info "Chargement des réponses depuis ${ANSWERS_FILE}..."

        answers_load_json "$ANSWERS_FILE" || die "Fichier de réponses invalide : ${ANSWERS_FILE}"

        ANSWERS_FILE_LOADED=true

        secrets_load

    else

        info "Pas de fichier de réponses (${ANSWERS_FILE} introuvable) : mode interactif complet."
    fi

    # Sous-domaines : un ou plusieurs noms par service ; les variables ne gardent que le nom principal
    normalize_subdomains

    # Sites (domaines) : racine des données du site principal, sites secondaires
    sites_load

    # Stockage des invités et valeurs qui en dépendent
    resolve_guest_storage
}

###############################################################################
#        SECRETS GÉNÉRÉS : conservés entre les lancements (fichier séparé)     #
###############################################################################

# Quand tu fournis ton propre fichier de réponses, il n'est jamais modifié. Les mots de passe que le script
# génère (Nextcloud, bases de données, ntfy, AdGuard, portail...) sont alors gardés dans
# ./proxmox-homelab-secrets.json (droits 600) et RECHARGÉS aux lancements suivants. Sans ça, chaque relance
# générait de nouveaux mots de passe alors que les bases de données (volumes Docker) gardaient les anciens :
# les applications ne pouvaient plus s'y connecter (ex. Nextcloud qui reste sur l'assistant d'installation).
# Une valeur écrite dans ton fichier de réponses reste prioritaire.
SECRETS_FILE="${SECRETS_FILE:-./proxmox-homelab-secrets.json}"
SECRET_VARS=(
    NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD
    SYNCIN_ADMIN_PASSWORD SYNCIN_DB_PASSWORD SYNCIN_DB_ROOT_PASSWORD
    SYNCIN_SECRET_1 SYNCIN_SECRET_2 SYNCIN_SECRET_3 SYNCIN_SECRET_4
    IMMICH_DB_PASSWORD ONLYOFFICE_JWT_SECRET
    PORTAL_PASSWORD MONGO_ADMIN_PASSWORD AI_WEBUI_PASSWORD
    DNS_ADMIN_PASSWORD NTFY_ADMIN_PASSWORD
)

# Valeur enregistrée d'un secret (alphanumérique seulement), dans le .json.
secrets_stored_value() {
    local v="$1" val=""
    if [[ -f "$SECRETS_FILE" ]]; then
        val="$(jq -r --arg k "$v" '(.[$k] // empty) | strings' "$SECRETS_FILE" 2> /dev/null | tail -n 1)" || val=""
    fi
    [[ "$val" =~ ^[A-Za-z0-9]+$ ]] && printf '%s' "$val"
    return 0
}

secrets_load() {

    [[ -f "$SECRETS_FILE" ]] || return 0
    answers_require_jq || return 0

    local v val
    for v in "${SECRET_VARS[@]}"; do
        [[ -z "${!v-}" ]] || continue
        val="$(secrets_stored_value "$v")"
        [[ -z "$val" ]] || printf -v "$v" '%s' "$val"
    done
}

secrets_persist() {

    local v val tmp
    command -v jq > /dev/null 2>&1 || return 0

    tmp="$(mktemp 2> /dev/null)" || return 0
    {
        for v in "${SECRET_VARS[@]}"; do
            val="${!v-}"
            [[ -n "$val" ]] || val="$(secrets_stored_value "$v")"
            [[ "$val" =~ ^[A-Za-z0-9]+$ ]] && printf '%s\x1f%s\n' "$v" "$val"
        done
    } | jq -R -n '
        {"_note": "Secrets GÉNÉRÉS par l'"'"'installateur (mis à jour automatiquement). Droits 600 : ne jamais partager ni mettre dans git. Rechargés à chaque lancement pour que les mots de passe restent identiques à ceux des bases de données déjà créées."}
        + (reduce (inputs | split("\u001f")) as $r ({}; .[$r[0]] = $r[1]))' > "$tmp" 2> /dev/null || { rm -f "$tmp"; return 0; }

    if ! cmp -s "$tmp" "$SECRETS_FILE" 2> /dev/null; then
        install -m 600 "$tmp" "$SECRETS_FILE" 2> /dev/null || true
    fi
    rm -f "$tmp"

    return 0
}

# Sauvegarde aussi si le script est interrompu (Ctrl+C) ou arrêté.
trap 'secrets_persist; exit 130' INT TERM

###############################################################################
#           FICHIER DE RÉPONSES GÉNÉRÉ APRÈS UNE INSTALLATION INTERACTIVE      #
###############################################################################

# Sans fichier de réponses, l'installation est interactive. Pour ne rien perdre (mots de passe générés,
# choix du disque, services...), les valeurs EFFECTIVES sont enregistrées dans ./proxmox-homelab-answers.json
# (droits 600) dès la fin des questions, puis complétées quand les secrets des applications sont générés.
# Un fichier fourni par l'utilisateur n'est jamais modifié. Désactiver : ANSWERS_SAVE=false.
# Une variable égale à sa valeur par défaut est écrite à null ; les variables « requises » sont toujours écrites.
declare -gA SERVICE_MODES_USED=()
ANSWERS_AUTOGEN=false

answers_save_run() {

    [[ "$ANSWERS_FILE_LOADED" != "true" && "${ANSWERS_SAVE:-true}" == "true" ]] || return 0
    [[ ! -e "$ANSWERS_FILE" || "$ANSWERS_AUTOGEN" == "true" ]] || return 0
    answers_require_jq || return 0
    answers_schema_load

    local out n g t cur def first=false isnull decl
    [[ "$ANSWERS_AUTOGEN" == "true" ]] || first=true

    out="$(mktemp)"

    for n in "${SCHEMA_ORDER[@]}"; do
        g="${SCHEMA_GROUP[$n]}"; t="${SCHEMA_TYPE[$n]}"; def="${SCHEMA_DEF[$n]}"
        isnull=0

        if [[ -n "${SUBDOMAIN_RAW[$n]+x}" ]]; then
            cur="${SUBDOMAIN_RAW[$n]}"
        elif [[ -n "${SERVICE_MODES_USED[$n]+x}" ]]; then
            cur="${SERVICE_MODES_USED[$n]}"
        else
            decl="$(declare -p "$n" 2> /dev/null || true)"
            if [[ "$decl" == "declare -a"* || "$decl" == "declare -A"* ]]; then
                cur=""; isnull=1
            else
                cur="${!n-}"
            fi
        fi

        if [[ "${SCHEMA_REQ[$n]}" != "1" ]]; then
            # Valeurs calculées (nom d'hôte, version, cœurs) : on ne les fige pas
            if [[ "$n" == "LOG_FILE" || "$n" == "NODE_NAME" || "$def" == "(calculé)" ]]; then
                isnull=1
            else
                [[ "$t" != "ref" ]] || def="$(answers_expand_refs "$def")"
                [[ "$cur" != "$def" ]] || isnull=1
            fi
        fi

        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$g" "$n" "$t" "$isnull" "$cur"
    done | jq -R -n --arg ver "$SCRIPT_VERSION" --arg when "$(date '+%F %T')" "$ANSWERS_JQ_DEFS"'
        reduce (inputs | split("\u001f")) as $r (
            {"_version": $ver,
             "_note": ("Fichier GÉNÉRÉ par l'"'"'installateur v" + $ver + " le " + $when + " à partir de tes réponses. Il contient des MOTS DE PASSE : droits 600, ne jamais le partager ni le mettre dans git. Relancer ./install.sh le réutilise tel quel (plus aucune question). FORMAT_CONFIRMATION=FORMAT-YES n'"'"'efface que si le disque ne porte pas déjà le label DATA : change DATA_DISK avec prudence. null = valeur par défaut du script ; documentation : proxmox-homelab-variables.md.")};
            .[$r[0]][$r[1]] = (if $r[3] == "1" then null else conv($r[2]; $r[4]) end))' > "$out"

    if ! jq -e 'type == "object"' "$out" > /dev/null 2>&1; then
        rm -f "$out"
        warn "Fichier de réponses non enregistré (génération JSON impossible)."
        return 0
    fi

    install -m 600 "$out" "$ANSWERS_FILE"
    rm -f "$out"
    ANSWERS_AUTOGEN=true

    if [[ "$first" == "true" ]]; then
        info "Fichier de réponses enregistré : ${ANSWERS_FILE} (droits 600, contient tes mots de passe). Relancer ./install.sh le réutilise."
        answers_doc_write "$ANSWERS_FILE" > /dev/null 2>&1 || true
    fi
}

###############################################################################
#                SITES : PLUSIEURS DOMAINES SUR UN MÊME SERVEUR               #
###############################################################################

# Un « site » = un domaine (ipassed.fr, autre.org...) avec SES données dans DATA :
#
#   <racine>/SHARED/   fichiers partagés (Users, Photo, Movies, Music...), groupe Unix propre au site
#   <racine>/apps/     données des applications (immich, nextcloud, syncin, mail, backups)
#
# La racine vaut ${DATA_MOUNT}/<domaine> par défaut, modifiable par site. L'infrastructure reste commune
# (une VM Docker, un SWAG, un CT mail, un DNS...) ; ce module gère le MODÈLE des sites, leurs dossiers et leurs groupes.
#
# Fichier de réponses (JSON), section « sites » (facultative ; absente = un seul site, DOMAIN) :
#   "sites": {
#     "ipassed.fr": { "racine": null },                                   <- site principal (= DOMAIN), facultatif ici
#     "autre.org":  { "racine": "/mnt/data/autre.org", "services": ["nextcloud", "mail", "samba"] }
#   }
#   racine   : dossier du site (null = ${DATA_MOUNT}/<domaine>), y compris pour le site principal.
#   services : parmi nextcloud syncin immich jellyfin homeassistant arr mail samba node (sert à créer les bons dossiers ;
#              le site principal garde tous ses dossiers).
#   groupe, gid : groupe Unix du site (défaut fs_<domaine>, GID libre à partir de 2001). Le site principal garde fileshare/2000.
#
# Les fonctions de ce module ne déplacent jamais de données existantes : le site principal est créé directement dans sa racine.

SITE_SERVICES_KNOWN="nextcloud syncin immich jellyfin homeassistant arr mail samba node"
SITE_GID_BASE=2001

declare -ga SITE_LIST=()                 # domaines, site principal en premier
declare -gA SITE_ROOT=() SITE_SHARED=() SITE_APPS=() SITE_SERVICES=() SITE_GROUP=() SITE_GID=()
SITE_PRIMARY=""
SITE_CUR=""
SITES_LOADED=false
declare -ga _SITE_SAVE=()

site_slug() {
    local s="${1,,}"
    printf '%s' "${s//[^a-z0-9]/_}"
}

# Charge le modèle des sites (section « sites » du JSON) et fixe SHARED_DIR / APPS_DIR du site principal.
sites_load() {

    [[ "$SITES_LOADED" != "true" ]] || return 0

    local line d r s g gi legacy_s="$SHARED_DIR"
    local -a jl=() order=()
    local -A J_ROOT=() J_SVC=() J_GRP=() J_GID=() seen=()

    SITE_LIST=(); SITE_ROOT=(); SITE_SHARED=(); SITE_APPS=(); SITE_SERVICES=(); SITE_GROUP=(); SITE_GID=()
    SITE_PRIMARY="${DOMAIN,,}"

    if [[ -f "${ANSWERS_FILE:-}" ]] && command -v jq > /dev/null 2>&1; then
        while IFS= read -r line; do jl+=("$line"); done < <(jq -r '
            (.sites // {}) | if type == "object" then
                to_entries[]
                | (.value | if type == "object" then . else {} end) as $v
                | [ .key, ($v.racine // ""),
                    (if ($v | has("services")) then (($v.services // []) | if type == "array" then join(" ") else tostring end) else "-" end),
                    ($v.groupe // ""), (($v.gid // "") | tostring) ] | join("\u001f")
            else empty end' "$ANSWERS_FILE" 2> /dev/null || true)
    fi

    for line in "${jl[@]}"; do
        IFS=$'\x1f' read -r d r s g gi <<< "$line"
        d="${d,,}"
        [[ -n "$d" && -z "${seen[$d]+x}" ]] || continue
        seen["$d"]=1
        order+=("$d")
        J_ROOT["$d"]="${r%/}"; J_SVC["$d"]="${s//,/ }"; J_GRP["$d"]="$g"; J_GID["$d"]="$gi"
    done

    SITE_LIST=("$SITE_PRIMARY")
    for d in "${order[@]}"; do [[ "$d" == "$SITE_PRIMARY" ]] || SITE_LIST+=("$d"); done

    for d in "${SITE_LIST[@]}"; do
        s="${J_SVC[$d]:--}"
        if [[ "$s" == "-" ]]; then
            if [[ "$d" == "$SITE_PRIMARY" ]]; then s="$SITE_SERVICES_KNOWN"; else s="samba"; fi
        fi
        SITE_SERVICES["$d"]="${s,,}"
        if [[ "$d" == "$SITE_PRIMARY" ]]; then
            SITE_GROUP["$d"]="$SHARED_GROUP"; SITE_GID["$d"]="$SHARED_GID"
        else
            SITE_GROUP["$d"]="${J_GRP[$d]:-fs_$(site_slug "$d")}"
            SITE_GROUP["$d"]="${SITE_GROUP[$d]:0:32}"
            SITE_GID["$d"]="${J_GID[$d]:-}"
            r="${J_ROOT[$d]:-}"
            [[ -n "$r" ]] || r="${DATA_MOUNT}/${d}"
            SITE_ROOT["$d"]="$r"; SITE_SHARED["$d"]="${r}/SHARED"; SITE_APPS["$d"]="${r}/apps"
        fi
    done

    # --- site principal : racine du JSON, sinon ${DATA_MOUNT}/<domaine> ; SHARED_DIR et APPS_DIR en découlent
    r="${J_ROOT[$SITE_PRIMARY]:-}"
    [[ -n "$r" ]] || r="${DATA_MOUNT}/${SITE_PRIMARY}"
    SITE_ROOT["$SITE_PRIMARY"]="$r"
    SITE_SHARED["$SITE_PRIMARY"]="${r}/SHARED"; SITE_APPS["$SITE_PRIMARY"]="${r}/apps"
    [[ "${AI_DOCS_DIR:-}" != "${legacy_s}/IA/Normes" ]] || AI_DOCS_DIR="${r}/SHARED/IA/Normes"
    SHARED_DIR="${r}/SHARED"; APPS_DIR="${r}/apps"

    SITES_LOADED=true
}

# Contrôles de cohérence des sites (domaines, services, racines, groupes).
validate_sites() {

    local d s a b g
    local re_dom='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
    local -A grp=() gid=()

    for d in "${SITE_LIST[@]}"; do
        [[ "$d" =~ $re_dom ]] || die "Site « ${d} » : nom de domaine invalide."
        for s in ${SITE_SERVICES[$d]}; do
            [[ " $SITE_SERVICES_KNOWN " == *" $s "* ]] || die "Site ${d} : service inconnu « ${s} » (connus : ${SITE_SERVICES_KNOWN})."
        done
        if [[ -n "${SITE_ROOT[$d]}" ]]; then
            [[ "${SITE_ROOT[$d]}" == /* && "${SITE_ROOT[$d]}" != *..* ]] || die "Site ${d} : la racine doit être un chemin absolu sans « .. » (${SITE_ROOT[$d]})."
            [[ "${SITE_ROOT[$d]}" != "/" && "${SITE_ROOT[$d]}" != "$DATA_MOUNT" && "${SITE_ROOT[$d]}" != "$PROXMOX_DATA_DIR" ]] \
                || die "Site ${d} : racine interdite (${SITE_ROOT[$d]})."
        fi
        g="${SITE_GROUP[$d]}"
        [[ "$g" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Site ${d} : nom de groupe invalide (${g})."
        [[ -z "${grp[$g]+x}" ]] || die "Sites ${grp[$g]} et ${d} : même groupe Unix (${g})."
        grp["$g"]="$d"
        if [[ -n "${SITE_GID[$d]}" ]]; then
            [[ "${SITE_GID[$d]}" =~ ^[0-9]+$ ]] || die "Site ${d} : GID invalide (${SITE_GID[$d]})."
            [[ -z "${gid[${SITE_GID[$d]}]+x}" ]] || die "Sites ${gid[${SITE_GID[$d]}]} et ${d} : même GID (${SITE_GID[$d]})."
            gid["${SITE_GID[$d]}"]="$d"
        fi
    done

    # Les dossiers des sites ne doivent ni se confondre ni s'imbriquer.
    for a in "${SITE_LIST[@]}"; do
        for b in "${SITE_LIST[@]}"; do
            [[ "$a" < "$b" ]] || continue
            local pa="${SITE_SHARED[$a]%/SHARED}" pb="${SITE_SHARED[$b]%/SHARED}"
            [[ "$pa" == "$pb" || "$pa" == "$pb"/* || "$pb" == "$pa"/* ]] \
                && die "Sites ${a} et ${b} : dossiers confondus ou imbriqués (${pa} / ${pb})."
        done
    done
    return 0
}

# ------------------------------------------------------------------ contexte d'un site
# GID libre à partir de SITE_GID_BASE pour un groupe qui n'existe pas encore.
site_gid_resolve() {
    local d="$1" g="${SITE_GROUP[$1]}" n v used
    [[ -z "${SITE_GID[$d]}" ]] || return 0
    if getent group "$g" > /dev/null 2>&1; then
        SITE_GID["$d"]="$(getent group "$g" | cut -d: -f3)"
        return 0
    fi
    n=$SITE_GID_BASE
    while :; do
        used=false
        getent group "$n" > /dev/null 2>&1 && used=true
        for v in "${SITE_GID[@]}"; do [[ "$v" == "$n" ]] && used=true; done
        [[ "$used" == "true" ]] || break
        n=$(( n + 1 ))
    done
    SITE_GID["$d"]="$n"
}

# Bascule SHARED_DIR / APPS_DIR / SHARED_GROUP / SHARED_GID sur ceux d'un site ; site_leave restaure.
site_enter() {
    local d="${1,,}"
    [[ -n "${SITE_SHARED[$d]+x}" ]] || die "Site inconnu : ${d}. Sites déclarés : ${SITE_LIST[*]}"
    site_gid_resolve "$d"
    _SITE_SAVE=("$SITE_CUR" "$SHARED_DIR" "$APPS_DIR" "$SHARED_GROUP" "$SHARED_GID")
    SITE_CUR="$d"
    SHARED_DIR="${SITE_SHARED[$d]}"; APPS_DIR="${SITE_APPS[$d]}"
    SHARED_GROUP="${SITE_GROUP[$d]}"; SHARED_GID="${SITE_GID[$d]}"
}

site_leave() {
    (( ${#_SITE_SAVE[@]} == 5 )) || return 0
    SITE_CUR="${_SITE_SAVE[0]}"; SHARED_DIR="${_SITE_SAVE[1]}"; APPS_DIR="${_SITE_SAVE[2]}"
    SHARED_GROUP="${_SITE_SAVE[3]}"; SHARED_GID="${_SITE_SAVE[4]}"
    _SITE_SAVE=()
}

# Dossiers (SHARED puis apps) de tous les sites, un par ligne : pour les sauvegardes.
sites_data_dirs() {
    local d
    sites_load
    for d in "${SITE_LIST[@]}"; do
        printf '%s\n%s\n' "${SITE_SHARED[$d]}" "${SITE_APPS[$d]}"
    done
}

# « domaine|dossier apps » de tous les sites, séparés par des espaces (conf d'exécution : dump des bases, test de restauration).
sites_apps_list() {
    local d out=""
    sites_load
    for d in "${SITE_LIST[@]}"; do out+="${out:+ }${d}|${SITE_APPS[$d]}"; done
    printf '%s' "$out"
}

# ------------------------------------------------------------------ création des dossiers
# Dossiers d'applications d'un site SECONDAIRE selon ses services (le principal garde prepare_apps_data_dirs).
site_apps_dirs() {

    local s
    mkdir -p "$APPS_DIR" "${APPS_DIR}/backups"
    chown root:root "$APPS_DIR" "${APPS_DIR}/backups"
    chmod 0755 "$APPS_DIR"; chmod 0750 "${APPS_DIR}/backups"

    for s in ${SITE_SERVICES[$SITE_CUR]}; do
        case "$s" in
            immich)
                mkdir -p "${APPS_DIR}/immich"; chown root:root "${APPS_DIR}/immich"; chmod 0750 "${APPS_DIR}/immich" ;;
            nextcloud)
                mkdir -p "${APPS_DIR}/nextcloud"; chgrp "$SHARED_GROUP" "${APPS_DIR}/nextcloud"
                chmod 2770 "${APPS_DIR}/nextcloud"; chown 33:"$SHARED_GID" "${APPS_DIR}/nextcloud" ;;
            syncin)
                mkdir -p "${APPS_DIR}/syncin"; chgrp "$SHARED_GROUP" "${APPS_DIR}/syncin"; chmod 2770 "${APPS_DIR}/syncin" ;;
            mail)
                mkdir -p "${APPS_DIR}/mail"; chown 100000:100000 "${APPS_DIR}/mail"; chmod 0750 "${APPS_DIR}/mail" ;;
        esac
    done
}

site_tree_create() {

    local d="${1,,}"
    site_enter "$d"
    info "Site ${d} : dossiers dans ${SITE_ROOT[$d]} (groupe ${SHARED_GROUP}, GID ${SHARED_GID})..."
    mkdir -p "${SITE_ROOT[$d]}"
    chown root:root "${SITE_ROOT[$d]}"; chmod 0755 "${SITE_ROOT[$d]}"
    shared_tree_apply "$SHARED_DIR" "$SHARED_GROUP" "$SHARED_GID"
    site_apps_dirs
    site_leave
}

# Dossiers de tous les sites SECONDAIRES (le principal est créé par create_data_tree).
sites_tree_extra() {

    local d
    sites_load

    if [[ -d "${SITE_ROOT[$SITE_PRIMARY]}" ]]; then
        chown root:root "${SITE_ROOT[$SITE_PRIMARY]}"; chmod 0755 "${SITE_ROOT[$SITE_PRIMARY]}"
    fi

    for d in "${SITE_LIST[@]}"; do
        [[ "$d" == "$SITE_PRIMARY" ]] || site_tree_create "$d"
    done
}

# ------------------------------------------------------------------ commandes
#   ./install.sh --sites-status                         état des sites et de leurs dossiers
#   ./install.sh --site-add domaine.tld [svc1,svc2] [/racine]   déclare un site dans le fichier de réponses et crée ses dossiers
sites_status() {

    local d role root g
    sites_load
    echo "Sites (${#SITE_LIST[@]}) :"
    for d in "${SITE_LIST[@]}"; do
        role="secondaire"; [[ "$d" == "$SITE_PRIMARY" ]] && role="principal"
        root="${SITE_ROOT[$d]}"
        site_gid_resolve "$d"
        g="${SITE_GROUP[$d]}"
        echo
        echo "  ${d}  [${role}]"
        echo "    racine   : ${root}"
        echo "    SHARED   : ${SITE_SHARED[$d]}  $([[ -d "${SITE_SHARED[$d]}" ]] && echo '(présent)' || echo '(à créer)')"
        echo "    apps     : ${SITE_APPS[$d]}  $([[ -d "${SITE_APPS[$d]}" ]] && echo '(présent)' || echo '(à créer)')"
        echo "    services : ${SITE_SERVICES[$d]}"
        echo "    groupe   : ${g} (GID ${SITE_GID[$d]})"
    done
    echo
}

site_add() {

    local d="${1:-}" svc="${2:-samba}" root="${3:-}" s tmp sj
    local re_dom='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'

    d="${d,,}"
    [[ -n "$d" ]] || die "Usage : ./install.sh --site-add domaine.tld [service1,service2,...] [/racine]  (services : ${SITE_SERVICES_KNOWN})"
    [[ "$d" =~ $re_dom ]] || die "Nom de domaine invalide : ${d}"
    sites_load
    [[ "$d" != "$SITE_PRIMARY" && -z "${SITE_SHARED[$d]+x}" ]] || die "Le site ${d} est déjà déclaré."
    [[ -f "${ANSWERS_FILE:-}" ]] || die "Pas de fichier de réponses : crée-le d'abord (./install.sh --init-answers)."
    answers_require_jq || die "jq est requis."
    svc="${svc//,/ }"; svc="${svc,,}"
    for s in $svc; do
        [[ " $SITE_SERVICES_KNOWN " == *" $s "* ]] || die "Service inconnu « ${s} » (connus : ${SITE_SERVICES_KNOWN})."
    done
    [[ -z "$root" || ( "$root" == /* && "$root" != *..* ) ]] || die "La racine doit être un chemin absolu : ${root}"

    sj="$(printf '%s\n' $svc | jq -R . | jq -s .)"
    tmp="$(mktemp)"
    jq --arg d "$d" --arg r "$root" --argjson s "$sj" \
        '.sites = ((.sites // {}) + {($d): ({services: $s} + (if $r != "" then {racine: $r} else {} end))})' \
        "$ANSWERS_FILE" > "$tmp" || { rm -f "$tmp"; die "Mise à jour du fichier de réponses impossible."; }
    cp -a "$ANSWERS_FILE" "${ANSWERS_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    install -m 600 "$tmp" "$ANSWERS_FILE"
    rm -f "$tmp"
    info "Site ${d} ajouté à ${ANSWERS_FILE} (services : ${svc})."

    SITES_LOADED=false
    sites_load
    validate_sites
    if [[ "$(id -u)" == "0" ]]; then
        site_tree_create "$d"
        info "Site ${d} : dossiers créés. Les services du site (SWAG, DNS, applications) arrivent avec les phases suivantes."
    else
        info "Lance la commande en root pour créer les dossiers, ou relance ./install.sh."
    fi
}

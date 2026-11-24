###############################################################################
#                  SOUS-DOMAINES DES SERVICES (UN OU PLUSIEURS NOMS)            #
###############################################################################

# Chaque service exposé par SWAG a une variable *_SUBDOMAIN qui accepte UN OU PLUSIEURS noms séparés par
# des espaces (ou des virgules) : IMMICH_SUBDOMAIN="photos photo".
#   - le PREMIER nom est le nom principal (liens, configuration interne : Nextcloud, Collabora, MX du mail...) ;
#   - tous les noms reçoivent un enregistrement DNS, figurent dans le certificat Let's Encrypt et dans le
#     server_name nginx de SWAG.
# Après normalisation, la variable d'origine ne contient plus que le nom principal (le reste du code
# n'a donc pas changé) ; la liste complète est dans SUBDOMAIN_ALL[<variable>].

SUBDOMAIN_VARS="NEXTCLOUD_SUBDOMAIN SYNCIN_SUBDOMAIN IMMICH_SUBDOMAIN JELLYFIN_SUBDOMAIN COLLABORA_SUBDOMAIN ONLYOFFICE_SUBDOMAIN MAIL_SUBDOMAIN NODE_SUBDOMAIN NTFY_SUBDOMAIN HOMEPAGE_SUBDOMAIN PORTAL_SUBDOMAIN"
declare -gA SUBDOMAIN_ALL=()      # variable -> "nom1 nom2 ..."
declare -gA SUBDOMAIN_RAW=()      # variable -> valeur saisie (pour le fichier de réponses généré)
SUBDOMAINS_NORMALIZED=false

normalize_subdomains() {

    [[ "$SUBDOMAINS_NORMALIZED" != "true" ]] || return 0

    local v raw
    local -a names

    for v in $SUBDOMAIN_VARS; do
        raw="${!v-}"
        SUBDOMAIN_RAW["$v"]="$raw"
        raw="${raw//,/ }"
        read -r -a names <<< "${raw,,}"
        SUBDOMAIN_ALL["$v"]="${names[*]:-}"
        printf -v "$v" '%s' "${names[0]:-}"
    done

    SUBDOMAINS_NORMALIZED=true
}

# Noms (un par ligne) d'une variable de sous-domaine.
sd_all() {
    local n
    for n in ${SUBDOMAIN_ALL[$1]:-}; do printf '%s\n' "$n"; done
}

# Noms complets séparés par des espaces : cloud.exemple.fr alias.exemple.fr
sd_fqdns() {
    local n out=""
    for n in ${SUBDOMAIN_ALL[$1]:-}; do out+="${out:+ }${n}.${DOMAIN}"; done
    printf '%s' "$out"
}

# Noms (relatifs à DOMAIN) servis par SWAG pour les services ACTIFS : certificat, DNS, zone.
# $1 = "zone" ajoute les noms publiés dans la zone DNS sans être dans le certificat (Homepage).
subdomain_hosts() {

    local mode="${1:-cert}"

    [[ "${ENABLE_PORTAL:-false}" == "true" ]]    && sd_all PORTAL_SUBDOMAIN
    sd_all NEXTCLOUD_SUBDOMAIN
    sd_all SYNCIN_SUBDOMAIN
    sd_all IMMICH_SUBDOMAIN
    [[ "${ENABLE_JELLYFIN:-false}" == "true" ]]   && sd_all JELLYFIN_SUBDOMAIN
    [[ "${ENABLE_COLLABORA:-false}" == "true" ]]  && sd_all COLLABORA_SUBDOMAIN
    [[ "${ENABLE_ONLYOFFICE:-false}" == "true" ]] && sd_all ONLYOFFICE_SUBDOMAIN
    [[ "${ENABLE_MAIL:-false}" == "true" ]]       && sd_all MAIL_SUBDOMAIN
    [[ "${ENABLE_NODE:-false}" == "true" ]]       && sd_all NODE_SUBDOMAIN
    [[ "${ENABLE_MONITOR:-false}" == "true" && "${MONITOR_NTFY:-false}" == "true" ]] && sd_all NTFY_SUBDOMAIN
    if [[ "$mode" == "zone" && "${ENABLE_MONITOR:-false}" == "true" ]]; then
        sd_all HOMEPAGE_SUBDOMAIN
    fi
    return 0
}

# Même liste, séparée par des virgules (variable SUBDOMAINS de SWAG).
subdomain_hosts_csv() {
    subdomain_hosts cert | awk '!s[$0]++' | paste -sd, -
}

# Refuse un nom invalide ou utilisé par deux services (nginx et le certificat ne s'en sortiraient pas).
validate_subdomains() {

    local v n owner
    local -A used=()

    for v in $SUBDOMAIN_VARS; do
        for n in ${SUBDOMAIN_ALL[$v]:-}; do
            [[ "$n" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
                || die "${v} : « ${n} » n'est pas un sous-domaine valide (lettres minuscules, chiffres et tirets ; un seul niveau, sans point)."
            owner="${used[$n]:-}"
            if [[ -n "$owner" && "$owner" != "$v" ]]; then
                die "Le sous-domaine « ${n} » est utilisé par deux services (${owner} et ${v}) : chaque nom ne peut servir qu'à un service."
            fi
            used["$n"]="$v"
        done
    done

    [[ -n "${SUBDOMAIN_ALL[NEXTCLOUD_SUBDOMAIN]:-}" && -n "${SUBDOMAIN_ALL[SYNCIN_SUBDOMAIN]:-}" && -n "${SUBDOMAIN_ALL[IMMICH_SUBDOMAIN]:-}" ]] \
        || die "NEXTCLOUD_SUBDOMAIN, SYNCIN_SUBDOMAIN et IMMICH_SUBDOMAIN ne peuvent pas être vides."
    return 0
}

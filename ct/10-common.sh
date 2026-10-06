###############################################################################
#                              LXC TEMPLATE                                   #
###############################################################################

# Résultat renvoyé via la variable globale DOWNLOADED_TEMPLATE, jamais
# via un $(...) : "pveam download" imprime lui-même une barre de
# progression sur stdout (indépendamment de nos logs), qui contaminerait
# la valeur capturée par un appelant utilisant $(download_debian_lxc_template).
# Déjà vu une fois avec nos propres logs (corrigé en redirigeant
# log()/info()/warn() vers stderr) ; pveam download prouve qu'on ne peut
# pas garantir qu'aucune commande externe n'écrira jamais sur stdout à
# l'intérieur de cette fonction - donc on arrête complètement d'en
# dépendre pour transmettre le résultat.
DOWNLOADED_TEMPLATE=""

download_debian_lxc_template() {

    local template

    # Filtre explicitement amd64 : pveam available peut lister plusieurs
    # architectures pour le même Debian 13 (ex: variante arm64), et un
    # simple "sort -V | tail -n1" sans filtre d'archi peut sélectionner
    # arm64 par accident (il se trie alphabétiquement après amd64), ce
    # qui casse le démarrage du CT avec "Exec format error" sur un hôte
    # x86_64.
    template="$(
        pveam available --section system |
            awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' |
            sort -V |
            tail -n 1
    )"

    [[ -n "$template" ]] \
        || die "Impossible de trouver un template Debian 13 amd64."

    if ! pveam list local |
        awk '{print $1}' |
        grep -qx "local:vztmpl/${template}"; then

        info "Téléchargement du template ${template}..."

        # >&2 : la barre de progression de pveam va sur stderr, jamais
        # sur stdout (aucun appelant ne capture cette fonction via un
        # $(...) désormais, mais autant rester prudent).
        pveam download local "$template" >&2
    fi

    DOWNLOADED_TEMPLATE="local:vztmpl/${template}"
}

###############################################################################
#                              LXC SCRIPT PUSH                                #
###############################################################################

pct_wait_for_network() {

    local VMID="$1"

    for _ in {1..30}; do

        if pct exec "$VMID" -- \
            ping -c 1 -W 1 10.10.10.1 >/dev/null 2>&1; then

            return 0
        fi

        sleep 2
    done

    die "Le CT ${VMID} ne parvient pas à joindre ${PRIVATE_GW}."
}

pct_push_script() {

    local VMID="$1"
    local LOCAL_SCRIPT="$2"
    local REMOTE_SCRIPT="$3"

    pct push \
        "$VMID" \
        "$LOCAL_SCRIPT" \
        "$REMOTE_SCRIPT"

    pct exec "$VMID" -- \
        chmod 700 "$REMOTE_SCRIPT"
}


###############################################################################
#                                  LOGGING                                    #
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    # >&2 : les logs ne doivent jamais atterrir sur stdout, sous peine de
    # se retrouver mélangés dans la valeur capturée par un $(...) partout
    # où une fonction appelant info()/warn() est utilisée en command
    # substitution (ex: TEMPLATE="$(download_debian_lxc_template)"). Le
    # "2>&1" en tête de script fusionne de toute façon stderr dans le
    # même flux tee (terminal + fichier de log), donc rien n'est perdu.
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

info() {
    log "INFO: $*"
}

warn() {
    log "WARN: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Marqueur de début de run, bien visible et greppable (le log cumule
# tous les essais depuis le tout premier lancement - sans ça, impossible
# de savoir à quelle tentative appartient telle ou telle erreur).
# Cherche "DEBUT proxmox-homelab-install" pour lister tous les runs.
log "=========================================================="
log "DEBUT proxmox-homelab-install.sh version ${SCRIPT_VERSION}"
log "=========================================================="

trap 'die "Erreur ligne ${LINENO}: ${BASH_COMMAND}"' ERR

###############################################################################
#                              BASIC CHECKS                                   #
###############################################################################

check_root() {
    [[ "$(id -u)" -eq 0 ]] \
        || die "Le script doit être exécuté en root."
}

check_proxmox() {

    command -v pveversion >/dev/null 2>&1 \
        || die "Ce script doit être exécuté sur un hôte Proxmox VE."

    command -v qm >/dev/null 2>&1 \
        || die "Commande qm introuvable."

    command -v pct >/dev/null 2>&1 \
        || die "Commande pct introuvable."

    command -v pvesh >/dev/null 2>&1 \
        || die "Commande pvesh introuvable."

    NODE_NAME="$(hostname -s)"

    pvesh get "/nodes/${NODE_NAME}/status" \
        --output-format json >/dev/null \
        || die "Le nœud Proxmox ${NODE_NAME} n'est pas accessible via l'API."
}


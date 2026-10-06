#!/usr/bin/env bash

###############################################################################
#                                                                             #
#                 PROXMOX HOMELAB INSTALLER                                  #
#                 (version : voir SCRIPT_VERSION ci-dessous)                 #
#                                                                             #
# Debian 13 / Proxmox VE 9.x                                                  #
#                                                                             #
# Architecture :                                                             #
#   vmbr0  -> LAN 192.168.1.0/24                                             #
#   vmbr1  -> réseau privé 10.10.10.0/24                                     #
#                                                                             #
#   CT 101  SWAG       10.10.10.16                                           #
#   VM 103  DOCKER     10.10.10.103                                          #
#   VM 104  FILES      10.10.10.104                                          #
#   CT 105  XMRIG      10.10.10.105                                          #
#                                                                             #
###############################################################################

set -Eeuo pipefail

# Installation non interactive pour APT (évite un blocage debconf,
# notamment sur iptables-persistent).
export DEBIAN_FRONTEND=noninteractive

###############################################################################
#                              CONFIGURATION                                  #
###############################################################################

SCRIPT_VERSION="2.26.2"

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------

ENABLE_SWAG=true
ENABLE_DOCKER=true
ENABLE_FILES=true
ENABLE_XMRIG=true

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------

NODE_NAME="$(hostname -s)"

LAN_BRIDGE="vmbr0"
PRIVATE_BRIDGE="vmbr1"

# Détectée automatiquement depuis l'IP réellement active sur LAN_BRIDGE
# (DHCP ou statique, peu importe) plutôt que supposée fixe à l'avance -
# pratique si l'IP est gérée par réservation DHCP sur la box plutôt que
# configurée en dur dans /etc/network/interfaces. Peut être forcée en la
# définissant explicitement dans le fichier de réponses si besoin.
detect_lan_ip() {
    ip -4 addr show "${LAN_BRIDGE:-vmbr0}" 2>/dev/null |
        awk '/inet /{print $2}' |
        cut -d/ -f1 |
        head -n1
}

LAN_IP="$(detect_lan_ip)"

if [[ -z "$LAN_IP" ]]; then
    LAN_IP="192.168.1.4"
    echo "AVERTISSEMENT: impossible de détecter l'IP de vmbr0, valeur de repli utilisée : ${LAN_IP} (à corriger dans le fichier de réponses si besoin)." >&2
fi

LAN_NET="192.168.1.0/24"
LAN_GW="192.168.1.1"

# État réseau cible pour vmbr0, lu depuis le fichier de réponses :
# "DHCP" (insensible à la casse) ou une adresse IP fixe à appliquer.
# Vide = pas de valeur fournie, le script demandera interactivement.
# Appliqué uniquement si différent de l'état actuel (sinon rien ne change).
# ATTENTION : si l'IP qui en résulte diffère de l'IP statique actuelle,
# toute connexion SSH/web en cours sur l'ancienne IP sera coupée net au
# moment du changement - lancer le script depuis la console Proxmox ou
# dans un tmux/screen dans ce cas.
HOST_IP=""

PRIVATE_GW="10.10.10.1"
PRIVATE_NET="10.10.10.0/24"

# ---------------------------------------------------------------------------
# VM / CT IDs
# ---------------------------------------------------------------------------

SWAG_ID="101"
DOCKER_ID="103"
FILES_ID="104"
XMRIG_ID="105"

# ---------------------------------------------------------------------------
# DATA
# ---------------------------------------------------------------------------

DATA_DISK="/dev/sdb"
DATA_PARTITION="/dev/sdb1"

DATA_MOUNT="/mnt/data"
SHARED_DIR="${DATA_MOUNT}/SHARED"
PROXMOX_DATA_DIR="${DATA_MOUNT}/proxmox"

SHARED_GROUP="fileshare"
SHARED_GID="2000"

VIRTIOFS_DIR_ID="files_shared"

# ---------------------------------------------------------------------------
# FILES VM
# ---------------------------------------------------------------------------

FILES_HOSTNAME="files"
FILES_IP="10.10.10.104/24"
FILES_GATEWAY="10.10.10.1"

FILES_CORES="2"
FILES_MEMORY="2048"
FILES_DISK="32G"

FILES_MOUNT="/srv/data"
FILES_SAMBA_SHARE="SHARED"

# ---------------------------------------------------------------------------
# DOCKER VM
# ---------------------------------------------------------------------------

DOCKER_HOSTNAME="docker"
DOCKER_IP="10.10.10.103/24"
DOCKER_GATEWAY="10.10.10.1"

DOCKER_CORES="2"
DOCKER_MEMORY="4096"
DOCKER_DISK="32G"

# Partage VirtioFS monté aussi sur la VM DOCKER (même dirid que FILES),
# pour donner aux applis un accès direct à SHARED sans passer par un
# ré-export réseau (NFS/Samba) depuis la VM FILES. Les conteneurs utilisent
# le GID ${SHARED_GID} via group_add pour respecter les permissions du partage.
DOCKER_SHARED_MOUNT="/srv/data"

# ---------------------------------------------------------------------------
# DOCKER APPS - Nextcloud / Sync-in / Immich / Home Assistant / Jellyfin
# ---------------------------------------------------------------------------

ENABLE_NEXTCLOUD=true
ENABLE_SYNCIN=true
ENABLE_IMMICH=true
ENABLE_HOMEASSISTANT=true
ENABLE_JELLYFIN=true

DOCKER_APPS_UID="1000"
DOCKER_APPS_GID="${SHARED_GID}"

NEXTCLOUD_HTTP_PORT="8081"
NEXTCLOUD_ADMIN_USER="admin"
NEXTCLOUD_ADMIN_PASSWORD=""
NEXTCLOUD_DB_PASSWORD=""

SYNCIN_HTTP_PORT="6060"
SYNCIN_ADMIN_LOGIN="admin"
SYNCIN_ADMIN_PASSWORD=""
SYNCIN_DB_PASSWORD=""
SYNCIN_DB_ROOT_PASSWORD=""
SYNCIN_SECRET_1=""
SYNCIN_SECRET_2=""
SYNCIN_SECRET_3=""
SYNCIN_SECRET_4=""

IMMICH_HTTP_PORT="2283"
IMMICH_DB_PASSWORD=""

HOMEASSISTANT_HTTP_PORT="8123"
JELLYFIN_HTTP_PORT="8096"

# ---------------------------------------------------------------------------
# SWAG
# ---------------------------------------------------------------------------

SWAG_HOSTNAME="swag"
SWAG_IP="10.10.10.16/24"
SWAG_GATEWAY="10.10.10.1"

DOMAIN="ipassed.fr"
LE_EMAIL=""

SWAG_CORES="1"
SWAG_MEMORY="512"
SWAG_DISK="8G"

# ---------------------------------------------------------------------------
# XMRig
# ---------------------------------------------------------------------------

XMRIG_HOSTNAME="xmrig"
XMRIG_IP="10.10.10.105/24"
XMRIG_GATEWAY="10.10.10.1"

# nproc-1 : laisse toujours un cœur de marge à l'hyperviseur et aux
# autres VM/CT, quel que soit le nombre de cœurs physiques de l'hôte.
# Note : sur la plupart des CPU, XMRig plafonne de toute façon le
# nombre de threads RandomX réellement utilisés selon la taille du
# cache L3 (environ L3 ÷ 2 Mo), donc ce nombre est surtout une marge de
# sécurité, pas une garantie que XMRig utilisera tous ces cœurs.
XMRIG_CORES="$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))"
XMRIG_MEMORY="4096"
XMRIG_DISK="8G"

XMRIG_VERSION="6.26.0"
XMRIG_ARCHIVE="xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz"
XMRIG_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/${XMRIG_ARCHIVE}"
XMRIG_SHA256SUMS_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/SHA256SUMS"

# Hash de secours, utilisé uniquement si le téléchargement de SHA256SUMS
# échoue (réseau restreint, GitHub indisponible, etc). Le script tente
# TOUJOURS de récupérer et vérifier le hash officiel en priorité.
XMRIG_SHA256_FALLBACK="fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5"

XMRIG_POOL="xmrpool.eu:5555"
XMRIG_WALLET=""

# CPU monitor
XMRIG_STOP_THRESHOLD="25"
XMRIG_RESUME_THRESHOLD="20"
XMRIG_RESUME_DELAY="300"
XMRIG_MONITOR_INTERVAL="5"

# HugePages
HUGEPAGES_COUNT="1280"
HUGEPAGES_MOUNT="/mnt/huge"

# ---------------------------------------------------------------------------
# Debian cloud image
# ---------------------------------------------------------------------------

DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"

DEBIAN_IMAGE_DIR="/var/lib/vz/template/iso"
DEBIAN_IMAGE="${DEBIAN_IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2"

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

LOG_FILE="/var/log/proxmox-homelab-install-${SCRIPT_VERSION}.log"

###############################################################################
#                         HOST PACKAGE REQUIREMENTS                           #
###############################################################################

# IMPORTANT :
# qemu-utils NE DOIT PAS être installé explicitement sur un hôte PVE.
# Sur PVE 9, cela peut provoquer une résolution APT voulant supprimer
# le stack QEMU/Proxmox.
#
# Les dépendances réellement manquantes sont détectées avant installation.
# Une simulation APT est ensuite effectuée et toute suppression d'un paquet
# Proxmox critique provoque l'arrêt immédiat du script.

HOST_PACKAGES=(
    ca-certificates
    curl
    wget
    git
    jq
    unzip
    rsync
    gnupg
    openssl
    acl
    attr
    util-linux
    psmisc
    procps
    parted
    e2fsprogs
    iptables
    iptables-persistent
    cloud-init
    virtiofsd
    ifupdown2
    fail2ban
)

###############################################################################
#                              GLOBAL VARIABLES                               #
###############################################################################

ROOT_PASSWORD=""
SAMBA_PASSWORD=""
ROOT_PASSWORD_HASH=""
SAMBA_PASSWORD_B64=""

# Fichier de réponses optionnel (voir load_answers_file()). Premier
# argument du script, sinon un fichier par défaut à côté du script s'il
# existe.
ANSWERS_FILE="${1:-./proxmox-homelab-answers.conf}"
ANSWERS_FILE_LOADED=false

# Confirmation de formatage du disque DATA, lisible depuis ANSWERS_FILE.
FORMAT_CONFIRMATION=""

# Suppression préalable des VM/CT homelab déjà existantes (voir
# propose_cleanup_existing()). "" = demande interactive, "oui"/"true" =
# supprime sans demander, toute autre valeur (ou vide en mode fichier) =
# conserve sans demander.
CLEANUP_EXISTING_VMS=""


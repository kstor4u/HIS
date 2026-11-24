#!/usr/bin/env bash

###############################################################################
#                                                                             #
#                 PROXMOX HOMELAB INSTALLER                                  #
#                 (version : voir SCRIPT_VERSION ci-dessous)                 #
#                                                                             #
# Debian 13 / Proxmox VE 9.x                                                  #
#                                                                             #
# Architecture :                                                              #
#   vmbr0  -> LAN 192.168.1.0/24                                              #
#   vmbr1  -> réseau privé 10.10.10.0/24                                      #
#                                                                             #
#   CT 101  SWAG       10.10.10.16   reverse proxy HTTPS (Let's Encrypt)      #
#   VM 103  DOCKER     10.10.10.103  Nextcloud, Sync-in, Immich, HA, Jellyfin #
#                                    (+ Collabora / OnlyOffice en option)     #
#   VM 104  FILES      10.10.10.104  Samba / Webmin                           #
#   CT 105  XMRIG      10.10.10.105  mineur Monero (option)                   #
#   CT 106  WIREGUARD  10.10.10.106  VPN (option)                             #
#   CT 107  NODE       10.10.10.107  Node.js + MongoDB (option)               #
#   CT 108  MAIL       10.10.10.108  serveur mail autonome (option)           #
#   CT 109  DNS        10.10.10.109  DNS filtrant AdGuard Home (option)         #
#   CT 110  MONITOR    10.10.10.110  Uptime Kuma + ntfy + Homepage (option)      #
#   (option) Sonarr/Radarr/Prowlarr/qBittorrent : dans la VM DOCKER               #
#   (option) CrowdSec : dans le CT SWAG                                         #
#                                                                             #
#   Disque DATA : SHARED (Samba) + apps/ (données d'applications, hors Samba) #
#                                                                             #
#   OPTIONS DU SCRIPT (./install.sh --help pour le détail et la liste des fonctions --run)
#     ./install.sh [fichier]               installe ; sans fichier de réponses : questions, puis fichier généré
#     ./install.sh --init-answers [f]      crée le fichier de réponses JSON + proxmox-homelab-variables.md et S'ARRÊTE (à compléter)
#     ./install.sh --update-answers [f]    met à jour un fichier existant (tes valeurs conservées, nouveautés à null et listées
#                                          dans « _nouveau », ancien fichier en .bak)
#     ./install.sh --describe [VARIABLE]   décrit une variable du fichier de réponses (ou toutes, sans argument)
#     ./install.sh --skip-answers-check    installe sans s'arrêter pour les variables nouvelles
#     ./install.sh --run <fonction> [...]  exécute UNE fonction : réparation, gestion, test (--list-commands)
#     ./install.sh --help | --version
#     Variables d'environnement : ANSWERS_CHECK=false  ANSWERS_SAVE=false
#                                                                             #
###############################################################################

set -Eeuo pipefail

# Installation non interactive pour APT (évite un blocage debconf,
# notamment sur iptables-persistent).
export DEBIAN_FRONTEND=noninteractive

###############################################################################
#                              CONFIGURATION                                  #
###############################################################################

# Locale : les CT Debian n'ont pas la locale (ex. en_US.UTF-8) de la session SSH de l'hôte, que pct exec leur transmet :
# apt/perl affichent alors "Can't set locale". C.UTF-8 existe partout (hôte, CT, VM) : on l'impose au script.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset LANGUAGE LC_CTYPE LC_MESSAGES LC_COLLATE LC_TIME LC_NUMERIC LC_MONETARY 2>/dev/null || true

SCRIPT_VERSION="2.61.0"

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------

# Un seul réglage par service (lisible aussi depuis le fichier de réponses) :
#   "keep"    = installe si absent ; conserve s'il existe déjà (création sautée)
#   "run"     = existe déjà : applique SEULEMENT les paramètres (rien créé, supprimé, téléchargé ni installé ;
#               absent = installé comme keep). Si tous les services actifs sont en run, l'installation de
#               l'hôte (dépôts, paquets, réseau, stockage, images) est aussi sautée : lancement court.
#   "cleanup" = supprime l'existant PUIS le recrée à neuf
#   "remove"  = supprime l'existant et ne l'installe pas
#   ""        = installe si absent ; s'il existe déjà, DEMANDE quoi faire
#   "skip"    = ne touche à rien et n'installe pas (même si le CT/la VM existe)
# Alias : "true" = keep, "false" = remove. Le disque DATA n'est jamais touché.
# Après resolve_service_modes(), ces variables valent toujours "true" ou "false".
ENABLE_SWAG=""
ENABLE_DOCKER=""
ENABLE_FILES=""
ENABLE_XMRIG=""
ENABLE_WIREGUARD=""
# NODE (CT Node.js + MongoDB) : "skip" par défaut = ni installé ni touché. Mets
# "keep" pour l'installer ("skip" = ne rien faire, aussi pour un CT existant).
ENABLE_NODE="skip"
# MAIL (CT serveur mail autonome) : "skip" par défaut, comme NODE. "keep" pour l'installer.
ENABLE_MAIL="skip"
# DNS (CT AdGuard Home : bloqueur de publicités/traqueurs + DNS interne) : "skip" par défaut.
ENABLE_DNS="skip"
# MONITOR (CT Uptime Kuma + ntfy + Homepage) : "skip" par défaut.
ENABLE_MONITOR="skip"
# AI (CT Ollama + Open WebUI + OCR, GPU NVIDIA de l'hôte) : "skip" par défaut. Voir ct/65-ai.sh.
ENABLE_AI="skip"

# Masque la fenêtre "No valid subscription" de l'interface web Proxmox.
# Purement local à l'interface (proxmoxlib.js) ; annulable : apt reinstall proxmox-widget-toolkit
DISABLE_SUBSCRIPTION_NAG=true

# Sauvegarde des certificats Let's Encrypt de SWAG (clés privées : fichier root 0600).
# Évite de redemander un certificat à chaque réinstallation (limite : 5 certificats
# identiques par semaine). Voir swag_backup_certs / swag_restore_certs.
SWAG_CERT_BACKUP="/var/lib/homelab/swag-letsencrypt.tgz"

# ---------------------------------------------------------------------------
# Sauvegardes (voir host/50-backup.sh)
# ---------------------------------------------------------------------------

# true = crée la tâche Proxmox planifiée (vzdump) de toutes les VM/CT installés.
ENABLE_BACKUP=false
BACKUP_STORAGE="DATA"                     # storage Proxmox de destination (même disque que les données !)
BACKUP_SCHEDULE="01:00"                   # tous les jours à 1h (terminé avant le tirage du serveur de sauvegarde, 3h) ; ex. "sun 01:00"
BACKUP_MODE="snapshot"                    # snapshot | suspend | stop (stop = arrêt bref de la VM/CT)
BACKUP_COMPRESS="zstd"
BACKUP_KEEP="keep-daily=7,keep-weekly=4,keep-monthly=3"   # rotation

# Copie HORS SITE chiffrée (restic), vide = désactivée. Exemples de dépôt :
#   sftp:utilisateur@10.10.20.5:/sauvegardes/homelab     (autre serveur, ex. via le VPN WireGuard)
#   s3:s3.fr-par.scw.cloud/mon-bucket/homelab            (stockage objet ; variables AWS_* à ajouter au script)
BACKUP_RESTIC_REPO=""
BACKUP_RESTIC_PASSWORD=""                 # OBLIGATOIRE si le dépôt est défini ; à conserver ailleurs
BACKUP_OFFSITE_PATHS=""                   # vide = sauvegardes vzdump + données d'applications + SHARED
BACKUP_OFFSITE_CRON="30 4 * * *"          # tous les jours à 4h30
BACKUP_OFFSITE_KEEP="--keep-daily 7 --keep-weekly 4 --keep-monthly 6"

# Accès en LECTURE SEULE pour un serveur de sauvegarde qui vient chercher les données
# (tirage ; voir le dossier backup-server/). Le serveur de sauvegarde garde l'initiative :
# ici on autorise seulement sa clé publique, limitée à rrsync -ro sur DATA_MOUNT.
ENABLE_BACKUP_PULL=false
BACKUP_PULL_USER="backup-pull"            # compte système dédié créé pour le tirage (sans mot de passe, sans root)
BACKUP_PULL_PUBKEY=""                     # contenu de /root/.ssh/homelab-pull.pub du serveur de sauvegarde
BACKUP_PULL_FROM=""                       # vide = toute IP (IP publique non fixe) ; sinon IP/plage autorisée. La clé reste en lecture seule.
BACKUP_CANARY=true                        # crée des fichiers témoins (docx/jpg/avi) surveillés par le serveur de sauvegarde

# Export vers un disque USB : brancher un disque portant un fichier marqueur copie la dernière sauvegarde
# du serveur dessus (voir host/55-usb-export.sh). Un disque sans ce fichier n'est jamais touché.
ENABLE_BACKUP_USB=false
BACKUP_USB_MARKER="HOMELAB-BACKUP"        # fichier à créer à la racine du disque
BACKUP_USB_CONTENT="dump apps"            # dump (vzdump) | apps (dossiers d'applications) | shared (partage SAMBA) ; modifiable dans le marqueur
BACKUP_USB_KEEP=2                         # exports conservés sur le disque
BACKUP_USB_WEBHOOK=""                     # URL ntfy facultative pour être prévenu (sinon : journal + message console)
BACKUP_USB_ALLOWED_UUIDS=""               # UUID de disques autorisés (vide = tout disque USB portant le marqueur)

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------

# Stockage Proxmox où sont créés les DISQUES des VM et des CT (disque système des invités).
#   local-lvm (défaut) = disque système de l'hôte (LVM-thin) : rapide, instantanés disponibles.
#   DATA               = disque de données (créé par le script) : épargne le disque système, mais les écritures
#                        des bases et de Docker vont alors sur DATA (lent si c'est un disque dur).
#   autre              = tout stockage Proxmox existant acceptant « images » et « rootdir ».
# Ne s'applique qu'aux VM/CT CRÉÉS : un invité existant n'est pas déplacé (qm move-disk / pct move-volume).
# Les CT sur un stockage « dir » (DATA) n'ont pas d'instantané : vzdump les sauvegarde en mode « suspend » (arrêt bref).
GUEST_STORAGE="local-lvm"

NODE_NAME="$(hostname -s)"

# Nom d'hôte voulu pour le serveur Proxmox (vide = inchangé). Appliqué en tout premier ;
# le script s'arrête ensuite pour que tu redémarres. Refusé s'il existe déjà des VM/CT. Voir host/05-hostname.sh
HOST_NAME=""

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

# Données d'applications HORS du partage Samba/SHARED : tout ce qui est géré par
# une application avec sa base (Immich, serveur mail...) vit ici, jamais visible
# par Samba, Nextcloud ou Sync-in. Partagé avec la VM DOCKER par un 2e VirtioFS ;
# le CT MAIL y accède par un point de montage LXC.
APPS_DIR="${DATA_MOUNT}/apps"
APPS_VIRTIOFS_DIR_ID="apps_data"

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
DOCKER_MEMORY="8192"   # Mo. 4096 ne suffit PAS pour Nextcloud+Immich+Sync-in+Jellyfin+HA : la VM gèle (manque de mémoire).
DOCKER_DISK="64G"

# Partage VirtioFS monté aussi sur la VM DOCKER (même dirid que FILES),
# pour donner aux applis un accès direct à SHARED sans passer par un
# ré-export réseau (NFS/Samba) depuis la VM FILES. Les conteneurs utilisent
# le GID ${SHARED_GID} via group_add pour respecter les permissions du partage.
DOCKER_SHARED_MOUNT="/srv/data"

# Montage du 2e VirtioFS (APPS_DIR) dans la VM DOCKER : données d'Immich.
DOCKER_APPS_MOUNT="/srv/apps"

# Emplacements des DONNÉES des applications. Restent volontairement en local
# dans la VM : bases de données (Postgres/MariaDB/SQLite), caches, configurations.
# Tout est HORS SHARED (voir APPS_DIR), donc jamais exposé par Samba :
#   ${APPS_DIR}/immich     photos importées, miniatures, vidéos encodées
#   ${APPS_DIR}/nextcloud  fichiers créés dans Nextcloud (hors stockages externes), versions, corbeille
#   ${APPS_DIR}/syncin     espaces personnels/communs de Sync-in, temporaire
#   ${APPS_DIR}/mail       boîtes mail (CT MAIL)
#   ${APPS_DIR}/backups    sauvegardes (ex. MongoDB)

# ---------------------------------------------------------------------------
# DOCKER APPS - Nextcloud / Sync-in / Immich / Home Assistant / Jellyfin
# ---------------------------------------------------------------------------

ENABLE_NEXTCLOUD=true
ENABLE_SYNCIN=true
ENABLE_IMMICH=true
ENABLE_HOMEASSISTANT=true
ENABLE_JELLYFIN=true

# Édition de documents dans Nextcloud (tableurs, textes, présentations). Nécessite
# ENABLE_NEXTCLOUD=true, SWAG et un enregistrement DNS A par sous-domaine.
# Les deux peuvent être installés pour comparer : ./install.sh --run nextcloud_office_use
# collabora|onlyoffice choisit l'éditeur actif. OnlyOffice demande ~4 Go de RAM de plus
# (augmenter DOCKER_MEMORY, ex. "8192").
ENABLE_COLLABORA=false
ENABLE_ONLYOFFICE=false
COLLABORA_HTTP_PORT="9980"
ONLYOFFICE_HTTP_PORT="8082"
COLLABORA_SUBDOMAIN="office"          # https://office.<domaine> (plusieurs noms possibles, séparés par des espaces)
ONLYOFFICE_SUBDOMAIN="onlyoffice"     # https://onlyoffice.<domaine>
COLLABORA_DICTIONARIES="fr_FR en_GB"  # dictionnaires du correcteur orthographique
ONLYOFFICE_JWT_SECRET=""              # vide = généré
# Sync-in utilise le serveur OnlyOffice ci-dessus (ENABLE_ONLYOFFICE=true requis) pour éditer les documents.
SYNCIN_ONLYOFFICE=false
# Idem avec Collabora (ENABLE_COLLABORA=true requis). Les deux peuvent être activés ensemble.
SYNCIN_COLLABORA=false

DOCKER_APPS_UID="1000"
DOCKER_APPS_GID="${SHARED_GID}"

# Sous-domaines des services (https://<nom>.<domaine>). UN OU PLUSIEURS noms séparés par des espaces : le
# premier est le nom principal ; tous ont leur enregistrement DNS, figurent dans le certificat Let's Encrypt
# et sont servis par SWAG. Un nom ne peut servir qu'à un seul service. Autres : COLLABORA_/ONLYOFFICE_/MAIL_/
# NODE_/NTFY_/HOMEPAGE_SUBDOMAIN (mêmes règles). Appliquer à une installation existante : ./install.sh --run repair_swag_subdomains
NEXTCLOUD_SUBDOMAIN="cloud"
SYNCIN_SUBDOMAIN="sync"
IMMICH_SUBDOMAIN="photos photo"
JELLYFIN_SUBDOMAIN="media"

# Portail : page d'accueil unique https://<PORTAIL>.<domaine> avec un lien vers chaque service installé (ct/25-portal.sh).
# Vue Internet = services exposés par SWAG ; vue réseau local/VPN = + liens d'administration (Proxmox, Kuma, AdGuard...).
# Secours sans DNS : http://<IP LAN hôte>:PORTAL_LOCAL_PORT. Mettre à jour après ajout d'un service : ./install.sh --run portal_apply
ENABLE_PORTAL=true
PORTAL_SUBDOMAIN="home"
PORTAL_TITLE="Mon serveur"
PORTAL_AUTH="public"        # public = mot de passe seulement depuis Internet | all = partout | none = jamais
PORTAL_USER="admin"
PORTAL_PASSWORD=""          # vide = généré et affiché dans le résumé
PORTAL_LOCAL_PORT="8088"    # accès http://<IP LAN hôte>:8088 (LAN uniquement, ne pas rediriger depuis la box)

NEXTCLOUD_HTTP_PORT="8081"
NEXTCLOUD_ADMIN_USER="admin"
NEXTCLOUD_ADMIN_PASSWORD=""
NEXTCLOUD_DB_PASSWORD=""
NEXTCLOUD_OPTIMIZE="true"            # Redis, cron, réglages PHP/occ (override Docker)
NEXTCLOUD_IMAGE_TAG=""               # vide = version majeure en cours (jamais "stable")
NEXTCLOUD_PHP_MEMORY_LIMIT="1024M"
NEXTCLOUD_UPLOAD_LIMIT="16G"
NEXTCLOUD_PHONE_REGION="FR"
NEXTCLOUD_MAINTENANCE_HOUR="1"
NEXTCLOUD_PREVIEW_MAX="2048"
NEXTCLOUD_PHOTOS="false"             # Memories (+ Photos) pour comparer avec Immich
NEXTCLOUD_PHOTOS_USER=""             # vide = NEXTCLOUD_ADMIN_USER
NEXTCLOUD_PHOTOS_PATH="/Photo"       # dossier de la bibliothèque, dans le compte
NEXTCLOUD_RECOGNIZE="false"          # IA Recognize (visages, objets) : image ffmpeg+node, ~4 Go RAM
RECOGNIZE_MODES="faces objects"      # faces objects landmarks audio video
RECOGNIZE_CORES="2"
DOCKER_CPU_TYPE="x86-64-v2-AES"      # "host" requis pour l'IA (AVX2) puis : --run docker_vm_cpu_apply reboot

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
# WireGuard (VPN)
# ---------------------------------------------------------------------------

WG_ID="106"
WG_HOSTNAME="wireguard"
WG_IP="10.10.10.106/24"
WG_GATEWAY="10.10.10.1"
WG_CORES="1"
WG_MEMORY="256"
WG_DISK="2G"
WG_UNPRIVILEGED="1"         # 0 = CT privilégié (si WireGuard refuse de démarrer en non privilégié)

WG_PORT="51820"             # UDP : à rediriger sur la box vers l'IP LAN de l'hôte
WG_NET="10.10.20.0/24"      # réseau VPN (obligatoirement un /24)
WG_SERVER_IP="10.10.20.1"
WG_MTU="1420"
WG_ENDPOINT=""              # nom/IP publique donnés aux clients ; vide = ${DOMAIN}
WG_DNS="1.1.1.1, 9.9.9.9"   # DNS donnés aux pairs du profil "internet"

# Client Tor dans le CT WireGuard : profil VPN « tor » (tout le trafic passe par le réseau Tor)
# et proxy SOCKS5 (socks5h://<IP du CT>:9050) pour les VM/CT du réseau privé et les pairs « lan ».
ENABLE_TOR=true
WG_TOR_SOCKS=true           # proxy SOCKS5 de Tor pour le réseau privé et les pairs lan

# Pairs créés à l'installation : "nom:profil" séparés par des espaces.
# Profils : lan | backup | internet | tor  (d'autres se créent ensuite : wg_add_peer)
WG_PEERS="pc:lan"

# Destinations autorisées par profil (vide = valeur par défaut calculée) :
WG_LAN_ROUTES=""            # défaut : réseau privé des VM + IP LAN de l'hôte (/32)
WG_BACKUP_DESTS=""          # défaut : IP de la VM FILES
WG_BACKUP_PORTS="22,445"    # ports TCP autorisés pour le profil backup

# ---------------------------------------------------------------------------
# NODE (Node.js + MongoDB, CT LXC avec Docker) : voir ct/60-node.sh
# ---------------------------------------------------------------------------

NODE_ID="107"
NODE_HOSTNAME="node"
NODE_IP="10.10.10.107/24"
NODE_GATEWAY="10.10.10.1"
NODE_CORES="2"
NODE_MEMORY="2048"
NODE_DISK="16G"
NODE_HTTP_PORT="3000"       # port de l'application (aussi redirigé depuis l'IP LAN de l'hôte)
MONGO_IMAGE="mongo:8"       # "mongo:4.4" si le CPU de l'hôte n'a pas AVX
MONGO_ADMIN_USER="admin"
MONGO_ADMIN_PASSWORD=""     # vide = généré et affiché dans le résumé final
MONGO_DB="app"              # base utilisée par l'application d'exemple
NODE_SUBDOMAIN="web"       # <sous-domaine>.${DOMAIN} -> application via SWAG (HTTPS) ; vide = pas de proxy SWAG
NODE_MONGO_EXPOSE=false     # true = MongoDB joignable sur le réseau privé (10.10.10.107:27017)

# ---------------------------------------------------------------------------
# MAIL (serveur mail autonome, CT LXC + docker-mailserver) : voir ct/70-mail.sh
# ---------------------------------------------------------------------------

MAIL_ID="108"
MAIL_HOSTNAME="mail"
MAIL_IP="10.10.10.108/24"
MAIL_GATEWAY="10.10.10.1"
MAIL_CORES="2"
MAIL_MEMORY="1536"
MAIL_DISK="8G"
MAIL_SUBDOMAIN="mail"       # nom du serveur : <sous-domaine>.${DOMAIN} (MX, certificat, DNS inverse)
# Comptes créés à l'installation : "nom" ou "nom:mot_de_passe" séparés par des espaces
# (adresse nom@${DOMAIN}). Sans mot de passe, il est généré et affiché. Vide = aucun.
MAIL_ACCOUNTS="contact"
# Relais SMTP pour l'ENVOI (vide = envoi direct depuis l'IP de la box). Utile si le FAI
# bloque le port 25 sortant ou si les mails finissent en spam. Ex. "[smtp-relay.brevo.com]:587"
MAIL_RELAY_HOST=""
MAIL_RELAY_USER=""
MAIL_RELAY_PASSWORD=""

# DNS (filtrage DNS / anti-publicités, CT LXC + AdGuard Home) : voir ct/80-dns.sh
# Le port 53 de l'IP LAN de l'hôte est redirigé vers le CT : mets l'IP LAN de l'hôte
# comme serveur DNS dans la box (DHCP). Ne redirige JAMAIS le port 53 de la box vers l'hôte.
DNS_ID="109"
DNS_HOSTNAME="dns"
DNS_IP="10.10.10.109/24"
DNS_GATEWAY="10.10.10.1"
DNS_CORES="1"
DNS_MEMORY="256"
DNS_DISK="2G"
DNS_ADMIN_USER="admin"
DNS_ADMIN_PASSWORD=""       # vide = généré et affiché dans le résumé (aussi dans le CT : /root/adguard-admin.pass)
DNS_VERSION="latest"        # "latest" ou une version figée (ex. v0.107.57)
DNS_UPSTREAMS="https://dns.quad9.net/dns-query https://cloudflare-dns.com/dns-query"   # DNS amont chiffrés (DoH), séparés par des espaces
DNS_BOOTSTRAP="9.9.9.9 1.1.1.1"   # DNS en clair pour trouver les serveurs ci-dessus
DNS_BLOCKLISTS=""           # listes en plus de la liste AdGuard par défaut : "Nom|URL;Nom|URL"
DNS_LOCAL_REWRITE=true      # cloud.<domaine>, etc. -> IP LAN de l'hôte pour les clients du LAN/VPN
DNS_REWRITE_EXTRA=""        # autres noms à réécrire vers l'IP LAN de l'hôte, séparés par des espaces
DNS_EXTRA_CLIENTS=""        # réseaux supplémentaires autorisés à interroger le DNS (CIDR, séparés par des espaces)
DNS_FORWARD_LAN=true        # redirige le port 53 (UDP/TCP) de l'IP LAN de l'hôte vers le CT
DNS_UI_PORT="3080"          # interface d'admin : http://<IP LAN hôte>:3080 ; vide = pas de redirection
DNS_FOR_WG=true             # les pairs VPN (profils lan et internet) utilisent ce DNS

# MONITOR (supervision) : voir ct/90-monitor.sh
# IA locale (CT LXC) : Ollama (modèles) + Open WebUI (interface, documents interrogeables) + OCR des PDF scannés.
# Le pilote NVIDIA est installé sur l'HÔTE (un redémarrage est demandé la première fois) et le GPU est partagé avec le CT.
# Interfaces réservées au réseau local / VPN (jamais exposées par SWAG).
AI_ID="111"
AI_HOSTNAME="ia"
AI_IP="10.10.10.111/24"
AI_GATEWAY="10.10.10.1"
AI_CORES="$(( $(nproc) / 2 > 2 ? $(nproc) / 2 : 2 ))"
AI_MEMORY="16384"           # Mo ; réduit automatiquement si les autres modules en laissent moins (AI_FORCE pour passer outre)
AI_DISK="120G"              # modèles (plusieurs Go chacun) + index
AI_RAM_RESERVE="3072"       # Mo laissés à l'hôte Proxmox
AI_FORCE=false
AI_GPU="auto"               # auto | true | false
AI_NVIDIA_SOURCE="debian"   # debian (paquets Debian, DKMS) | run (installateur NVIDIA, version AI_NVIDIA_VERSION)
AI_NVIDIA_VERSION=""
AI_VRAM_MB=""               # à renseigner seulement si la VRAM n'est pas lisible
AI_MODEL_CHAT=""            # vide = choisi selon la VRAM (12 Go : qwen2.5:14b)
AI_MODEL_CODE=""            # vide = choisi selon la VRAM (12 Go : qwen2.5-coder:14b)
AI_MODEL_EMBED="bge-m3"
AI_MODEL_AUTOCOMPLETE="qwen2.5-coder:1.5b"
AI_KEEP_ALIVE="5m"          # durée avant de libérer la VRAM après la dernière question
AI_CONTEXT="8192"           # taille de contexte (jetons)
AI_WEB_PORT="8090"
AI_API_PORT="11434"
AI_API_LAN=true             # API Ollama sur l'IP LAN de l'hôte (VS Code) : SANS mot de passe, réseau local uniquement
AI_WEBUI_NAME="Assistant"
AI_WEBUI_EMAIL=""           # vide = LE_EMAIL
AI_WEBUI_PASSWORD=""        # vide = généré et affiché dans le résumé
AI_DOCS_DIR="${SHARED_DIR}/IA/Normes"   # PDF à indexer (même scannés) ; dossier accessible par Samba
AI_OCR=true
AI_OCR_LANG="fra+eng"
AI_INGEST=true
AI_COLLECTION="Normes"
AI_BACKUP=false             # inclure le CT IA dans les sauvegardes vzdump (lourd : modèles)

MONITOR_ID="110"
MONITOR_HOSTNAME="monitor"
MONITOR_IP="10.10.10.110/24"
MONITOR_GATEWAY="10.10.10.1"
MONITOR_CORES="2"
MONITOR_MEMORY="1024"
MONITOR_DISK="8G"
MONITOR_KUMA=true           # Uptime Kuma (disponibilité des services)
MONITOR_NTFY=true           # ntfy (serveur de notifications)
MONITOR_HOMEPAGE=true       # Homepage (page d'accueil des services, réseau local)
KUMA_PORT="3001"            # redirigé depuis l'IP LAN de l'hôte (LAN uniquement)
NTFY_PORT="8085"
HOMEPAGE_PORT="3002"
NTFY_SUBDOMAIN="ntfy"       # <sous-domaine>.${DOMAIN} via SWAG pour les alertes hors du LAN ; vide = pas d'accès Internet
HOMEPAGE_SUBDOMAIN=""       # déconseillé : Homepage n'a pas d'authentification
NTFY_ADMIN_USER="admin"
NTFY_ADMIN_PASSWORD=""      # vide = généré et affiché dans le résumé

# ZONE DNS À PUBLIER (fichier généré, jamais appliqué) : voir host/57-dns-zone.sh
ENABLE_DNS_ZONE=true
DNS_ZONE_DIR="/var/lib/homelab/dns-zone"
DNS_ZONE_IP=""              # vide = IP publique détectée (api.ipify.org) ; à fixer si elle est introuvable
DNS_ZONE_TTL="3600"
DNS_ZONE_PARENT=""          # ex. "ipassed.fr" quand DOMAIN="machin.ipassed.fr" : génère aussi la variante à ajouter dans la zone parente

# NOTIFICATIONS ET SURVEILLANCE DE L'HÔTE : voir host/58-notify.sh
ENABLE_HEALTH=true          # alertes SMART (smartd), disques, RAID, services, sauvegardes (toutes les 10 min)
NOTIFY_NTFY_URL=""          # vide = ntfy du CT MONITOR s'il existe ; sinon une URL (ex. https://ntfy.sh)
NOTIFY_NTFY_TOPIC="homelab"
NOTIFY_NTFY_TOKEN=""        # jeton d'accès ntfy (créé automatiquement avec le CT MONITOR)
NOTIFY_KUMA_PUSH_URL=""     # URL d'un moniteur "Push" d'Uptime Kuma : battement de cœur de l'hôte
HEALTH_DISK_PCT="90"        # alerte si un disque/stockage dépasse ce pourcentage
HEALTH_BACKUP_MAX_H="36"    # alerte si la dernière sauvegarde vzdump est plus vieille
HEALTH_DISK_STEP="10"       # alerte à chaque palier de remplissage franchi (tous les N %) ; 0 = désactivé

# TELEGRAM : alertes + bot de questions (/cpu /memoire /stockage /invites /status) : voir host/58-telegram.sh
ENABLE_TELEGRAM=false
TELEGRAM_BOT_TOKEN=""       # jeton donné par @BotFather (/newbot)
TELEGRAM_CHAT_ID=""         # identifiant(s) de discussion autorisé(s) ; trouve-le avec ./install.sh --run telegram_chat_id
TELEGRAM_ALERTS="miner disk usb backup system network security"   # catégories envoyées : miner | disk | usb | backup | system | network | security | health | smart | all (séparées par des espaces)
# Actions à distance (sauvegardes, VM/CT, hôte) : voir host/58-actions.sh. Désactivées par défaut.
TELEGRAM_ADMIN_ID=""        # identifiant Telegram de l'UNIQUE personne autorisée à agir (discussion privée) ; ./install.sh --run telegram_chat_id
TELEGRAM_ACTIONS=""         # groupes autorisés (séparés par des espaces) : backup | guests | host ; vide = bot en lecture seule
TELEGRAM_ACTION_DELAY="60"  # secondes avant l'arrêt/redémarrage de l'hôte (/annuler possible pendant ce délai)
HEALTH_PUBLIC_IP=true       # alerte quand l'IP publique change (DNS, WireGuard, serveur de sauvegarde à mettre à jour)

# DUMP DES BASES AVANT SAUVEGARDE : voir host/59-db-dump.sh
ENABLE_DB_DUMP=true
DB_DUMP_KEEP="7"            # dumps conservés par base

# TEST DE RESTAURATION MENSUEL ET MISES À JOUR DOCKER : voir host/60-maintenance.sh
ENABLE_RESTORE_TEST=true
RESTORE_TEST_CALENDAR="*-*-02 05:30:00"   # systemd OnCalendar : le 2 de chaque mois à 5h30
RESTORE_TEST_ID="990"       # ID temporaire du CT restauré pour le test (doit être libre)
RESTORE_TEST_STORAGE=""     # vide = GUEST_STORAGE ; storage où le CT de test est restauré
RESTORE_TEST_VERIFY_VM=true # lit en entier les archives de VM (long) ; false = présence/âge seulement
DOCKER_UPDATE_MODE="notify" # off | notify (signale) | safe (applique aux projets sûrs, signale les autres)
DOCKER_UPDATE_CALENDAR="Sat *-*-* 05:00:00"

# CROWDSEC devant SWAG : voir ct/25-crowdsec.sh
ENABLE_CROWDSEC=false
CROWDSEC_WHITELIST=""       # réseaux/IP supplémentaires jamais bannis (CIDR, séparés par des espaces)

# SONARR / RADARR / PROWLARR / QBITTORRENT (dans la VM DOCKER) : voir vm/40-arr.sh
ENABLE_ARR=false
SONARR_PORT="8989"          # interfaces accessibles depuis le LAN uniquement
RADARR_PORT="7878"
PROWLARR_PORT="9696"
QBIT_PORT="8089"
ARR_VPN=true                # qBittorrent derrière gluetun (coupe-circuit) ; false = sans VPN (ton IP est visible)
ARR_VPN_WG_CONF=""          # chemin, sur l'hôte, du fichier WireGuard .conf fourni par ton VPN
ARR_QBIT_USER="admin"
ARR_QBIT_PASSWORD=""        # vide = généré (conservé dans la VM) et affiché dans le résumé
ARR_PUID="0"
ARR_PGID="${SHARED_GID}"

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

# Stockage des images téléchargées (image cloud des VM, pilote NVIDIA...) sur le disque de l'OS (stockage « local »).
# Le template des CT est géré par Proxmox (pveam) dans /var/lib/vz/template/cache : même disque, même logique.
# STORE_IMAGES=true : les images sont téléchargées UNE fois, gardées, jamais réécrites ni retéléchargées aux lancements
# suivants (le téléchargement n'a même lieu que si une VM/CT doit réellement être créé).
# STORE_IMAGES=false : supprimées en fin d'installation (gain d'espace, retéléchargement à la prochaine création).
# Commandes : ./install.sh --run images_status | images_purge
STORE_IMAGES=true
IMAGE_STORE_DIR="/var/lib/vz/template/iso"

# Où stocker l'image cloud Debian, le pilote NVIDIA et les templates des CT :
#   auto  = DATA si GUEST_STORAGE=DATA, sinon local (défaut)
#   local = disque système (/var/lib/vz)
#   DATA  = disque de données (${PROXMOX_DATA_DIR}/template/iso et /template/cache) : pour un petit disque système.
IMAGES_STORAGE="auto"
TEMPLATE_STORAGE="local"

DEBIAN_IMAGE_DIR="${IMAGE_STORE_DIR}"
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
    smartmontools
    zstd
    python3
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

# Compte administrateur non-root sur l'hôte Proxmox (membre de sudo).
# ADMIN_USER vide = aucun compte créé.
ADMIN_USER="${ADMIN_USER:-}"                 # ex. "roland"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"             # vide = généré et affiché (si le compte est créé)
ADMIN_SSH_KEY=""              # clé publique SSH optionnelle (ligne ssh-ed25519 ...)
ADMIN_SUDO_NOPASSWD=false     # true = sudo sans mot de passe
# Connexion SSH directe de root : "" = inchangé | no = interdite | prohibit-password = clé seulement.
# "no" exige ADMIN_USER (membre de sudo, avec clé SSH ou mot de passe) : sinon refusé pour ne pas te verrouiller dehors.
# L'interface web Proxmox (root@pam) et la console ne sont pas concernées. Nota : un cluster Proxmox a besoin du SSH root entre ses nœuds.
SSH_ROOT_LOGIN=""

# SSH depuis l'EXTÉRIEUR, temporaire, pour la phase de développement (poste sans WireGuard) : second port sshd,
# clé SSH seulement (ADMIN_USER + ADMIN_SSH_KEY obligatoires), fail2ban, expiration automatique, notification de chaque
# connexion. La redirection du port sur la box est à faire à la main. true = ouvert à chaque exécution du script ;
# repasser à false (ou ./install.sh --run ssh_external_off) pour fermer. Voir host/16-ssh-external.sh.
SSH_EXTERNAL=false
SSH_EXTERNAL_PORT="2244"
SSH_EXTERNAL_DAYS="7"       # durée d'ouverture en jours puis fermeture automatique ; 0 = SANS limite. Rappel 5 jours avant la fin ; prolonger : ./install.sh --ssh_external_expand <jours>
ADMIN_PVE_ACCESS=true         # true = peut aussi se connecter à l'interface web Proxmox (realm "Linux PAM", rôle Administrator)
ROOT_PASSWORD_HASH=""
SAMBA_PASSWORD_B64=""

# Fichier de réponses optionnel (voir load_answers_file()). Premier
# argument du script, sinon un fichier par défaut à côté du script s'il
# existe.
ANSWERS_FILE="${1:-./proxmox-homelab-answers.json}"
ANSWERS_FILE_LOADED=false

# Confirmation de formatage du disque DATA, lisible depuis ANSWERS_FILE.
FORMAT_CONFIRMATION=""

# Volume existant à réutiliser SANS formatage (ex. grappe RAID mdadm : /dev/md0, ou /dev/sdb1).
# Vide = comportement habituel (DATA_DISK est formaté après confirmation). En interactif, le script
# détecte les grappes/volumes existants et demande quoi faire ; ici on peut l'imposer.
DATA_EXISTING_DEVICE=""

# Mode du stockage DATA :
#   disk (défaut) = DATA_DISK (ou DATA_EXISTING_DEVICE) est un disque/volume dédié, formaté en ext4 après confirmation.
#   thin          = disque UNIQUE : DATA est un volume mince (thin LV) ext4 créé DANS le thin pool de Proxmox
#                   (DATA_THIN_POOL, « pve/data » par défaut), à côté des disques de VM de local-lvm. Aucun disque
#                   n'est formaté ; l'espace est partagé dynamiquement. Voir DATA_LV_SIZE et POOL_GUARD.
DATA_MODE="disk"
DATA_THIN_POOL="pve/data"     # mode thin : thin pool LVM qui héberge le volume DATA
DATA_THIN_LV="datafs"         # mode thin : nom du volume créé
DATA_LV_SIZE="90%"            # mode thin : taille VIRTUELLE du volume : « NN% » de la taille du pool, ou absolue (ex. 2T)
DATA_TRIM="true"              # fstrim.timer hebdomadaire sur l'hôte (rend au pool l'espace des fichiers supprimés)
POOL_GUARD="true"             # arrête toutes les VM/CT quand un thin pool ou DATA atteint POOL_GUARD_PCT (reprise à la main)
POOL_GUARD_PCT="98"           # seuil du garde-fou (50 à 99)


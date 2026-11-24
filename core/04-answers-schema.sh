###############################################################################
#         SCHÉMA DU FICHIER DE RÉPONSES (SOURCE UNIQUE DES VARIABLES)         #
###############################################################################

# Une ligne par élément, champs séparés par « ^ » :
#   G^groupe^TITRE                                            un groupe (= une section du fichier JSON, dans cet ordre)
#   V^groupe^NOM^type^requis^init^défaut^description          une variable
#     type    : str (texte) | bool (true/false) | int (nombre) | ref (texte pouvant contenir ${AUTRE_VARIABLE})
#     requis  : 1 = écrite avec la valeur « init » dans un fichier neuf ; 0 = écrite à null (null = défaut du script)
#     défaut  : valeur par défaut DU SCRIPT (documentation ; la vraie valeur est dans core/00-config.sh) ; « (calculé) » = dépend de la machine
# Ajouter une variable : la définir (avec sa valeur par défaut) dans core/00-config.sh, puis ajouter UNE ligne V ici.
# Le fichier JSON, la documentation (proxmox-homelab-variables.md), --describe et la fusion --update-answers en découlent.
answers_schema_text() {
    cat <<'EOF_SCHEMA'
G^obligatoire^OBLIGATOIRE
G^services^SERVICES PRINCIPAUX
G^docker_apps^APPLICATIONS DE LA VM DOCKER
G^reseau^RÉSEAU
G^dns_zone^ZONE DNS À PUBLIER (fichier généré, jamais appliqué)
G^admin_ssh^COMPTE ADMIN / SSH
G^wireguard^WIREGUARD
G^services_optionnels^SERVICES OPTIONNELS (CT)
G^sauvegardes^SAUVEGARDES
G^maintenance^MAINTENANCE AUTOMATIQUE
G^xmrig^XMRIG (si ENABLE_XMRIG)
G^avance^AVANCÉ (rarement utile) : identifiants, adresses, ressources, montages, ports
V^obligatoire^DOMAIN^str^1^exemple.fr^ipassed.fr^Ton nom de domaine, servi par SWAG (enregistrements DNS A vers ton IP publique). Peut être un sous-domaine (ex. machin.ipassed.fr : cloud.machin.ipassed.fr, mail.machin.ipassed.fr...) ; voir DNS_ZONE_*. À CHANGER : tous les sous-domaines en dépendent. Défaut du script : ipassed.fr.
V^obligatoire^LE_EMAIL^str^1^toi@exemple.fr^^E-mail de contact Let's Encrypt (alertes d'expiration). Défaut : vide.
V^obligatoire^ROOT_PASSWORD^str^1^^^Mot de passe root des VM/CT. Vide = demandé au lancement.
V^obligatoire^SAMBA_PASSWORD^str^1^^^Mot de passe de l'utilisateur Samba « fileshare ». Vide = demandé.
V^obligatoire^DATA_DISK^str^1^/dev/sdb^/dev/sdb^Disque ou grappe RAID (/dev/mdX, formatée en entier) à formater pour les données. Formaté QUE s'il ne porte pas déjà le label DATA. En interactif (sans fichier de réponses), l'installateur LISTE les disques et grappes détectés (disque système exclu, contenu affiché) et tu choisis ; ce fichier sert en mode automatique. Défaut : /dev/sdb.
V^obligatoire^DATA_PARTITION^str^0^^/dev/sdb1^Partition créée/utilisée sur ce disque. Défaut : /dev/sdb1.
V^obligatoire^FORMAT_CONFIRMATION^str^1^^^« FORMAT-YES » autorise le formatage sans question. Défaut : vide (demande).
V^obligatoire^DATA_EXISTING_DEVICE^str^0^^^Volume ou RAID existant à réutiliser SANS formatage (ex. /dev/md0, /dev/sdb1). Vide = comportement habituel ; en interactif, le script détecte et demande.
V^obligatoire^DATA_MODE^str^0^^disk^Stockage DATA : disk (disque ou grappe dédié, DATA_DISK, formaté après confirmation) | thin (DISQUE UNIQUE : DATA est un volume mince ext4 créé dans le thin pool de Proxmox, rien n'est formaté ; l'espace est partagé avec local-lvm). Défaut : disk.
V^obligatoire^GUEST_STORAGE^str^0^^local-lvm^Storage Proxmox des DISQUES des VM et CT créés : local-lvm (disque système, rapide, instantanés) | DATA (disque de données : épargne le disque système ; lent si disque dur) | autre storage acceptant « images » et « rootdir ». Les invités déjà créés ne sont pas déplacés. Défaut : local-lvm.
V^obligatoire^IMAGES_STORAGE^str^0^^auto^Où stocker l'image cloud Debian, le pilote NVIDIA et les templates des CT : auto (DATA si GUEST_STORAGE=DATA, sinon local) | local (disque système) | DATA. Pour un serveur à très petit disque système : GUEST_STORAGE="DATA" (le reste suit). Snippets cloud-init (quelques Ko) restent sur local. Défaut : auto.
V^services^ENABLE_SWAG^str^1^keep^^CT 101 : reverse proxy HTTPS + Let's Encrypt. États : keep (installe si absent, conserve) | run (existe déjà : applique SEULEMENT les paramètres du fichier, sans créer, supprimer, télécharger ni installer ; si tous les services actifs sont en run, les étapes d'installation de l'hôte sont aussi sautées ; absent = installé comme keep) | cleanup (supprime puis recrée) | remove (supprime) | skip (ne touche à rien) | vide (demande). Défaut du script : vide.
V^services^ENABLE_DOCKER^str^1^keep^^VM 103 : Nextcloud, Sync-in, Immich, Home Assistant, Jellyfin. Mêmes états. Défaut : vide.
V^services^ENABLE_FILES^str^1^keep^^VM 104 : Samba et Webmin. Mêmes états. Défaut : vide.
V^services^ENABLE_WIREGUARD^str^1^keep^^CT 106 : VPN. Mêmes états. Défaut : vide.
V^services^ENABLE_XMRIG^str^1^skip^^CT 105 : mineur Monero (voir §9). Mêmes états. Défaut : vide.
V^services^ENABLE_NODE^str^1^skip^skip^CT 107 : Node.js + MongoDB (voir §6). Mêmes états. Défaut : skip.
V^services^ENABLE_MAIL^str^1^skip^skip^CT 108 : serveur mail autonome (voir §6). Mêmes états. Défaut : skip.
V^services^ENABLE_DNS^str^1^skip^skip^CT 109 : AdGuard Home, DNS filtrant (voir §6). Mêmes états. Défaut : skip.
V^services^ENABLE_MONITOR^str^1^skip^skip^CT 110 : Uptime Kuma + ntfy + Homepage (voir §6). Mêmes états. Défaut : skip.
V^services^ENABLE_AI^str^1^skip^skip^CT 111 : IA locale (Ollama + Open WebUI + OCR des PDF, sur le GPU NVIDIA de l'hôte). Mêmes états. Activation intelligente : RAM vérifiée, XMRig et machine-learning d'Immich bridés, modèles choisis selon la VRAM. Demande une carte NVIDIA (sinon CPU, très lent) et ≥ 8 Go de RAM libres. Défaut : skip.
V^docker_apps^ENABLE_NEXTCLOUD^bool^0^^true^Nextcloud. Valeurs : true | false. Défaut : true.
V^docker_apps^ENABLE_SYNCIN^bool^0^^true^Sync-in. Valeurs : true | false. Défaut : true.
V^docker_apps^SYNCIN_ONLYOFFICE^bool^0^^false^Édition de documents dans Sync-in avec le serveur OnlyOffice (exige ENABLE_ONLYOFFICE=true). Installation existante : ./install.sh --run syncin_editors_apply. Défaut : false.
V^docker_apps^SYNCIN_COLLABORA^bool^0^^false^Édition de documents dans Sync-in avec Collabora Online (exige ENABLE_COLLABORA=true) ; peut être combiné avec SYNCIN_ONLYOFFICE. Installation existante : ./install.sh --run syncin_editors_apply. Défaut : false.
V^docker_apps^ENABLE_IMMICH^bool^0^^true^Immich (photos). Valeurs : true | false. Défaut : true.
V^docker_apps^ENABLE_HOMEASSISTANT^bool^0^^true^Home Assistant. Valeurs : true | false. Défaut : true.
V^docker_apps^ENABLE_JELLYFIN^bool^0^^true^Jellyfin. Valeurs : true | false. Défaut : true.
V^docker_apps^ENABLE_COLLABORA^bool^0^^false^Édition de documents dans Nextcloud (office.<domaine>) ; demande Nextcloud, SWAG et un enregistrement DNS A. Valeurs : true | false. Défaut : false.
V^docker_apps^ENABLE_ONLYOFFICE^bool^0^^false^Autre éditeur (onlyoffice.<domaine>), ~4 Go de RAM en plus ; peut coexister avec Collabora (./install.sh --run nextcloud_office_use collabora|onlyoffice). Défaut : false.
V^docker_apps^NEXTCLOUD_ADMIN_USER^str^0^^admin^Administrateur Nextcloud. Défaut : admin.
V^docker_apps^NEXTCLOUD_ADMIN_PASSWORD^str^0^^^Vide = généré et affiché à la fin.
V^docker_apps^NEXTCLOUD_DB_PASSWORD^str^0^^^Mot de passe de la base Nextcloud. Vide = généré.
V^docker_apps^NEXTCLOUD_OPTIMIZE^bool^0^^true^Optimisation Nextcloud (Redis, cron, PHP). Défaut : true.
V^docker_apps^NEXTCLOUD_IMAGE_TAG^str^0^^^Étiquette d'image. Vide = version majeure en cours (recommandé).
V^docker_apps^NEXTCLOUD_PHP_MEMORY_LIMIT^str^0^^1024M^Limite de mémoire PHP de Nextcloud (php.ini memory_limit). Défaut : 1024M.
V^docker_apps^NEXTCLOUD_UPLOAD_LIMIT^str^0^^16G^Taille maximale d'un envoi de fichier dans Nextcloud (PHP_UPLOAD_LIMIT). Défaut : 16G.
V^docker_apps^NEXTCLOUD_PHONE_REGION^str^0^^FR^Région par défaut des numéros de téléphone Nextcloud (code pays ISO, ex. FR). Défaut : FR.
V^docker_apps^NEXTCLOUD_MAINTENANCE_HOUR^int^0^^1^Heure (0-23) de début de la fenêtre de maintenance des tâches lourdes de Nextcloud. Défaut : 1.
V^docker_apps^NEXTCLOUD_PREVIEW_MAX^int^0^^2048^Taille maximale (en pixels) des aperçus générés par Nextcloud. Défaut : 2048.
V^docker_apps^NEXTCLOUD_PHOTOS^bool^0^^false^Photos Nextcloud (Memories) pour comparer avec Immich. Défaut : false.
V^docker_apps^NEXTCLOUD_PHOTOS_USER^str^0^^^Compte propriétaire des photos. Vide = administrateur.
V^docker_apps^NEXTCLOUD_PHOTOS_PATH^str^0^^/Photo^Dossier de la bibliothèque dans ce compte. Défaut : /Photo.
V^docker_apps^NEXTCLOUD_RECOGNIZE^bool^0^^false^IA Recognize (visages, objets). Demande DOCKER_CPU_TYPE="host" et DOCKER_MEMORY="12288". Défaut : false.
V^docker_apps^RECOGNIZE_MODES^str^0^^faces objects^Modes : faces objects landmarks audio video. Défaut : "faces objects".
V^docker_apps^RECOGNIZE_CORES^int^0^^2^Nombre de cœurs utilisés par Recognize pour la classification. Défaut : 2.
V^docker_apps^DOCKER_CPU_TYPE^str^0^^x86-64-v2-AES^Type de processeur de la VM Docker ("host" pour l'IA). Défaut : x86-64-v2-AES.
V^docker_apps^SYNCIN_ADMIN_LOGIN^str^0^^admin^Administrateur Sync-in. Défaut : admin.
V^docker_apps^SYNCIN_ADMIN_PASSWORD^str^0^^^Vide = généré.
V^docker_apps^SYNCIN_DB_PASSWORD^str^0^^^Mot de passe de la base Sync-in. Vide = généré.
V^docker_apps^SYNCIN_DB_ROOT_PASSWORD^str^0^^^Mot de passe root de la base Sync-in. Vide = généré.
V^docker_apps^SYNCIN_SECRET_1^str^0^^^Secret interne Sync-in (1 à 4). Laisse vide pour qu'ils soient générés, jamais « change-me ».
V^docker_apps^SYNCIN_SECRET_2^str^0^^^Idem (secret 2).
V^docker_apps^SYNCIN_SECRET_3^str^0^^^Idem (secret 3).
V^docker_apps^SYNCIN_SECRET_4^str^0^^^Idem (secret 4).
V^docker_apps^IMMICH_DB_PASSWORD^str^0^^^Mot de passe de la base Immich. Vide = généré.
V^docker_apps^COLLABORA_SUBDOMAIN^str^0^^office^Sous-domaine(s) de Collabora : https://<nom>.<domaine>. Un ou plusieurs noms séparés par des espaces. Défaut : office.
V^docker_apps^ONLYOFFICE_SUBDOMAIN^str^0^^onlyoffice^Sous-domaine(s) d'OnlyOffice (un ou plusieurs noms). Défaut : onlyoffice.
V^docker_apps^COLLABORA_DICTIONARIES^str^0^^fr_FR en_GB^Dictionnaires du correcteur orthographique (codes de langue séparés par des espaces).
V^docker_apps^ONLYOFFICE_JWT_SECRET^str^0^^^Secret JWT d'OnlyOffice. Vide = généré.
V^reseau^HOST_NAME^str^0^^^Nom d'hôte voulu pour ce serveur Proxmox. Vide = inchangé. Appliqué en tout premier, puis le script s'ARRÊTE : redémarre et relance. Refusé s'il existe déjà des VM/CT ou un cluster.
V^reseau^NODE_NAME^str^0^^(calculé)^Nom du nœud Proxmox. Défaut : hostname -s (calculé ; ne le fixe que cas particulier).
V^reseau^LAN_BRIDGE^str^0^^vmbr0^Pont relié à ta box (LAN). Défaut : vmbr0.
V^reseau^PRIVATE_BRIDGE^str^0^^vmbr1^Pont du réseau privé des VM/CT. Défaut : vmbr1.
V^reseau^LAN_IP^str^0^^192.168.1.4^IP LAN de l'hôte (redirections DNS et interfaces d'admin). Détectée sur LAN_BRIDGE ; à forcer si la détection se trompe (repli : 192.168.1.4).
V^reseau^LAN_NET^str^0^^192.168.1.0/24^Réseau LAN (autorisations, DNS, pare-feu). Défaut : 192.168.1.0/24.
V^reseau^LAN_GW^str^0^^192.168.1.1^Passerelle du LAN (ta box). Défaut : 192.168.1.1.
V^reseau^HOST_IP^str^0^^^État voulu de vmbr0 : « DHCP » ou une IP fixe. Vide = demandé en interactif. ATTENTION : un changement d'IP coupe la session SSH en cours.
V^reseau^PRIVATE_NET^str^0^^10.10.10.0/24^Réseau privé des VM/CT. Défaut : 10.10.10.0/24.
V^reseau^PRIVATE_GW^str^0^^10.10.10.1^Adresse de l'hôte sur le réseau privé : passerelle des CT/VM et cible du tirage via WireGuard. Défaut : 10.10.10.1.
V^dns_zone^ENABLE_DNS_ZONE^bool^0^^true^Génère le fichier de zone (A, MX, SPF, DMARC, DKIM) d'après les services actifs, avec les changements depuis la dernière fois. Valeurs : true | false. Fichiers dans DNS_ZONE_DIR ; relance : ./install.sh --run dns_zone_generate.
V^dns_zone^DNS_ZONE_DIR^str^0^^/var/lib/homelab/dns-zone^Dossier de sortie des fichiers de zone.
V^dns_zone^DNS_ZONE_IP^str^0^^^IP publique à publier. Vide = détectée (api.ipify.org) ; à fixer si introuvable.
V^dns_zone^DNS_ZONE_TTL^int^0^^3600^TTL des enregistrements en secondes. Défaut : 3600.
V^dns_zone^DNS_ZONE_PARENT^str^0^^^Zone parente quand DOMAIN est un sous-domaine, ex. « ipassed.fr » pour DOMAIN=machin.ipassed.fr : génère aussi <DOMAIN>.parent.zone à ajouter dans la zone parente. Vide = pas de variante.
V^admin_ssh^ADMIN_USER^str^1^^^Compte sudo non-root sur l'hôte (ex. « roland »). Vide = aucun compte.
V^admin_ssh^ADMIN_PASSWORD^str^1^^^Vide = généré et affiché (si le compte est créé).
V^admin_ssh^ADMIN_SSH_KEY^str^1^^^Clé publique SSH du compte (une ligne « ssh-ed25519 AAAA... » ou « ssh-rsa AAAA... »), recommandée. Pour l'obtenir, sur TON poste (Linux/macOS, ou PowerShell/Git Bash sous Windows) : ssh-keygen -t rsa -b 4096 -C "mail@gmail.com"  (alternative moderne : ssh-keygen -t ed25519 -C "mail@gmail.com"). Accepte l'emplacement proposé ; la phrase secrète est facultative mais conseillée. Deux fichiers sont créés dans ~/.ssh/ : id_rsa (clé PRIVÉE, à ne jamais partager ni coller ici) et id_rsa.pub (clé publique). Colle ici le TEXTE contenu dans le fichier .pub (affichable avec : cat ~/.ssh/id_rsa.pub), sur une seule ligne, entre guillemets. Vide = pas de clé, connexion par mot de passe seulement.
V^admin_ssh^ADMIN_SUDO_NOPASSWD^bool^0^^false^true = sudo sans mot de passe. Défaut : false.
V^admin_ssh^ADMIN_PVE_ACCESS^bool^0^^true^Le compte peut aussi se connecter à l'interface web Proxmox (realm Linux PAM, rôle Administrator). Défaut : true.
V^admin_ssh^SSH_ROOT_LOGIN^str^1^^^SSH direct de root. Valeurs : vide (inchangé) | no (interdit, exige ADMIN_USER utilisable, sinon refusé) | prohibit-password (clé seulement). Console et interface web non concernées ; un cluster a besoin du SSH root entre nœuds.
V^admin_ssh^STORE_IMAGES^bool^0^^true^Garder les images téléchargées (image cloud Debian des VM, pilote NVIDIA) sur le disque de l'OS : téléchargées une seule fois, jamais réécrites ni retéléchargées aux lancements suivants (le téléchargement n'a lieu que si une VM doit réellement être créée). false = supprimées en fin d'installation (gain d'espace, retéléchargement à la prochaine création). Le template des CT est géré par Proxmox dans le même stockage. Valeurs : true | false. Défaut : true.
V^admin_ssh^IMAGE_STORE_DIR^str^0^^/var/lib/vz/template/iso^Dossier de stockage des images téléchargées (disque de l'OS, stockage « local » de Proxmox). Défaut : /var/lib/vz/template/iso.
V^admin_ssh^SSH_EXTERNAL^bool^0^^false^SSH depuis l'EXTÉRIEUR, pour la phase de développement (poste sans WireGuard). Ouvre un second port sshd (clé SSH uniquement, ADMIN_USER obligatoire avec ADMIN_SSH_KEY, jamais root ni mot de passe), fail2ban, notification de chaque connexion et FERMETURE AUTOMATIQUE après SSH_EXTERNAL_DAYS jours (0 = sans limite). La redirection du port sur la box est à faire à la main (et à retirer ensuite). Fermer : repasser à false ou ./install.sh --run ssh_external_off. Valeurs : true | false. Défaut : false.
V^admin_ssh^SSH_EXTERNAL_PORT^int^0^^2244^Port TCP du SSH externe (1024-65535, pas 22) : à rediriger sur la box vers l'IP LAN de l'hôte, même port. Beaucoup de réseaux d'entreprise bloquent les ports inhabituels : en cas d'échec, essaie un port courant (ex. 8443). Défaut : 2244.
V^admin_ssh^SSH_EXTERNAL_DAYS^int^0^^7^Durée d'ouverture en jours (1 à 365), puis fermeture automatique ; 0 = SANS limite (rappel hebdomadaire). Notification quotidienne les 5 derniers jours ; prolonger : ./install.sh --ssh_external_expand <jours> (0 = sans limite). Relancer le script ne raccourcit pas une échéance déjà prolongée. Défaut : 7.
V^admin_ssh^DISABLE_SUBSCRIPTION_NAG^bool^0^^true^Masque la fenêtre « No valid subscription » (annulable : apt reinstall proxmox-widget-toolkit). Défaut : true.
V^wireguard^WG_PORT^int^0^^51820^Port UDP, à rediriger sur la box vers l'IP LAN de l'hôte. Défaut : 51820.
V^wireguard^WG_ENDPOINT^str^0^^^Nom ou IP publique donnés aux clients. Vide = DOMAIN.
V^wireguard^WG_NET^str^0^^10.10.20.0/24^Réseau du VPN (obligatoirement un /24). Défaut : 10.10.20.0/24.
V^wireguard^WG_SERVER_IP^str^0^^10.10.20.1^Adresse du serveur dans le tunnel (dans WG_NET). Défaut : 10.10.20.1.
V^wireguard^ENABLE_TOR^bool^0^^true^Client Tor dans le CT WireGuard : active le profil VPN « tor » (tout le trafic du pair passe par le réseau Tor, rien d'autre ne sort : si Tor tombe, la connexion est coupée) et un proxy SOCKS5 Tor. Création d'un pair : ./install.sh --run wg_add_peer <nom> tor ; test : ./install.sh --run wg_test_tor. Défaut : true.
V^wireguard^WG_TOR_SOCKS^bool^0^^true^Proxy SOCKS5 de Tor (socks5h://<IP du CT WireGuard>:9050) pour les VM/CT du réseau privé, et à l'adresse VPN du serveur pour les pairs du profil lan. Non accessible depuis Internet. Défaut : true.
V^wireguard^WG_PEERS^str^1^pc:lan^pc:lan^Pairs créés à l'installation, « nom:profil » séparés par des espaces (profils : lan, backup, internet, tor). Profils : lan (ton réseau) | backup (destinations et ports limités) | internet (tout le trafic). Ex. « pc:lan n54l:backup telephone:internet ».
V^wireguard^WG_DNS^str^0^^1.1.1.1, 9.9.9.9^DNS des pairs « internet » ; remplacé par le CT DNS si ENABLE_DNS et DNS_FOR_WG.
V^wireguard^WG_MTU^int^0^^1420^MTU du tunnel (à baisser si des connexions se bloquent). Défaut : 1420.
V^wireguard^WG_UNPRIVILEGED^int^0^^1^1 = CT non privilégié ; 0 = privilégié si WireGuard refuse de démarrer. Défaut : 1.
V^wireguard^WG_LAN_ROUTES^str^0^^^Destinations du profil lan (CIDR séparés par des virgules). Vide = réseau privé des VM + IP LAN de l'hôte en /32.
V^wireguard^WG_BACKUP_DESTS^str^0^^^Destinations du profil backup (IP séparées par des virgules). Vide = VM FILES, plus l'hôte (PRIVATE_GW) si ENABLE_BACKUP_PULL=true.
V^wireguard^WG_BACKUP_PORTS^str^0^^22,445^Ports TCP autorisés pour le profil backup. Défaut : 22,445.
V^services_optionnels^NODE_SUBDOMAIN^str^0^^web^NODE : <nom>.<domaine> via SWAG (HTTPS) ; un ou plusieurs noms. Vide = pas de proxy SWAG. Défaut : web.
V^services_optionnels^NODE_HTTP_PORT^int^0^^3000^NODE : port de l'application, aussi redirigé depuis l'IP LAN de l'hôte. Défaut : 3000.
V^services_optionnels^MONGO_IMAGE^str^0^^mongo:8^NODE : image MongoDB ; « mongo:4.4 » si le CPU n'a pas AVX.
V^services_optionnels^MONGO_ADMIN_USER^str^0^^admin^NODE : administrateur MongoDB. Défaut : admin.
V^services_optionnels^MONGO_ADMIN_PASSWORD^str^0^^^NODE : vide = généré et affiché.
V^services_optionnels^MONGO_DB^str^0^^app^NODE : base de l'application d'exemple. Défaut : app.
V^services_optionnels^NODE_MONGO_EXPOSE^bool^0^^false^NODE : true = MongoDB joignable sur le réseau privé (10.10.10.107:27017). Défaut : false.
V^services_optionnels^MAIL_SUBDOMAIN^str^0^^mail^MAIL : nom du serveur <nom>.<domaine> (MX, certificat, DNS inverse) ; plusieurs noms possibles (le premier sert de MX). Défaut : mail.
V^services_optionnels^MAIL_ACCOUNTS^str^0^^contact^MAIL : comptes créés (nom@<domaine>), « nom » ou « nom:mdp » séparés par des espaces. Sans mot de passe = généré. Vide = aucun.
V^services_optionnels^MAIL_RELAY_HOST^str^0^^^MAIL : relais SMTP pour l'envoi, ex. « [smtp-relay.brevo.com]:587 » si le port 25 sortant est bloqué ou si ça finit en spam. Vide = envoi direct.
V^services_optionnels^MAIL_RELAY_USER^str^0^^^MAIL : identifiant du relais.
V^services_optionnels^MAIL_RELAY_PASSWORD^str^0^^^MAIL : mot de passe du relais.
V^services_optionnels^DNS_ADMIN_USER^str^0^^admin^DNS : identifiant de l'interface AdGuard. Défaut : admin. (Mets l'IP LAN de l'hôte comme DNS dans la box ; ne redirige JAMAIS le port 53 de la box vers l'hôte.)
V^services_optionnels^DNS_ADMIN_PASSWORD^str^0^^^DNS : vide = généré, affiché et gardé dans le CT (/root/adguard-admin.pass).
V^services_optionnels^DNS_VERSION^str^0^^latest^DNS : « latest » ou version figée (ex. v0.107.57).
V^services_optionnels^DNS_UPSTREAMS^str^0^^https://dns.quad9.net/dns-query https://cloudflare-dns.com/dns-query^DNS : DNS amont chiffrés (DoH), séparés par des espaces.
V^services_optionnels^DNS_BOOTSTRAP^str^0^^9.9.9.9 1.1.1.1^DNS : DNS en clair pour retrouver les serveurs amont.
V^services_optionnels^DNS_BLOCKLISTS^str^0^^^DNS : listes en plus de celle d'AdGuard, au format « Nom|URL;Nom|URL ».
V^services_optionnels^DNS_LOCAL_REWRITE^bool^0^^true^DNS : cloud.<domaine>, etc. résolus vers l'IP LAN de l'hôte pour les clients LAN/VPN. Défaut : true.
V^services_optionnels^DNS_REWRITE_EXTRA^str^0^^^DNS : autres noms à réécrire vers l'IP LAN de l'hôte, séparés par des espaces.
V^services_optionnels^DNS_EXTRA_CLIENTS^str^0^^^DNS : réseaux supplémentaires autorisés (CIDR, espaces) ; LAN, réseau privé et VPN le sont déjà.
V^services_optionnels^DNS_FORWARD_LAN^bool^0^^true^DNS : redirige le port 53 (UDP/TCP) de l'IP LAN de l'hôte vers le CT. Défaut : true.
V^services_optionnels^DNS_UI_PORT^int^0^^3080^DNS : interface sur http://<IP LAN hôte>:3080 ; vide = pas de redirection.
V^services_optionnels^DNS_FOR_WG^bool^0^^true^DNS : les pairs VPN (profils lan et internet) utilisent ce DNS. Défaut : true.
V^services_optionnels^MONITOR_KUMA^bool^0^^true^MONITOR : Uptime Kuma (disponibilité ; moniteurs à créer à la main). Défaut : true.
V^services_optionnels^MONITOR_NTFY^bool^0^^true^MONITOR : ntfy, serveur de notifications. Défaut : true.
V^services_optionnels^MONITOR_HOMEPAGE^bool^0^^true^MONITOR : Homepage, page d'accueil des services (réseau local). Défaut : true.
V^services_optionnels^NTFY_SUBDOMAIN^str^0^^ntfy^MONITOR : ntfy.<domaine> via SWAG pour les alertes hors du LAN ; un ou plusieurs noms. Vide = LAN/VPN seulement.
V^services_optionnels^HOMEPAGE_SUBDOMAIN^str^0^^^MONITOR : déconseillé, Homepage n'a pas d'authentification. Un ou plusieurs noms.
V^services_optionnels^NTFY_ADMIN_USER^str^0^^admin^MONITOR : administrateur ntfy. Défaut : admin.
V^services_optionnels^NTFY_ADMIN_PASSWORD^str^0^^^MONITOR : vide = généré et affiché.
V^services_optionnels^ENABLE_CROWDSEC^bool^1^false^false^CrowdSec devant SWAG (anti brute-force et scans). Valeurs : true | false. Défaut : false.
V^services_optionnels^CROWDSEC_WHITELIST^str^0^^^CrowdSec : réseaux/IP supplémentaires jamais bannis (CIDR, espaces).
V^services_optionnels^ENABLE_ARR^bool^1^false^false^Sonarr / Radarr / Prowlarr / qBittorrent dans la VM DOCKER (Prowlarr sans indexeur au départ). Défaut : false.
V^services_optionnels^ARR_VPN^bool^1^true^true^qBittorrent uniquement via VPN (gluetun, coupe-circuit). false = ton IP est visible. Défaut : true.
V^services_optionnels^ARR_VPN_WG_CONF^str^1^^^Chemin sur l'hôte du fichier WireGuard .conf de ton fournisseur VPN (ex. /root/vpn.conf) ; requis si ARR_VPN=true.
V^services_optionnels^ARR_QBIT_USER^str^0^^admin^Identifiant qBittorrent. Défaut : admin.
V^services_optionnels^ARR_QBIT_PASSWORD^str^0^^^Vide = généré (gardé dans la VM) et affiché.
V^services_optionnels^ARR_PUID^int^0^^0^UID des conteneurs arr. Défaut : 0.
V^services_optionnels^ARR_PGID^int^0^^2000^GID des conteneurs arr (groupe de SHARED). Défaut : SHARED_GID (2000).
V^services_optionnels^SONARR_PORT^int^0^^8989^Port Sonarr (LAN seulement). Défaut : 8989.
V^services_optionnels^RADARR_PORT^int^0^^7878^Port Radarr (LAN seulement). Défaut : 7878.
V^services_optionnels^PROWLARR_PORT^int^0^^9696^Port Prowlarr (LAN seulement). Défaut : 9696.
V^services_optionnels^QBIT_PORT^int^0^^8089^Port qBittorrent (LAN seulement). Défaut : 8089.
V^sauvegardes^ENABLE_BACKUP^bool^1^true^false^Tâche vzdump quotidienne de toutes les VM/CT. Valeurs : true | false. Défaut du script : false.
V^sauvegardes^BACKUP_STORAGE^str^0^^DATA^Storage Proxmox de destination (même disque que les données : prévoir une copie externe). Défaut : DATA.
V^sauvegardes^BACKUP_SCHEDULE^str^0^^01:00^Heure du lancement (« HH:MM » ou « sun 01:00 »), à finir avant le tirage du N54L (3 h). Défaut : 01:00.
V^sauvegardes^BACKUP_MODE^str^0^^snapshot^snapshot | suspend | stop (stop arrête brièvement la VM/CT). Défaut : snapshot.
V^sauvegardes^BACKUP_COMPRESS^str^0^^zstd^Compression vzdump (zstd, gzip, lzo, 0). Défaut : zstd.
V^sauvegardes^BACKUP_KEEP^str^0^^keep-daily=7,keep-weekly=4,keep-monthly=3^Rotation des archives (options keep-* de vzdump).
V^sauvegardes^BACKUP_RESTIC_REPO^str^0^^^Copie hors site chiffrée (restic). Vide = désactivée. Ex. sftp:utilisateur@10.10.20.5:/sauvegardes/homelab ou s3:s3.fr-par.scw.cloud/mon-bucket/homelab.
V^sauvegardes^BACKUP_RESTIC_PASSWORD^str^0^^^OBLIGATOIRE si le dépôt est défini ; à conserver ailleurs.
V^sauvegardes^BACKUP_OFFSITE_PATHS^str^0^^^Chemins envoyés hors site, séparés par des espaces. Vide = vzdump + données d'applications + SHARED.
V^sauvegardes^BACKUP_OFFSITE_CRON^str^0^^30 4 * * *^Expression cron de la copie hors site. Défaut : tous les jours à 4 h 30.
V^sauvegardes^BACKUP_OFFSITE_KEEP^str^0^^--keep-daily 7 --keep-weekly 4 --keep-monthly 6^Rétention restic (options de « restic forget »).
V^sauvegardes^ENABLE_BACKUP_PULL^bool^1^false^false^Accès LECTURE SEULE pour le serveur de sauvegarde N54L qui tire les données (rrsync -ro sur DATA_MOUNT, compte sans root). backup_source_export l'active seul. Défaut : false.
V^sauvegardes^BACKUP_PULL_USER^str^0^^backup-pull^Compte système dédié au tirage (sans mot de passe). Défaut : backup-pull.
V^sauvegardes^BACKUP_PULL_PUBKEY^str^1^^^Clé publique du N54L : le TEXTE contenu dans le fichier .pub généré sur le N54L (cat /root/.ssh/homelab-pull.pub ; créée par : ssh-keygen -t ed25519 -f /root/.ssh/homelab-pull -C "homelab-pull"). Ne jamais coller la clé privée (fichier sans .pub). Peut rester vide si les clés viennent de backup_source_export.
V^sauvegardes^BACKUP_PULL_FROM^str^0^^^Vide = toute IP ; sinon IP/plage autorisée. La clé reste en lecture seule.
V^sauvegardes^BACKUP_CANARY^bool^0^^true^Fichiers témoins docx/jpg/avi surveillés par le N54L pour détecter une altération. Défaut : true.
V^sauvegardes^ENABLE_BACKUP_USB^bool^1^false^false^Export vers un disque USB portant le fichier marqueur ; un disque sans marqueur n'est jamais touché. Défaut : false.
V^sauvegardes^BACKUP_USB_MARKER^str^0^^HOMELAB-BACKUP^Nom du fichier marqueur à créer à la racine du disque.
V^sauvegardes^BACKUP_USB_CONTENT^str^0^^dump apps^Contenu exporté (combinable) : dump (vzdump) | apps (dossiers d'applications) | shared (partage Samba). Modifiable dans le marqueur.
V^sauvegardes^BACKUP_USB_KEEP^int^0^^2^Nombre d'exports conservés sur le disque. Défaut : 2.
V^sauvegardes^BACKUP_USB_WEBHOOK^str^0^^^URL ntfy facultative pour être prévenu ; sinon journal + message console.
V^sauvegardes^BACKUP_USB_ALLOWED_UUIDS^str^0^^^UUID de disques autorisés (espaces). Vide = tout disque USB avec marqueur.
V^maintenance^ENABLE_HEALTH^bool^0^^true^Alertes SMART, disques, RAID, services, sauvegardes (toutes les 10 min). Défaut : true.
V^maintenance^POOL_GUARD^bool^0^^true^Garde-fou de stockage : quand un thin pool LVM (données ou métadonnées) ou le volume DATA atteint POOL_GUARD_PCT, arrête les sauvegardes en cours puis TOUTES les VM et CT, coupe leur démarrage automatique et notifie. Rien ne redémarre seul : ménage puis « sudo homelab-pool-guard --resume ». Défaut : true.
V^maintenance^POOL_GUARD_PCT^int^0^^98^Seuil du garde-fou en % (50 à 99). Réarmement automatique 5 points plus bas. Défaut : 98.
V^maintenance^HEALTH_DISK_PCT^int^0^^90^Alerte si un disque/storage dépasse ce pourcentage. Défaut : 90.
V^maintenance^HEALTH_BACKUP_MAX_H^int^0^^36^Alerte si la dernière sauvegarde vzdump a plus de N heures. Défaut : 36.
V^maintenance^HEALTH_DISK_STEP^int^0^^10^Alerte à CHAQUE palier de remplissage franchi (tous les N %, à la montée ; retour en dessous signalé avec 2 % de marge). 0 = désactivé. Défaut : 10.
V^maintenance^ENABLE_TELEGRAM^bool^1^false^false^Alertes Telegram + bot de questions (/cpu /memoire /stockage /invites /status, lecture seule). Étapes : @BotFather > /newbot (jeton), écris à ton bot, ./install.sh --run telegram_chat_id, puis ./install.sh --run configure_notify. Défaut : false.
V^maintenance^TELEGRAM_BOT_TOKEN^str^0^^^Jeton du bot donné par @BotFather (ex. 123456789:AAAA...). À garder secret.
V^maintenance^TELEGRAM_CHAT_ID^str^0^^^Identifiant(s) numérique(s) de discussion AUTORISÉS, séparés par des espaces ou virgules : le bot ignore tout autre. Obtenu par ./install.sh --run telegram_chat_id.
V^maintenance^TELEGRAM_ALERTS^str^0^^miner disk usb backup system network security^Catégories envoyées sur Telegram, séparées par des espaces : miner (mineur arrêté/relancé par la charge CPU) | disk (palier de stockage) | usb (disque USB branché, export) | backup (sauvegarde vzdump : début et fin détaillée) | system (serveur démarré) | network (IP publique modifiée) | security (action Telegram exécutée ou code refusé) | health (problèmes de la surveillance) | smart (disques) | all.
V^maintenance^TELEGRAM_ADMIN_ID^str^0^^^Identifiant Telegram de l'UNIQUE personne autorisée à lancer des actions (discussion privée avec le bot uniquement). Vide = aucune action possible. Obtenu par ./install.sh --run telegram_chat_id.
V^maintenance^TELEGRAM_ACTIONS^str^0^^^Groupes d'actions autorisés depuis Telegram, séparés par des espaces : backup (/sauvegarder /dumpbases /testrestauration) | guests (/invite_demarrer /invite_arreter /invite_redemarrer) | host (/hote_redemarrer /hote_eteindre). Vide (défaut) = bot en lecture seule. Chaque action exige un code à usage unique (TOTP) de ton application d'authentification : ./install.sh --run telegram_totp_show affiche le secret.
V^maintenance^TELEGRAM_ACTION_DELAY^int^0^^60^Secondes d'attente avant l'arrêt ou le redémarrage de l'hôte demandé par Telegram ; /annuler l'interrompt pendant ce délai. Défaut : 60.
V^maintenance^HEALTH_PUBLIC_IP^bool^0^^true^Alerte (catégorie network) quand l'IP publique change : zone DNS, tunnel WireGuard et serveur de sauvegarde à mettre à jour. Défaut : true.
V^maintenance^NOTIFY_NTFY_URL^str^0^^^Serveur ntfy. Vide = ntfy du CT MONITOR s'il existe ; sinon une URL (ex. https://ntfy.sh).
V^maintenance^NOTIFY_NTFY_TOPIC^str^0^^homelab^Sujet ntfy des alertes. Défaut : homelab.
V^maintenance^NOTIFY_NTFY_TOKEN^str^0^^^Jeton d'accès ntfy (créé automatiquement avec le CT MONITOR).
V^maintenance^NOTIFY_KUMA_PUSH_URL^str^0^^^URL d'un moniteur « Push » d'Uptime Kuma : battement de cœur de l'hôte.
V^maintenance^ENABLE_DB_DUMP^bool^0^^true^Dump logique des bases avant chaque sauvegarde (dans APPS_DIR/backups/db/). Défaut : true.
V^maintenance^DB_DUMP_KEEP^int^0^^7^Dumps conservés par base. Défaut : 7.
V^maintenance^ENABLE_RESTORE_TEST^bool^0^^true^Test de restauration mensuel. Défaut : true.
V^maintenance^RESTORE_TEST_CALENDAR^str^0^^*-*-02 05:30:00^OnCalendar systemd : le 2 de chaque mois à 5 h 30.
V^maintenance^RESTORE_TEST_ID^int^0^^990^ID libre du CT temporaire de test. Défaut : 990.
V^maintenance^RESTORE_TEST_STORAGE^str^0^^^Storage où restaurer temporairement le CT. Vide = GUEST_STORAGE. Défaut : vide.
V^maintenance^RESTORE_TEST_VERIFY_VM^bool^0^^true^true = lit en entier les archives de VM (long) ; false = présence et âge seulement.
V^maintenance^DOCKER_UPDATE_MODE^str^1^notify^notify^Mises à jour des images Docker. off | notify (signale) | safe (applique les projets sûrs, signale les autres). Défaut : notify.
V^maintenance^DOCKER_UPDATE_CALENDAR^str^0^^Sat *-*-* 05:00:00^OnCalendar systemd de la vérification (samedi 5 h).
V^xmrig^XMRIG_WALLET^str^0^^^Adresse de portefeuille Monero : à renseigner pour être crédité.
V^xmrig^XMRIG_POOL^str^0^^xmrpool.eu:5555^Pool de minage « hôte:port ».
V^xmrig^XMRIG_CORES^int^0^^(calculé)^Cœurs du CT. Défaut : nproc - 1 (min. 1), calculé ; XMRig plafonne de toute façon selon le cache L3.
V^xmrig^XMRIG_MEMORY^int^0^^4096^Mémoire du CT en Mo. Défaut : 4096.
V^xmrig^XMRIG_VERSION^str^0^^6.26.0^Version téléchargée sur GitHub (met à jour XMRIG_SHA256_FALLBACK si tu la changes).
V^xmrig^XMRIG_SHA256_FALLBACK^str^0^^fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5^SHA-256 de secours, utilisé seulement si SHA256SUMS est injoignable (le hash officiel est toujours tenté d'abord).
V^xmrig^XMRIG_STOP_THRESHOLD^int^0^^25^Suspend le minage si la charge CPU dépasse ce %. Défaut : 25.
V^xmrig^XMRIG_RESUME_THRESHOLD^int^0^^20^Reprend sous ce % de charge. Défaut : 20.
V^xmrig^XMRIG_RESUME_DELAY^int^0^^300^Secondes sous le seuil avant de reprendre. Défaut : 300.
V^xmrig^XMRIG_MONITOR_INTERVAL^int^0^^5^Secondes entre deux mesures de charge. Défaut : 5.
V^xmrig^HUGEPAGES_COUNT^int^0^^1280^Pages mémoire réservées (accélèrent RandomX). Défaut : 1280.
V^xmrig^HUGEPAGES_MOUNT^str^0^^/mnt/huge^Point de montage des HugePages.
V^avance^FILES_ID^int^0^^104^VM FILES : identifiant Proxmox. Défaut : 104.
V^avance^FILES_HOSTNAME^str^0^^files^VM FILES : nom d'hôte. Défaut : files.
V^avance^FILES_IP^str^0^^10.10.10.104/24^VM FILES : adresse IPv4 en CIDR. Défaut : 10.10.10.104/24.
V^avance^FILES_GATEWAY^str^0^^10.10.10.1^VM FILES : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^FILES_CORES^int^0^^2^VM FILES : cœurs. Défaut : 2.
V^avance^FILES_MEMORY^int^0^^2048^VM FILES : mémoire en Mo. Défaut : 2048.
V^avance^FILES_DISK^str^0^^32G^VM FILES : taille du disque. Défaut : 32G.
V^avance^DOCKER_ID^int^0^^103^VM DOCKER (8192 avec OnlyOffice) : identifiant Proxmox. Défaut : 103.
V^avance^DOCKER_HOSTNAME^str^0^^docker^VM DOCKER (8192 avec OnlyOffice) : nom d'hôte. Défaut : docker.
V^avance^DOCKER_IP^str^0^^10.10.10.103/24^VM DOCKER (8192 avec OnlyOffice) : adresse IPv4 en CIDR. Défaut : 10.10.10.103/24.
V^avance^DOCKER_GATEWAY^str^0^^10.10.10.1^VM DOCKER (8192 avec OnlyOffice) : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^DOCKER_CORES^int^0^^2^VM DOCKER (8192 avec OnlyOffice) : cœurs. Défaut : 2.
V^avance^DOCKER_MEMORY^int^0^^8192^VM DOCKER (8192 avec OnlyOffice) : mémoire en Mo. Défaut : 4096.
V^avance^DOCKER_DISK^str^0^^64G^VM DOCKER : taille du disque (images Docker + bases + miniatures : 32G se remplit, Immich/Postgres tombent alors en erreur 500). Agrandir ensuite : ./install.sh --run docker_disk_grow 32G. Défaut : 64G.
V^avance^SWAG_ID^int^0^^101^CT SWAG : identifiant Proxmox. Défaut : 101.
V^avance^SWAG_HOSTNAME^str^0^^swag^CT SWAG : nom d'hôte. Défaut : swag.
V^avance^SWAG_IP^str^0^^10.10.10.16/24^CT SWAG : adresse IPv4 en CIDR. Défaut : 10.10.10.16/24.
V^avance^SWAG_GATEWAY^str^0^^10.10.10.1^CT SWAG : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^SWAG_CORES^int^0^^1^CT SWAG : cœurs. Défaut : 1.
V^avance^SWAG_MEMORY^int^0^^512^CT SWAG : mémoire en Mo. Défaut : 512.
V^avance^SWAG_DISK^str^0^^8G^CT SWAG : taille du disque. Défaut : 8G.
V^avance^WG_ID^int^0^^106^CT WireGuard : identifiant Proxmox. Défaut : 106.
V^avance^WG_HOSTNAME^str^0^^wireguard^CT WireGuard : nom d'hôte. Défaut : wireguard.
V^avance^WG_IP^str^0^^10.10.10.106/24^CT WireGuard : adresse IPv4 en CIDR. Défaut : 10.10.10.106/24.
V^avance^WG_GATEWAY^str^0^^10.10.10.1^CT WireGuard : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^WG_CORES^int^0^^1^CT WireGuard : cœurs. Défaut : 1.
V^avance^WG_MEMORY^int^0^^256^CT WireGuard : mémoire en Mo. Défaut : 256.
V^avance^WG_DISK^str^0^^2G^CT WireGuard : taille du disque. Défaut : 2G.
V^avance^NODE_ID^int^0^^107^CT NODE : identifiant Proxmox. Défaut : 107.
V^avance^NODE_HOSTNAME^str^0^^node^CT NODE : nom d'hôte. Défaut : node.
V^avance^NODE_IP^str^0^^10.10.10.107/24^CT NODE : adresse IPv4 en CIDR. Défaut : 10.10.10.107/24.
V^avance^NODE_GATEWAY^str^0^^10.10.10.1^CT NODE : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^NODE_CORES^int^0^^2^CT NODE : cœurs. Défaut : 2.
V^avance^NODE_MEMORY^int^0^^2048^CT NODE : mémoire en Mo. Défaut : 2048.
V^avance^NODE_DISK^str^0^^16G^CT NODE : taille du disque. Défaut : 16G.
V^avance^MAIL_ID^int^0^^108^CT MAIL : identifiant Proxmox. Défaut : 108.
V^avance^MAIL_HOSTNAME^str^0^^mail^CT MAIL : nom d'hôte. Défaut : mail.
V^avance^MAIL_IP^str^0^^10.10.10.108/24^CT MAIL : adresse IPv4 en CIDR. Défaut : 10.10.10.108/24.
V^avance^MAIL_GATEWAY^str^0^^10.10.10.1^CT MAIL : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^MAIL_CORES^int^0^^2^CT MAIL : cœurs. Défaut : 2.
V^avance^MAIL_MEMORY^int^0^^1536^CT MAIL : mémoire en Mo. Défaut : 1536.
V^avance^MAIL_DISK^str^0^^8G^CT MAIL : taille du disque. Défaut : 8G.
V^avance^DNS_ID^int^0^^109^CT DNS : identifiant Proxmox. Défaut : 109.
V^avance^DNS_HOSTNAME^str^0^^dns^CT DNS : nom d'hôte. Défaut : dns.
V^avance^DNS_IP^str^0^^10.10.10.109/24^CT DNS : adresse IPv4 en CIDR. Défaut : 10.10.10.109/24.
V^avance^DNS_GATEWAY^str^0^^10.10.10.1^CT DNS : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^DNS_CORES^int^0^^1^CT DNS : cœurs. Défaut : 1.
V^avance^DNS_MEMORY^int^0^^256^CT DNS : mémoire en Mo. Défaut : 256.
V^avance^DNS_DISK^str^0^^2G^CT DNS : taille du disque. Défaut : 2G.
V^avance^MONITOR_ID^int^0^^110^CT MONITOR : identifiant Proxmox. Défaut : 110.
V^avance^MONITOR_HOSTNAME^str^0^^monitor^CT MONITOR : nom d'hôte. Défaut : monitor.
V^avance^MONITOR_IP^str^0^^10.10.10.110/24^CT MONITOR : adresse IPv4 en CIDR. Défaut : 10.10.10.110/24.
V^avance^MONITOR_GATEWAY^str^0^^10.10.10.1^CT MONITOR : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^MONITOR_CORES^int^0^^2^CT MONITOR : cœurs. Défaut : 2.
V^avance^MONITOR_MEMORY^int^0^^1024^CT MONITOR : mémoire en Mo. Défaut : 1024.
V^avance^MONITOR_DISK^str^0^^8G^CT MONITOR : taille du disque. Défaut : 8G.
V^avance^XMRIG_ID^int^0^^105^CT XMRIG : identifiant Proxmox. Défaut : 105.
V^avance^XMRIG_HOSTNAME^str^0^^xmrig^CT XMRIG : nom d'hôte. Défaut : xmrig.
V^avance^XMRIG_IP^str^0^^10.10.10.105/24^CT XMRIG : adresse IPv4 en CIDR. Défaut : 10.10.10.105/24.
V^avance^XMRIG_GATEWAY^str^0^^10.10.10.1^CT XMRIG : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
V^avance^XMRIG_DISK^str^0^^8G^CT XMRIG : taille du disque. Défaut : 8G.
V^avance^DATA_THIN_POOL^str^0^^pve/data^Mode thin : thin pool LVM (VG/LV) qui héberge le volume DATA. Défaut : pve/data.
V^avance^DATA_THIN_LV^str^0^^datafs^Mode thin : nom du volume DATA créé dans le pool. Défaut : datafs.
V^avance^DATA_LV_SIZE^str^0^^90%^Mode thin : taille VIRTUELLE du volume DATA, « NN% » de la taille du pool ou valeur absolue (2T). Le volume ne prend que ce qu'il contient réellement ; df affiche cette taille virtuelle, pas la place réelle (voir lvs). Défaut : 90%.
V^avance^DATA_TRIM^bool^0^^true^Active fstrim.timer sur l'hôte (passage hebdomadaire) : rend au thin pool l'espace des fichiers supprimés. Défaut : true.
V^avance^DATA_MOUNT^str^0^^/mnt/data^Point de montage du disque DATA. Défaut : /mnt/data.
V^avance^SHARED_DIR^ref^0^^${DATA_MOUNT}/SHARED^Dossier du partage Samba. Défaut : ${DATA_MOUNT}/SHARED.
V^avance^PROXMOX_DATA_DIR^ref^0^^${DATA_MOUNT}/proxmox^Dossier des sauvegardes vzdump. Défaut : ${DATA_MOUNT}/proxmox.
V^avance^SHARED_GROUP^str^0^^fileshare^Groupe propriétaire du partage. Défaut : fileshare.
V^avance^SHARED_GID^int^0^^2000^GID de ce groupe (aussi utilisé par les conteneurs). Défaut : 2000.
V^avance^VIRTIOFS_DIR_ID^str^0^^files_shared^Identifiant VirtioFS de SHARED. Défaut : files_shared.
V^avance^APPS_DIR^ref^0^^${DATA_MOUNT}/apps^Données d'applications HORS Samba (Immich, Nextcloud, Sync-in, mail, dumps de bases). Défaut : ${DATA_MOUNT}/apps.
V^avance^APPS_VIRTIOFS_DIR_ID^str^0^^apps_data^Identifiant du 2e VirtioFS (APPS_DIR). Défaut : apps_data.
V^avance^FILES_MOUNT^str^0^^/srv/data^Montage de SHARED dans la VM FILES. Défaut : /srv/data.
V^avance^FILES_SAMBA_SHARE^str^0^^SHARED^Nom du partage Samba. Défaut : SHARED.
V^avance^DOCKER_SHARED_MOUNT^str^0^^/srv/data^Montage de SHARED dans la VM DOCKER. Défaut : /srv/data.
V^avance^DOCKER_APPS_MOUNT^str^0^^/srv/apps^Montage d'APPS_DIR dans la VM DOCKER. Défaut : /srv/apps.
V^avance^DOCKER_APPS_UID^int^0^^1000^UID des conteneurs d'applications. Défaut : 1000.
V^avance^DOCKER_APPS_GID^int^0^^2000^GID des conteneurs d'applications. Défaut : SHARED_GID.
V^avance^SWAG_CERT_BACKUP^str^0^^/var/lib/homelab/swag-letsencrypt.tgz^Sauvegarde des certificats Let's Encrypt (évite la limite de 5 certificats identiques par semaine).
V^avance^NEXTCLOUD_SUBDOMAIN^str^0^^cloud^Sous-domaine(s) de Nextcloud : https://<nom>.<domaine>. UN OU PLUSIEURS noms séparés par des espaces (ex. "cloud nuage") : le premier est le nom principal, tous ont leur DNS, figurent dans le certificat Let's Encrypt et sont servis par SWAG. Un nom ne peut servir qu'à un seul service. Appliquer à une installation existante : ./install.sh --run repair_swag_subdomains. Défaut : cloud.
V^avance^SYNCIN_SUBDOMAIN^str^0^^sync^Sous-domaine(s) de Sync-in (même règle que NEXTCLOUD_SUBDOMAIN : un ou plusieurs noms). Défaut : sync.
V^avance^IMMICH_SUBDOMAIN^str^0^^photos photo^Sous-domaine(s) d'Immich (photos). Un ou plusieurs noms ; le premier est le principal. Défaut : "photos photo".
V^avance^JELLYFIN_SUBDOMAIN^str^0^^media^Sous-domaine(s) de Jellyfin (actif si ENABLE_JELLYFIN). Un ou plusieurs noms, ex. "media movies". Défaut : media.
V^avance^ENABLE_PORTAL^bool^0^^true^Portail : page d'accueil unique (https://<PORTAL_SUBDOMAIN>.<domaine>) avec un lien vers chaque service installé. Demande SWAG et un enregistrement DNS A. Valeurs : true | false. Défaut : true.
V^avance^PORTAL_SUBDOMAIN^str^0^^home^Sous-domaine(s) du portail. Un ou plusieurs noms. Avec le DNS interne (AdGuard), le même nom marche en local et depuis Internet. Défaut : home.
V^avance^PORTAL_TITLE^str^0^^Mon serveur^Titre affiché en haut du portail. Défaut : Mon serveur.
V^avance^PORTAL_AUTH^str^0^^public^Mot de passe du portail : public = demandé seulement depuis Internet (libre en réseau local/VPN) | all = partout | none = jamais. Défaut : public.
V^avance^PORTAL_USER^str^0^^admin^Utilisateur du mot de passe du portail. Défaut : admin.
V^avance^PORTAL_PASSWORD^str^0^^^Mot de passe du portail. Vide = généré et affiché dans le résumé (puis conservé dans le fichier de secrets).
V^avance^PORTAL_LOCAL_PORT^int^0^^8088^Accès de secours sans DNS : http://<IP LAN hôte>:<port> (vue réseau local). Ne pas rediriger ce port depuis la box. Défaut : 8088.
V^avance^AI_CORES^int^0^^(calculé)^Cœurs du CT IA. Défaut : la moitié des cœurs de l'hôte (minimum 2).
V^avance^AI_MEMORY^int^0^^16384^RAM du CT IA en Mo. Réduite automatiquement si les autres modules activés en laissent moins (minimum 8192, sinon l'installation s'arrête sauf AI_FORCE=true). Défaut : 16384.
V^avance^AI_DISK^str^0^^120G^Disque du CT IA (modèles de plusieurs Go chacun). Défaut : 120G.
V^avance^AI_RAM_RESERVE^int^0^^3072^RAM (Mo) laissée à l'hôte Proxmox dans le calcul du budget. Défaut : 3072.
V^avance^AI_FORCE^bool^0^^false^Installer l'IA même si la RAM disponible est insuffisante (risque de saturation). Valeurs : true | false. Défaut : false.
V^avance^AI_GPU^str^0^^auto^GPU NVIDIA : auto (détecté avec lspci) | true (exige la carte) | false (CPU seulement). Défaut : auto.
V^avance^AI_NVIDIA_SOURCE^str^0^^debian^Pilote NVIDIA de l'hôte : debian (paquets Debian non-free + DKMS) | run (installateur officiel NVIDIA, version AI_NVIDIA_VERSION ; versions hôte et CT identiques). Si debian échoue avec ton noyau, essaie run. Désactive Secure Boot dans le BIOS. Défaut : debian.
V^avance^AI_NVIDIA_VERSION^str^0^^^Version du pilote pour AI_NVIDIA_SOURCE=run (ex. 580.95.05). Défaut : vide.
V^avance^AI_VRAM_MB^str^0^^^VRAM en Mo, seulement si elle n'est pas lisible avant le premier redémarrage (une 3060 = 12288). Défaut : vide (hypothèse 12000).
V^avance^AI_MODEL_CHAT^str^0^^^Modèle de discussion Ollama. Vide = choisi selon la VRAM (≥ 20 Go : qwen2.5:32b, ≥ 10 Go : qwen2.5:14b, ≥ 6 Go : 7b, sinon 3b). Défaut : vide.
V^avance^AI_MODEL_CODE^str^0^^^Modèle de code Ollama. Vide = qwen2.5-coder à la taille choisie selon la VRAM. Défaut : vide.
V^avance^AI_MODEL_EMBED^str^0^^bge-m3^Modèle d'embeddings (recherche dans les documents, multilingue). Défaut : bge-m3.
V^avance^AI_MODEL_AUTOCOMPLETE^str^0^^qwen2.5-coder:1.5b^Petit modèle rapide pour l'autocomplétion dans VS Code. Défaut : qwen2.5-coder:1.5b.
V^avance^AI_KEEP_ALIVE^str^0^^5m^Délai avant de libérer la VRAM après la dernière requête. Défaut : 5m.
V^avance^AI_CONTEXT^int^0^^8192^Taille de contexte des modèles (jetons) ; plus grand = plus de VRAM. Défaut : 8192.
V^avance^AI_WEB_PORT^int^0^^8090^Port d'Open WebUI : http://<IP LAN hôte>:8090 (LAN uniquement, ne pas rediriger depuis la box). Défaut : 8090.
V^avance^AI_API_PORT^int^0^^11434^Port de l'API Ollama. Défaut : 11434.
V^avance^AI_API_LAN^bool^0^^true^Rediriger l'API Ollama sur l'IP LAN de l'hôte (pour VS Code). Elle n'a PAS de mot de passe : réseau local uniquement. Valeurs : true | false. Défaut : true.
V^avance^AI_WEBUI_NAME^str^0^^Assistant^Nom affiché par Open WebUI. Défaut : Assistant.
V^avance^AI_WEBUI_EMAIL^str^0^^^E-mail du compte administrateur Open WebUI. Vide = LE_EMAIL.
V^avance^AI_WEBUI_PASSWORD^str^0^^^Mot de passe administrateur Open WebUI. Vide = généré et affiché dans le résumé.
V^avance^AI_DOCS_DIR^ref^0^^${SHARED_DIR}/IA/Normes^Dossier des documents à indexer (normes en PDF, même scannés), accessible par Samba. OCR et indexation automatiques toutes les 15 minutes. Défaut : SHARED/IA/Normes.
V^avance^AI_OCR^bool^0^^true^OCR des PDF scannés (ocrmypdf) avant indexation. Valeurs : true | false. Défaut : true.
V^avance^AI_OCR_LANG^str^0^^fra+eng^Langues de l'OCR (codes Tesseract). Défaut : fra+eng.
V^avance^AI_INGEST^bool^0^^true^Envoyer automatiquement les documents dans la base de connaissances d'Open WebUI. Valeurs : true | false. Défaut : true.
V^avance^AI_COLLECTION^str^0^^Normes^Nom de la base de connaissances Open WebUI. Défaut : Normes.
V^avance^AI_BACKUP^bool^0^^false^Inclure le CT IA dans les sauvegardes vzdump (lourd à cause des modèles). Valeurs : true | false. Défaut : false.
V^avance^AI_ID^int^0^^111^Identifiant Proxmox du CT IA. Défaut : 111.
V^avance^AI_IP^str^0^^10.10.10.111/24^IP du CT IA. Défaut : 10.10.10.111/24.
V^avance^NEXTCLOUD_HTTP_PORT^int^0^^8081^Port HTTP interne de Nextcloud (accès LAN ; ne le redirige pas depuis la box). Défaut : 8081.
V^avance^SYNCIN_HTTP_PORT^int^0^^6060^Port Sync-in. Défaut : 6060.
V^avance^IMMICH_HTTP_PORT^int^0^^2283^Port Immich. Défaut : 2283.
V^avance^HOMEASSISTANT_HTTP_PORT^int^0^^8123^Port Home Assistant. Défaut : 8123.
V^avance^JELLYFIN_HTTP_PORT^int^0^^8096^Port Jellyfin. Défaut : 8096.
V^avance^COLLABORA_HTTP_PORT^int^0^^9980^Port Collabora. Défaut : 9980.
V^avance^ONLYOFFICE_HTTP_PORT^int^0^^8082^Port OnlyOffice. Défaut : 8082.
V^avance^KUMA_PORT^int^0^^3001^Port Uptime Kuma (redirigé depuis l'IP LAN, LAN seulement). Défaut : 3001.
V^avance^HOMEPAGE_PORT^int^0^^3002^Port Homepage. Défaut : 3002.
V^avance^NTFY_PORT^int^0^^8085^Port ntfy. Défaut : 8085.
V^avance^DEBIAN_IMAGE_URL^str^0^^https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2^Image cloud Debian 13 des VM.
V^avance^DEBIAN_IMAGE_DIR^ref^0^^${IMAGE_STORE_DIR}^Dossier de stockage de l'image.
V^avance^DEBIAN_IMAGE^ref^0^^${DEBIAN_IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2^Chemin complet de l'image.
V^avance^LOG_FILE^str^0^^(calculé)^Journal de l'installation. Défaut : /var/log/proxmox-homelab-install-<version>.log.
EOF_SCHEMA
}

# Variables du fichier de réponses (installateur v2.61.0)

Fichier généré par `./install.sh --init-answers` / `--update-answers` : ne pas l'éditer, il est régénéré.
Une variable en particulier : `./install.sh --describe NOM` (ou le début d'un nom, ex. `NEXTCLOUD_`).

## Format du fichier `proxmox-homelab-answers.json`

- Un objet JSON. Les **groupes** (`obligatoire`, `services`, `reseau`...) ne servent qu'à ranger : seul le **nom de la
  variable** compte ; il doit rester unique dans tout le fichier. Tu peux déplacer une variable d'un groupe à l'autre.
- **`null` (ou clé absente) = valeur par défaut du script.** Pour changer une valeur, remplace `null` par la valeur voulue.
- Valeurs : texte (`"abc"`), `true` / `false`, nombre (`8192`). Un texte vide `""` est une vraie valeur (par ex. mot de passe
  vide = généré ou demandé), différente de `null`.
- Plusieurs noms pour une variable qui l'accepte (sous-domaines...) : soit un texte avec espaces (`"cloud nc"`), soit une liste
  (`["cloud", "nc"]`).
- Les variables de type `ref` peuvent contenir `${AUTRE_VARIABLE}` (ex. `"${DATA_MOUNT}/SHARED"`).
- Les clés qui commencent par `_` sont ignorées : `_version`, `_note`, `_nouveau` (variables ajoutées par la dernière mise à
  jour). Tes variables inconnues du modèle sont rangées dans le groupe `personnalise` (appliquées, avec un avertissement).
- Le fichier peut contenir des mots de passe : droits 600, jamais dans git. Les mots de passe GÉNÉRÉS par le script sont gardés
  à part dans `proxmox-homelab-secrets.json`.

## Services à états (`ENABLE_SWAG`, `ENABLE_DOCKER`, `ENABLE_FILES`, `ENABLE_XMRIG`, `ENABLE_WIREGUARD`, `ENABLE_NODE`, `ENABLE_MAIL`...)

| Valeur | Effet |
|---|---|
| `"keep"` | installe si absent, conserve s'il existe |
| `"run"` | existe déjà : applique SEULEMENT les paramètres (rien créé, supprimé, téléchargé ni installé) |
| `"cleanup"` | supprime puis recrée à neuf (repasser en `keep` ensuite !) |
| `"remove"` | supprime et n'installe pas |
| `"skip"` | ne touche à rien |
| `""` | installe si absent ; s'il existe, demande |

Les états s'appliquent à un invité entier (VM/CT) : pour Nextcloud, c'est `ENABLE_DOCKER` (VM 103).

## Plusieurs domaines (section `sites`)

Section facultative, à la racine du JSON (hors des groupes). Absente : un seul site, `DOMAIN`. Chaque site a ses dossiers dans
DATA (`<racine>/SHARED` et `<racine>/apps`) et son groupe Unix ; l'infrastructure (VM Docker, SWAG, mail, DNS...) est commune.

```json
"sites": {
  "ipassed.fr": { "racine": null },
  "autre.org":  { "racine": "/mnt/data/autre.org", "services": ["nextcloud", "mail", "samba"] }
}
```

| Clé | Effet |
|---|---|
| `racine` | dossier du site ; `null` = `${DATA_MOUNT}/<domaine>` (valable aussi pour le site principal `DOMAIN`) |
| `services` | parmi `nextcloud syncin immich jellyfin homeassistant arr mail samba node` : dossiers créés (défaut d'un site secondaire : `samba`) |
| `groupe`, `gid` | groupe Unix du site (défaut `fs_<domaine>`, GID libre à partir de 2001) ; le site principal garde `fileshare` / 2000 |

Commandes : `./install.sh --sites-status` (état), `./install.sh --site-add domaine.tld [svc1,svc2] [/racine]` (ajoute au fichier
et crée les dossiers). Sauvegardes (restic, export USB, source de tirage, fichiers témoins) : tous les sites sont couverts.
Phase actuelle : dossiers, groupes et sauvegardes ; les services par domaine (SWAG, DNS, applications, mail) viennent ensuite.

## obligatoire : OBLIGATOIRE

- **DOMAIN** (texte, à renseigner) : Ton nom de domaine, servi par SWAG (enregistrements DNS A vers ton IP publique). Peut être un sous-domaine (ex. machin.ipassed.fr : cloud.machin.ipassed.fr, mail.machin.ipassed.fr...) ; voir DNS_ZONE_*. À CHANGER : tous les sous-domaines en dépendent. Défaut du script : ipassed.fr.
- **LE_EMAIL** (texte, à renseigner) : E-mail de contact Let's Encrypt (alertes d'expiration). Défaut : vide.
- **ROOT_PASSWORD** (texte, à renseigner) : Mot de passe root des VM/CT. Vide = demandé au lancement.
- **SAMBA_PASSWORD** (texte, à renseigner) : Mot de passe de l'utilisateur Samba « fileshare ». Vide = demandé.
- **DATA_DISK** (texte, à renseigner) : Disque ou grappe RAID (/dev/mdX, formatée en entier) à formater pour les données. Formaté QUE s'il ne porte pas déjà le label DATA. En interactif (sans fichier de réponses), l'installateur LISTE les disques et grappes détectés (disque système exclu, contenu affiché) et tu choisis ; ce fichier sert en mode automatique. Défaut : /dev/sdb.
- **DATA_PARTITION** (texte) : Partition créée/utilisée sur ce disque. Défaut : /dev/sdb1.
- **FORMAT_CONFIRMATION** (texte, à renseigner) : « FORMAT-YES » autorise le formatage sans question. Défaut : vide (demande).
- **DATA_EXISTING_DEVICE** (texte) : Volume ou RAID existant à réutiliser SANS formatage (ex. /dev/md0, /dev/sdb1). Vide = comportement habituel ; en interactif, le script détecte et demande.
- **DATA_MODE** (texte) : Stockage DATA : disk (disque ou grappe dédié, DATA_DISK, formaté après confirmation) | thin (DISQUE UNIQUE : DATA est un volume mince ext4 créé dans le thin pool de Proxmox, rien n'est formaté ; l'espace est partagé avec local-lvm). Défaut : disk.
- **GUEST_STORAGE** (texte) : Storage Proxmox des DISQUES des VM et CT créés : local-lvm (disque système, rapide, instantanés) | DATA (disque de données : épargne le disque système ; lent si disque dur) | autre storage acceptant « images » et « rootdir ». Les invités déjà créés ne sont pas déplacés. Défaut : local-lvm.
- **IMAGES_STORAGE** (texte) : Où stocker l'image cloud Debian, le pilote NVIDIA et les templates des CT : auto (DATA si GUEST_STORAGE=DATA, sinon local) | local (disque système) | DATA. Pour un serveur à très petit disque système : GUEST_STORAGE="DATA" (le reste suit). Snippets cloud-init (quelques Ko) restent sur local. Défaut : auto.

## services : SERVICES PRINCIPAUX

- **ENABLE_SWAG** (texte, à renseigner) : CT 101 : reverse proxy HTTPS + Let's Encrypt. États : keep (installe si absent, conserve) | run (existe déjà : applique SEULEMENT les paramètres du fichier, sans créer, supprimer, télécharger ni installer ; si tous les services actifs sont en run, les étapes d'installation de l'hôte sont aussi sautées ; absent = installé comme keep) | cleanup (supprime puis recrée) | remove (supprime) | skip (ne touche à rien) | vide (demande). Défaut du script : vide.
- **ENABLE_DOCKER** (texte, à renseigner) : VM 103 : Nextcloud, Sync-in, Immich, Home Assistant, Jellyfin. Mêmes états. Défaut : vide.
- **ENABLE_FILES** (texte, à renseigner) : VM 104 : Samba et Webmin. Mêmes états. Défaut : vide.
- **ENABLE_WIREGUARD** (texte, à renseigner) : CT 106 : VPN. Mêmes états. Défaut : vide.
- **ENABLE_XMRIG** (texte, à renseigner) : CT 105 : mineur Monero (voir §9). Mêmes états. Défaut : vide.
- **ENABLE_NODE** (texte, à renseigner) : CT 107 : Node.js + MongoDB (voir §6). Mêmes états. Défaut : skip.
- **ENABLE_MAIL** (texte, à renseigner) : CT 108 : serveur mail autonome (voir §6). Mêmes états. Défaut : skip.
- **ENABLE_DNS** (texte, à renseigner) : CT 109 : AdGuard Home, DNS filtrant (voir §6). Mêmes états. Défaut : skip.
- **ENABLE_MONITOR** (texte, à renseigner) : CT 110 : Uptime Kuma + ntfy + Homepage (voir §6). Mêmes états. Défaut : skip.
- **ENABLE_AI** (texte, à renseigner) : CT 111 : IA locale (Ollama + Open WebUI + OCR des PDF, sur le GPU NVIDIA de l'hôte). Mêmes états. Activation intelligente : RAM vérifiée, XMRig et machine-learning d'Immich bridés, modèles choisis selon la VRAM. Demande une carte NVIDIA (sinon CPU, très lent) et ≥ 8 Go de RAM libres. Défaut : skip.

## docker_apps : APPLICATIONS DE LA VM DOCKER

- **ENABLE_NEXTCLOUD** (true/false) : Nextcloud. Valeurs : true | false. Défaut : true.
- **ENABLE_SYNCIN** (true/false) : Sync-in. Valeurs : true | false. Défaut : true.
- **SYNCIN_ONLYOFFICE** (true/false) : Édition de documents dans Sync-in avec le serveur OnlyOffice (exige ENABLE_ONLYOFFICE=true). Installation existante : ./install.sh --run syncin_editors_apply. Défaut : false.
- **SYNCIN_COLLABORA** (true/false) : Édition de documents dans Sync-in avec Collabora Online (exige ENABLE_COLLABORA=true) ; peut être combiné avec SYNCIN_ONLYOFFICE. Installation existante : ./install.sh --run syncin_editors_apply. Défaut : false.
- **ENABLE_IMMICH** (true/false) : Immich (photos). Valeurs : true | false. Défaut : true.
- **ENABLE_HOMEASSISTANT** (true/false) : Home Assistant. Valeurs : true | false. Défaut : true.
- **ENABLE_JELLYFIN** (true/false) : Jellyfin. Valeurs : true | false. Défaut : true.
- **ENABLE_COLLABORA** (true/false) : Édition de documents dans Nextcloud (office.<domaine>) ; demande Nextcloud, SWAG et un enregistrement DNS A. Valeurs : true | false. Défaut : false.
- **ENABLE_ONLYOFFICE** (true/false) : Autre éditeur (onlyoffice.<domaine>), ~4 Go de RAM en plus ; peut coexister avec Collabora (./install.sh --run nextcloud_office_use collabora|onlyoffice). Défaut : false.
- **NEXTCLOUD_ADMIN_USER** (texte) : Administrateur Nextcloud. Défaut : admin.
- **NEXTCLOUD_ADMIN_PASSWORD** (texte) : Vide = généré et affiché à la fin.
- **NEXTCLOUD_DB_PASSWORD** (texte) : Mot de passe de la base Nextcloud. Vide = généré.
- **NEXTCLOUD_OPTIMIZE** (true/false) : Optimisation Nextcloud (Redis, cron, PHP). Défaut : true.
- **NEXTCLOUD_IMAGE_TAG** (texte) : Étiquette d'image. Vide = version majeure en cours (recommandé).
- **NEXTCLOUD_PHP_MEMORY_LIMIT** (texte) : Limite de mémoire PHP de Nextcloud (php.ini memory_limit). Défaut : 1024M.
- **NEXTCLOUD_UPLOAD_LIMIT** (texte) : Taille maximale d'un envoi de fichier dans Nextcloud (PHP_UPLOAD_LIMIT). Défaut : 16G.
- **NEXTCLOUD_PHONE_REGION** (texte) : Région par défaut des numéros de téléphone Nextcloud (code pays ISO, ex. FR). Défaut : FR.
- **NEXTCLOUD_MAINTENANCE_HOUR** (nombre) : Heure (0-23) de début de la fenêtre de maintenance des tâches lourdes de Nextcloud. Défaut : 1.
- **NEXTCLOUD_PREVIEW_MAX** (nombre) : Taille maximale (en pixels) des aperçus générés par Nextcloud. Défaut : 2048.
- **NEXTCLOUD_PHOTOS** (true/false) : Photos Nextcloud (Memories) pour comparer avec Immich. Défaut : false.
- **NEXTCLOUD_PHOTOS_USER** (texte) : Compte propriétaire des photos. Vide = administrateur.
- **NEXTCLOUD_PHOTOS_PATH** (texte) : Dossier de la bibliothèque dans ce compte. Défaut : /Photo.
- **NEXTCLOUD_RECOGNIZE** (true/false) : IA Recognize (visages, objets). Demande DOCKER_CPU_TYPE="host" et DOCKER_MEMORY="12288". Défaut : false.
- **RECOGNIZE_MODES** (texte) : Modes : faces objects landmarks audio video. Défaut : "faces objects".
- **RECOGNIZE_CORES** (nombre) : Nombre de cœurs utilisés par Recognize pour la classification. Défaut : 2.
- **DOCKER_CPU_TYPE** (texte) : Type de processeur de la VM Docker ("host" pour l'IA). Défaut : x86-64-v2-AES.
- **SYNCIN_ADMIN_LOGIN** (texte) : Administrateur Sync-in. Défaut : admin.
- **SYNCIN_ADMIN_PASSWORD** (texte) : Vide = généré.
- **SYNCIN_DB_PASSWORD** (texte) : Mot de passe de la base Sync-in. Vide = généré.
- **SYNCIN_DB_ROOT_PASSWORD** (texte) : Mot de passe root de la base Sync-in. Vide = généré.
- **SYNCIN_SECRET_1** (texte) : Secret interne Sync-in (1 à 4). Laisse vide pour qu'ils soient générés, jamais « change-me ».
- **SYNCIN_SECRET_2** (texte) : Idem (secret 2).
- **SYNCIN_SECRET_3** (texte) : Idem (secret 3).
- **SYNCIN_SECRET_4** (texte) : Idem (secret 4).
- **IMMICH_DB_PASSWORD** (texte) : Mot de passe de la base Immich. Vide = généré.
- **COLLABORA_SUBDOMAIN** (texte) : Sous-domaine(s) de Collabora : https://<nom>.<domaine>. Un ou plusieurs noms séparés par des espaces. Défaut : office.
- **ONLYOFFICE_SUBDOMAIN** (texte) : Sous-domaine(s) d'OnlyOffice (un ou plusieurs noms). Défaut : onlyoffice.
- **COLLABORA_DICTIONARIES** (texte) : Dictionnaires du correcteur orthographique (codes de langue séparés par des espaces). Défaut : `fr_FR en_GB`.
- **ONLYOFFICE_JWT_SECRET** (texte) : Secret JWT d'OnlyOffice. Vide = généré.

## reseau : RÉSEAU

- **HOST_NAME** (texte) : Nom d'hôte voulu pour ce serveur Proxmox. Vide = inchangé. Appliqué en tout premier, puis le script s'ARRÊTE : redémarre et relance. Refusé s'il existe déjà des VM/CT ou un cluster.
- **NODE_NAME** (texte) : Nom du nœud Proxmox. Défaut : hostname -s (calculé ; ne le fixe que cas particulier).
- **LAN_BRIDGE** (texte) : Pont relié à ta box (LAN). Défaut : vmbr0.
- **PRIVATE_BRIDGE** (texte) : Pont du réseau privé des VM/CT. Défaut : vmbr1.
- **LAN_IP** (texte) : IP LAN de l'hôte (redirections DNS et interfaces d'admin). Détectée sur LAN_BRIDGE ; à forcer si la détection se trompe (repli : 192.168.1.4). Défaut : `192.168.1.4`.
- **LAN_NET** (texte) : Réseau LAN (autorisations, DNS, pare-feu). Défaut : 192.168.1.0/24.
- **LAN_GW** (texte) : Passerelle du LAN (ta box). Défaut : 192.168.1.1.
- **HOST_IP** (texte) : État voulu de vmbr0 : « DHCP » ou une IP fixe. Vide = demandé en interactif. ATTENTION : un changement d'IP coupe la session SSH en cours.
- **PRIVATE_NET** (texte) : Réseau privé des VM/CT. Défaut : 10.10.10.0/24.
- **PRIVATE_GW** (texte) : Adresse de l'hôte sur le réseau privé : passerelle des CT/VM et cible du tirage via WireGuard. Défaut : 10.10.10.1.

## dns_zone : ZONE DNS À PUBLIER (fichier généré, jamais appliqué)

- **ENABLE_DNS_ZONE** (true/false) : Génère le fichier de zone (A, MX, SPF, DMARC, DKIM) d'après les services actifs, avec les changements depuis la dernière fois. Valeurs : true | false. Fichiers dans DNS_ZONE_DIR ; relance : ./install.sh --run dns_zone_generate. Défaut : `true`.
- **DNS_ZONE_DIR** (texte) : Dossier de sortie des fichiers de zone. Défaut : `/var/lib/homelab/dns-zone`.
- **DNS_ZONE_IP** (texte) : IP publique à publier. Vide = détectée (api.ipify.org) ; à fixer si introuvable.
- **DNS_ZONE_TTL** (nombre) : TTL des enregistrements en secondes. Défaut : 3600.
- **DNS_ZONE_PARENT** (texte) : Zone parente quand DOMAIN est un sous-domaine, ex. « ipassed.fr » pour DOMAIN=machin.ipassed.fr : génère aussi <DOMAIN>.parent.zone à ajouter dans la zone parente. Vide = pas de variante.

## admin_ssh : COMPTE ADMIN / SSH

- **ADMIN_USER** (texte, à renseigner) : Compte sudo non-root sur l'hôte (ex. « roland »). Vide = aucun compte.
- **ADMIN_PASSWORD** (texte, à renseigner) : Vide = généré et affiché (si le compte est créé).
- **ADMIN_SSH_KEY** (texte, à renseigner) : Clé publique SSH du compte (une ligne « ssh-ed25519 AAAA... » ou « ssh-rsa AAAA... »), recommandée. Pour l'obtenir, sur TON poste (Linux/macOS, ou PowerShell/Git Bash sous Windows) : ssh-keygen -t rsa -b 4096 -C "mail@gmail.com"  (alternative moderne : ssh-keygen -t ed25519 -C "mail@gmail.com"). Accepte l'emplacement proposé ; la phrase secrète est facultative mais conseillée. Deux fichiers sont créés dans ~/.ssh/ : id_rsa (clé PRIVÉE, à ne jamais partager ni coller ici) et id_rsa.pub (clé publique). Colle ici le TEXTE contenu dans le fichier .pub (affichable avec : cat ~/.ssh/id_rsa.pub), sur une seule ligne, entre guillemets. Vide = pas de clé, connexion par mot de passe seulement.
- **ADMIN_SUDO_NOPASSWD** (true/false) : true = sudo sans mot de passe. Défaut : false.
- **ADMIN_PVE_ACCESS** (true/false) : Le compte peut aussi se connecter à l'interface web Proxmox (realm Linux PAM, rôle Administrator). Défaut : true.
- **SSH_ROOT_LOGIN** (texte, à renseigner) : SSH direct de root. Valeurs : vide (inchangé) | no (interdit, exige ADMIN_USER utilisable, sinon refusé) | prohibit-password (clé seulement). Console et interface web non concernées ; un cluster a besoin du SSH root entre nœuds.
- **STORE_IMAGES** (true/false) : Garder les images téléchargées (image cloud Debian des VM, pilote NVIDIA) sur le disque de l'OS : téléchargées une seule fois, jamais réécrites ni retéléchargées aux lancements suivants (le téléchargement n'a lieu que si une VM doit réellement être créée). false = supprimées en fin d'installation (gain d'espace, retéléchargement à la prochaine création). Le template des CT est géré par Proxmox dans le même stockage. Valeurs : true | false. Défaut : true.
- **IMAGE_STORE_DIR** (texte) : Dossier de stockage des images téléchargées (disque de l'OS, stockage « local » de Proxmox). Défaut : /var/lib/vz/template/iso.
- **SSH_EXTERNAL** (true/false) : SSH depuis l'EXTÉRIEUR, pour la phase de développement (poste sans WireGuard). Ouvre un second port sshd (clé SSH uniquement, ADMIN_USER obligatoire avec ADMIN_SSH_KEY, jamais root ni mot de passe), fail2ban, notification de chaque connexion et FERMETURE AUTOMATIQUE après SSH_EXTERNAL_DAYS jours (0 = sans limite). La redirection du port sur la box est à faire à la main (et à retirer ensuite). Fermer : repasser à false ou ./install.sh --run ssh_external_off. Valeurs : true | false. Défaut : false.
- **SSH_EXTERNAL_PORT** (nombre) : Port TCP du SSH externe (1024-65535, pas 22) : à rediriger sur la box vers l'IP LAN de l'hôte, même port. Beaucoup de réseaux d'entreprise bloquent les ports inhabituels : en cas d'échec, essaie un port courant (ex. 8443). Défaut : 2244.
- **SSH_EXTERNAL_DAYS** (nombre) : Durée d'ouverture en jours (1 à 365), puis fermeture automatique ; 0 = SANS limite (rappel hebdomadaire). Notification quotidienne les 5 derniers jours ; prolonger : ./install.sh --ssh_external_expand <jours> (0 = sans limite). Relancer le script ne raccourcit pas une échéance déjà prolongée. Défaut : 7.
- **DISABLE_SUBSCRIPTION_NAG** (true/false) : Masque la fenêtre « No valid subscription » (annulable : apt reinstall proxmox-widget-toolkit). Défaut : true.

## wireguard : WIREGUARD

- **WG_PORT** (nombre) : Port UDP, à rediriger sur la box vers l'IP LAN de l'hôte. Défaut : 51820.
- **WG_ENDPOINT** (texte) : Nom ou IP publique donnés aux clients. Vide = DOMAIN.
- **WG_NET** (texte) : Réseau du VPN (obligatoirement un /24). Défaut : 10.10.20.0/24.
- **WG_SERVER_IP** (texte) : Adresse du serveur dans le tunnel (dans WG_NET). Défaut : 10.10.20.1.
- **ENABLE_TOR** (true/false) : Client Tor dans le CT WireGuard : active le profil VPN « tor » (tout le trafic du pair passe par le réseau Tor, rien d'autre ne sort : si Tor tombe, la connexion est coupée) et un proxy SOCKS5 Tor. Création d'un pair : ./install.sh --run wg_add_peer <nom> tor ; test : ./install.sh --run wg_test_tor. Défaut : true.
- **WG_TOR_SOCKS** (true/false) : Proxy SOCKS5 de Tor (socks5h://<IP du CT WireGuard>:9050) pour les VM/CT du réseau privé, et à l'adresse VPN du serveur pour les pairs du profil lan. Non accessible depuis Internet. Défaut : true.
- **WG_PEERS** (texte, à renseigner) : Pairs créés à l'installation, « nom:profil » séparés par des espaces (profils : lan, backup, internet, tor). Profils : lan (ton réseau) | backup (destinations et ports limités) | internet (tout le trafic). Ex. « pc:lan n54l:backup telephone:internet ». Défaut : `pc:lan`.
- **WG_DNS** (texte) : DNS des pairs « internet » ; remplacé par le CT DNS si ENABLE_DNS et DNS_FOR_WG. Défaut : `1.1.1.1, 9.9.9.9`.
- **WG_MTU** (nombre) : MTU du tunnel (à baisser si des connexions se bloquent). Défaut : 1420.
- **WG_UNPRIVILEGED** (nombre) : 1 = CT non privilégié ; 0 = privilégié si WireGuard refuse de démarrer. Défaut : 1.
- **WG_LAN_ROUTES** (texte) : Destinations du profil lan (CIDR séparés par des virgules). Vide = réseau privé des VM + IP LAN de l'hôte en /32.
- **WG_BACKUP_DESTS** (texte) : Destinations du profil backup (IP séparées par des virgules). Vide = VM FILES, plus l'hôte (PRIVATE_GW) si ENABLE_BACKUP_PULL=true.
- **WG_BACKUP_PORTS** (texte) : Ports TCP autorisés pour le profil backup. Défaut : 22,445.

## services_optionnels : SERVICES OPTIONNELS (CT)

- **NODE_SUBDOMAIN** (texte) : NODE : <nom>.<domaine> via SWAG (HTTPS) ; un ou plusieurs noms. Vide = pas de proxy SWAG. Défaut : web.
- **NODE_HTTP_PORT** (nombre) : NODE : port de l'application, aussi redirigé depuis l'IP LAN de l'hôte. Défaut : 3000.
- **MONGO_IMAGE** (texte) : NODE : image MongoDB ; « mongo:4.4 » si le CPU n'a pas AVX. Défaut : `mongo:8`.
- **MONGO_ADMIN_USER** (texte) : NODE : administrateur MongoDB. Défaut : admin.
- **MONGO_ADMIN_PASSWORD** (texte) : NODE : vide = généré et affiché.
- **MONGO_DB** (texte) : NODE : base de l'application d'exemple. Défaut : app.
- **NODE_MONGO_EXPOSE** (true/false) : NODE : true = MongoDB joignable sur le réseau privé (10.10.10.107:27017). Défaut : false.
- **MAIL_SUBDOMAIN** (texte) : MAIL : nom du serveur <nom>.<domaine> (MX, certificat, DNS inverse) ; plusieurs noms possibles (le premier sert de MX). Défaut : mail.
- **MAIL_ACCOUNTS** (texte) : MAIL : comptes créés (nom@<domaine>), « nom » ou « nom:mdp » séparés par des espaces. Sans mot de passe = généré. Vide = aucun. Défaut : `contact`.
- **MAIL_RELAY_HOST** (texte) : MAIL : relais SMTP pour l'envoi, ex. « [smtp-relay.brevo.com]:587 » si le port 25 sortant est bloqué ou si ça finit en spam. Vide = envoi direct.
- **MAIL_RELAY_USER** (texte) : MAIL : identifiant du relais.
- **MAIL_RELAY_PASSWORD** (texte) : MAIL : mot de passe du relais.
- **DNS_ADMIN_USER** (texte) : DNS : identifiant de l'interface AdGuard. Défaut : admin. (Mets l'IP LAN de l'hôte comme DNS dans la box ; ne redirige JAMAIS le port 53 de la box vers l'hôte.)
- **DNS_ADMIN_PASSWORD** (texte) : DNS : vide = généré, affiché et gardé dans le CT (/root/adguard-admin.pass).
- **DNS_VERSION** (texte) : DNS : « latest » ou version figée (ex. v0.107.57). Défaut : `latest`.
- **DNS_UPSTREAMS** (texte) : DNS : DNS amont chiffrés (DoH), séparés par des espaces. Défaut : `https://dns.quad9.net/dns-query https://cloudflare-dns.com/dns-query`.
- **DNS_BOOTSTRAP** (texte) : DNS : DNS en clair pour retrouver les serveurs amont. Défaut : `9.9.9.9 1.1.1.1`.
- **DNS_BLOCKLISTS** (texte) : DNS : listes en plus de celle d'AdGuard, au format « Nom|URL;Nom|URL ».
- **DNS_LOCAL_REWRITE** (true/false) : DNS : cloud.<domaine>, etc. résolus vers l'IP LAN de l'hôte pour les clients LAN/VPN. Défaut : true.
- **DNS_REWRITE_EXTRA** (texte) : DNS : autres noms à réécrire vers l'IP LAN de l'hôte, séparés par des espaces.
- **DNS_EXTRA_CLIENTS** (texte) : DNS : réseaux supplémentaires autorisés (CIDR, espaces) ; LAN, réseau privé et VPN le sont déjà.
- **DNS_FORWARD_LAN** (true/false) : DNS : redirige le port 53 (UDP/TCP) de l'IP LAN de l'hôte vers le CT. Défaut : true.
- **DNS_UI_PORT** (nombre) : DNS : interface sur http://<IP LAN hôte>:3080 ; vide = pas de redirection. Défaut : `3080`.
- **DNS_FOR_WG** (true/false) : DNS : les pairs VPN (profils lan et internet) utilisent ce DNS. Défaut : true.
- **MONITOR_KUMA** (true/false) : MONITOR : Uptime Kuma (disponibilité ; moniteurs à créer à la main). Défaut : true.
- **MONITOR_NTFY** (true/false) : MONITOR : ntfy, serveur de notifications. Défaut : true.
- **MONITOR_HOMEPAGE** (true/false) : MONITOR : Homepage, page d'accueil des services (réseau local). Défaut : true.
- **NTFY_SUBDOMAIN** (texte) : MONITOR : ntfy.<domaine> via SWAG pour les alertes hors du LAN ; un ou plusieurs noms. Vide = LAN/VPN seulement. Défaut : `ntfy`.
- **HOMEPAGE_SUBDOMAIN** (texte) : MONITOR : déconseillé, Homepage n'a pas d'authentification. Un ou plusieurs noms.
- **NTFY_ADMIN_USER** (texte) : MONITOR : administrateur ntfy. Défaut : admin.
- **NTFY_ADMIN_PASSWORD** (texte) : MONITOR : vide = généré et affiché.
- **ENABLE_CROWDSEC** (true/false, à renseigner) : CrowdSec devant SWAG (anti brute-force et scans). Valeurs : true | false. Défaut : false.
- **CROWDSEC_WHITELIST** (texte) : CrowdSec : réseaux/IP supplémentaires jamais bannis (CIDR, espaces).
- **ENABLE_ARR** (true/false, à renseigner) : Sonarr / Radarr / Prowlarr / qBittorrent dans la VM DOCKER (Prowlarr sans indexeur au départ). Défaut : false.
- **ARR_VPN** (true/false, à renseigner) : qBittorrent uniquement via VPN (gluetun, coupe-circuit). false = ton IP est visible. Défaut : true.
- **ARR_VPN_WG_CONF** (texte, à renseigner) : Chemin sur l'hôte du fichier WireGuard .conf de ton fournisseur VPN (ex. /root/vpn.conf) ; requis si ARR_VPN=true.
- **ARR_QBIT_USER** (texte) : Identifiant qBittorrent. Défaut : admin.
- **ARR_QBIT_PASSWORD** (texte) : Vide = généré (gardé dans la VM) et affiché.
- **ARR_PUID** (nombre) : UID des conteneurs arr. Défaut : 0.
- **ARR_PGID** (nombre) : GID des conteneurs arr (groupe de SHARED). Défaut : SHARED_GID (2000).
- **SONARR_PORT** (nombre) : Port Sonarr (LAN seulement). Défaut : 8989.
- **RADARR_PORT** (nombre) : Port Radarr (LAN seulement). Défaut : 7878.
- **PROWLARR_PORT** (nombre) : Port Prowlarr (LAN seulement). Défaut : 9696.
- **QBIT_PORT** (nombre) : Port qBittorrent (LAN seulement). Défaut : 8089.

## sauvegardes : SAUVEGARDES

- **ENABLE_BACKUP** (true/false, à renseigner) : Tâche vzdump quotidienne de toutes les VM/CT. Valeurs : true | false. Défaut du script : false.
- **BACKUP_STORAGE** (texte) : Storage Proxmox de destination (même disque que les données : prévoir une copie externe). Défaut : DATA.
- **BACKUP_SCHEDULE** (texte) : Heure du lancement (« HH:MM » ou « sun 01:00 »), à finir avant le tirage du N54L (3 h). Défaut : 01:00.
- **BACKUP_MODE** (texte) : snapshot | suspend | stop (stop arrête brièvement la VM/CT). Défaut : snapshot.
- **BACKUP_COMPRESS** (texte) : Compression vzdump (zstd, gzip, lzo, 0). Défaut : zstd.
- **BACKUP_KEEP** (texte) : Rotation des archives (options keep-* de vzdump). Défaut : `keep-daily=7,keep-weekly=4,keep-monthly=3`.
- **BACKUP_RESTIC_REPO** (texte) : Copie hors site chiffrée (restic). Vide = désactivée. Ex. sftp:utilisateur@10.10.20.5:/sauvegardes/homelab ou s3:s3.fr-par.scw.cloud/mon-bucket/homelab.
- **BACKUP_RESTIC_PASSWORD** (texte) : OBLIGATOIRE si le dépôt est défini ; à conserver ailleurs.
- **BACKUP_OFFSITE_PATHS** (texte) : Chemins envoyés hors site, séparés par des espaces. Vide = vzdump + données d'applications + SHARED.
- **BACKUP_OFFSITE_CRON** (texte) : Expression cron de la copie hors site. Défaut : tous les jours à 4 h 30.
- **BACKUP_OFFSITE_KEEP** (texte) : Rétention restic (options de « restic forget »). Défaut : `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
- **ENABLE_BACKUP_PULL** (true/false, à renseigner) : Accès LECTURE SEULE pour le serveur de sauvegarde N54L qui tire les données (rrsync -ro sur DATA_MOUNT, compte sans root). backup_source_export l'active seul. Défaut : false.
- **BACKUP_PULL_USER** (texte) : Compte système dédié au tirage (sans mot de passe). Défaut : backup-pull.
- **BACKUP_PULL_PUBKEY** (texte, à renseigner) : Clé publique du N54L : le TEXTE contenu dans le fichier .pub généré sur le N54L (cat /root/.ssh/homelab-pull.pub ; créée par : ssh-keygen -t ed25519 -f /root/.ssh/homelab-pull -C "homelab-pull"). Ne jamais coller la clé privée (fichier sans .pub). Peut rester vide si les clés viennent de backup_source_export.
- **BACKUP_PULL_FROM** (texte) : Vide = toute IP ; sinon IP/plage autorisée. La clé reste en lecture seule.
- **BACKUP_CANARY** (true/false) : Fichiers témoins docx/jpg/avi surveillés par le N54L pour détecter une altération. Défaut : true.
- **ENABLE_BACKUP_USB** (true/false, à renseigner) : Export vers un disque USB portant le fichier marqueur ; un disque sans marqueur n'est jamais touché. Défaut : false.
- **BACKUP_USB_MARKER** (texte) : Nom du fichier marqueur à créer à la racine du disque. Défaut : `HOMELAB-BACKUP`.
- **BACKUP_USB_CONTENT** (texte) : Contenu exporté (combinable) : dump (vzdump) | apps (dossiers d'applications) | shared (partage Samba). Modifiable dans le marqueur. Défaut : `dump apps`.
- **BACKUP_USB_KEEP** (nombre) : Nombre d'exports conservés sur le disque. Défaut : 2.
- **BACKUP_USB_WEBHOOK** (texte) : URL ntfy facultative pour être prévenu ; sinon journal + message console.
- **BACKUP_USB_ALLOWED_UUIDS** (texte) : UUID de disques autorisés (espaces). Vide = tout disque USB avec marqueur.

## maintenance : MAINTENANCE AUTOMATIQUE

- **ENABLE_HEALTH** (true/false) : Alertes SMART, disques, RAID, services, sauvegardes (toutes les 10 min). Défaut : true.
- **POOL_GUARD** (true/false) : Garde-fou de stockage : quand un thin pool LVM (données ou métadonnées) ou le volume DATA atteint POOL_GUARD_PCT, arrête les sauvegardes en cours puis TOUTES les VM et CT, coupe leur démarrage automatique et notifie. Rien ne redémarre seul : ménage puis « sudo homelab-pool-guard --resume ». Défaut : true.
- **POOL_GUARD_PCT** (nombre) : Seuil du garde-fou en % (50 à 99). Réarmement automatique 5 points plus bas. Défaut : 98.
- **HEALTH_DISK_PCT** (nombre) : Alerte si un disque/storage dépasse ce pourcentage. Défaut : 90.
- **HEALTH_BACKUP_MAX_H** (nombre) : Alerte si la dernière sauvegarde vzdump a plus de N heures. Défaut : 36.
- **HEALTH_DISK_STEP** (nombre) : Alerte à CHAQUE palier de remplissage franchi (tous les N %, à la montée ; retour en dessous signalé avec 2 % de marge). 0 = désactivé. Défaut : 10.
- **ENABLE_TELEGRAM** (true/false, à renseigner) : Alertes Telegram + bot de questions (/cpu /memoire /stockage /invites /status, lecture seule). Étapes : @BotFather > /newbot (jeton), écris à ton bot, ./install.sh --run telegram_chat_id, puis ./install.sh --run configure_notify. Défaut : false.
- **TELEGRAM_BOT_TOKEN** (texte) : Jeton du bot donné par @BotFather (ex. 123456789:AAAA...). À garder secret.
- **TELEGRAM_CHAT_ID** (texte) : Identifiant(s) numérique(s) de discussion AUTORISÉS, séparés par des espaces ou virgules : le bot ignore tout autre. Obtenu par ./install.sh --run telegram_chat_id.
- **TELEGRAM_ALERTS** (texte) : Catégories envoyées sur Telegram, séparées par des espaces : miner (mineur arrêté/relancé par la charge CPU) | disk (palier de stockage) | usb (disque USB branché, export) | backup (sauvegarde vzdump : début et fin détaillée) | system (serveur démarré) | network (IP publique modifiée) | security (action Telegram exécutée ou code refusé) | health (problèmes de la surveillance) | smart (disques) | all. Défaut : `miner disk usb backup system network security`.
- **TELEGRAM_ADMIN_ID** (texte) : Identifiant Telegram de l'UNIQUE personne autorisée à lancer des actions (discussion privée avec le bot uniquement). Vide = aucune action possible. Obtenu par ./install.sh --run telegram_chat_id.
- **TELEGRAM_ACTIONS** (texte) : Groupes d'actions autorisés depuis Telegram, séparés par des espaces : backup (/sauvegarder /dumpbases /testrestauration) | guests (/invite_demarrer /invite_arreter /invite_redemarrer) | host (/hote_redemarrer /hote_eteindre). Vide (défaut) = bot en lecture seule. Chaque action exige un code à usage unique (TOTP) de ton application d'authentification : ./install.sh --run telegram_totp_show affiche le secret.
- **TELEGRAM_ACTION_DELAY** (nombre) : Secondes d'attente avant l'arrêt ou le redémarrage de l'hôte demandé par Telegram ; /annuler l'interrompt pendant ce délai. Défaut : 60.
- **HEALTH_PUBLIC_IP** (true/false) : Alerte (catégorie network) quand l'IP publique change : zone DNS, tunnel WireGuard et serveur de sauvegarde à mettre à jour. Défaut : true.
- **NOTIFY_NTFY_URL** (texte) : Serveur ntfy. Vide = ntfy du CT MONITOR s'il existe ; sinon une URL (ex. https://ntfy.sh).
- **NOTIFY_NTFY_TOPIC** (texte) : Sujet ntfy des alertes. Défaut : homelab.
- **NOTIFY_NTFY_TOKEN** (texte) : Jeton d'accès ntfy (créé automatiquement avec le CT MONITOR).
- **NOTIFY_KUMA_PUSH_URL** (texte) : URL d'un moniteur « Push » d'Uptime Kuma : battement de cœur de l'hôte.
- **ENABLE_DB_DUMP** (true/false) : Dump logique des bases avant chaque sauvegarde (dans APPS_DIR/backups/db/). Défaut : true.
- **DB_DUMP_KEEP** (nombre) : Dumps conservés par base. Défaut : 7.
- **ENABLE_RESTORE_TEST** (true/false) : Test de restauration mensuel. Défaut : true.
- **RESTORE_TEST_CALENDAR** (texte) : OnCalendar systemd : le 2 de chaque mois à 5 h 30. Défaut : `*-*-02 05:30:00`.
- **RESTORE_TEST_ID** (nombre) : ID libre du CT temporaire de test. Défaut : 990.
- **RESTORE_TEST_STORAGE** (texte) : Storage où restaurer temporairement le CT. Vide = GUEST_STORAGE. Défaut : vide.
- **RESTORE_TEST_VERIFY_VM** (true/false) : true = lit en entier les archives de VM (long) ; false = présence et âge seulement. Défaut : `true`.
- **DOCKER_UPDATE_MODE** (texte, à renseigner) : Mises à jour des images Docker. off | notify (signale) | safe (applique les projets sûrs, signale les autres). Défaut : notify.
- **DOCKER_UPDATE_CALENDAR** (texte) : OnCalendar systemd de la vérification (samedi 5 h). Défaut : `Sat *-*-* 05:00:00`.

## xmrig : XMRIG (si ENABLE_XMRIG)

- **XMRIG_WALLET** (texte) : Adresse de portefeuille Monero : à renseigner pour être crédité.
- **XMRIG_POOL** (texte) : Pool de minage « hôte:port ». Défaut : `xmrpool.eu:5555`.
- **XMRIG_CORES** (nombre) : Cœurs du CT. Défaut : nproc - 1 (min. 1), calculé ; XMRig plafonne de toute façon selon le cache L3.
- **XMRIG_MEMORY** (nombre) : Mémoire du CT en Mo. Défaut : 4096.
- **XMRIG_VERSION** (texte) : Version téléchargée sur GitHub (met à jour XMRIG_SHA256_FALLBACK si tu la changes). Défaut : `6.26.0`.
- **XMRIG_SHA256_FALLBACK** (texte) : SHA-256 de secours, utilisé seulement si SHA256SUMS est injoignable (le hash officiel est toujours tenté d'abord). Défaut : `fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5`.
- **XMRIG_STOP_THRESHOLD** (nombre) : Suspend le minage si la charge CPU dépasse ce %. Défaut : 25.
- **XMRIG_RESUME_THRESHOLD** (nombre) : Reprend sous ce % de charge. Défaut : 20.
- **XMRIG_RESUME_DELAY** (nombre) : Secondes sous le seuil avant de reprendre. Défaut : 300.
- **XMRIG_MONITOR_INTERVAL** (nombre) : Secondes entre deux mesures de charge. Défaut : 5.
- **HUGEPAGES_COUNT** (nombre) : Pages mémoire réservées (accélèrent RandomX). Défaut : 1280.
- **HUGEPAGES_MOUNT** (texte) : Point de montage des HugePages. Défaut : `/mnt/huge`.

## avance : AVANCÉ (rarement utile) : identifiants, adresses, ressources, montages, ports

- **FILES_ID** (nombre) : VM FILES : identifiant Proxmox. Défaut : 104.
- **FILES_HOSTNAME** (texte) : VM FILES : nom d'hôte. Défaut : files.
- **FILES_IP** (texte) : VM FILES : adresse IPv4 en CIDR. Défaut : 10.10.10.104/24.
- **FILES_GATEWAY** (texte) : VM FILES : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **FILES_CORES** (nombre) : VM FILES : cœurs. Défaut : 2.
- **FILES_MEMORY** (nombre) : VM FILES : mémoire en Mo. Défaut : 2048.
- **FILES_DISK** (texte) : VM FILES : taille du disque. Défaut : 32G.
- **DOCKER_ID** (nombre) : VM DOCKER (8192 avec OnlyOffice) : identifiant Proxmox. Défaut : 103.
- **DOCKER_HOSTNAME** (texte) : VM DOCKER (8192 avec OnlyOffice) : nom d'hôte. Défaut : docker.
- **DOCKER_IP** (texte) : VM DOCKER (8192 avec OnlyOffice) : adresse IPv4 en CIDR. Défaut : 10.10.10.103/24.
- **DOCKER_GATEWAY** (texte) : VM DOCKER (8192 avec OnlyOffice) : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **DOCKER_CORES** (nombre) : VM DOCKER (8192 avec OnlyOffice) : cœurs. Défaut : 2.
- **DOCKER_MEMORY** (nombre) : VM DOCKER (8192 avec OnlyOffice) : mémoire en Mo. Défaut : 4096.
- **DOCKER_DISK** (texte) : VM DOCKER : taille du disque (images Docker + bases + miniatures : 32G se remplit, Immich/Postgres tombent alors en erreur 500). Agrandir ensuite : ./install.sh --run docker_disk_grow 32G. Défaut : 64G.
- **SWAG_ID** (nombre) : CT SWAG : identifiant Proxmox. Défaut : 101.
- **SWAG_HOSTNAME** (texte) : CT SWAG : nom d'hôte. Défaut : swag.
- **SWAG_IP** (texte) : CT SWAG : adresse IPv4 en CIDR. Défaut : 10.10.10.16/24.
- **SWAG_GATEWAY** (texte) : CT SWAG : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **SWAG_CORES** (nombre) : CT SWAG : cœurs. Défaut : 1.
- **SWAG_MEMORY** (nombre) : CT SWAG : mémoire en Mo. Défaut : 512.
- **SWAG_DISK** (texte) : CT SWAG : taille du disque. Défaut : 8G.
- **WG_ID** (nombre) : CT WireGuard : identifiant Proxmox. Défaut : 106.
- **WG_HOSTNAME** (texte) : CT WireGuard : nom d'hôte. Défaut : wireguard.
- **WG_IP** (texte) : CT WireGuard : adresse IPv4 en CIDR. Défaut : 10.10.10.106/24.
- **WG_GATEWAY** (texte) : CT WireGuard : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **WG_CORES** (nombre) : CT WireGuard : cœurs. Défaut : 1.
- **WG_MEMORY** (nombre) : CT WireGuard : mémoire en Mo. Défaut : 256.
- **WG_DISK** (texte) : CT WireGuard : taille du disque. Défaut : 2G.
- **NODE_ID** (nombre) : CT NODE : identifiant Proxmox. Défaut : 107.
- **NODE_HOSTNAME** (texte) : CT NODE : nom d'hôte. Défaut : node.
- **NODE_IP** (texte) : CT NODE : adresse IPv4 en CIDR. Défaut : 10.10.10.107/24.
- **NODE_GATEWAY** (texte) : CT NODE : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **NODE_CORES** (nombre) : CT NODE : cœurs. Défaut : 2.
- **NODE_MEMORY** (nombre) : CT NODE : mémoire en Mo. Défaut : 2048.
- **NODE_DISK** (texte) : CT NODE : taille du disque. Défaut : 16G.
- **MAIL_ID** (nombre) : CT MAIL : identifiant Proxmox. Défaut : 108.
- **MAIL_HOSTNAME** (texte) : CT MAIL : nom d'hôte. Défaut : mail.
- **MAIL_IP** (texte) : CT MAIL : adresse IPv4 en CIDR. Défaut : 10.10.10.108/24.
- **MAIL_GATEWAY** (texte) : CT MAIL : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **MAIL_CORES** (nombre) : CT MAIL : cœurs. Défaut : 2.
- **MAIL_MEMORY** (nombre) : CT MAIL : mémoire en Mo. Défaut : 1536.
- **MAIL_DISK** (texte) : CT MAIL : taille du disque. Défaut : 8G.
- **DNS_ID** (nombre) : CT DNS : identifiant Proxmox. Défaut : 109.
- **DNS_HOSTNAME** (texte) : CT DNS : nom d'hôte. Défaut : dns.
- **DNS_IP** (texte) : CT DNS : adresse IPv4 en CIDR. Défaut : 10.10.10.109/24.
- **DNS_GATEWAY** (texte) : CT DNS : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **DNS_CORES** (nombre) : CT DNS : cœurs. Défaut : 1.
- **DNS_MEMORY** (nombre) : CT DNS : mémoire en Mo. Défaut : 256.
- **DNS_DISK** (texte) : CT DNS : taille du disque. Défaut : 2G.
- **MONITOR_ID** (nombre) : CT MONITOR : identifiant Proxmox. Défaut : 110.
- **MONITOR_HOSTNAME** (texte) : CT MONITOR : nom d'hôte. Défaut : monitor.
- **MONITOR_IP** (texte) : CT MONITOR : adresse IPv4 en CIDR. Défaut : 10.10.10.110/24.
- **MONITOR_GATEWAY** (texte) : CT MONITOR : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **MONITOR_CORES** (nombre) : CT MONITOR : cœurs. Défaut : 2.
- **MONITOR_MEMORY** (nombre) : CT MONITOR : mémoire en Mo. Défaut : 1024.
- **MONITOR_DISK** (texte) : CT MONITOR : taille du disque. Défaut : 8G.
- **XMRIG_ID** (nombre) : CT XMRIG : identifiant Proxmox. Défaut : 105.
- **XMRIG_HOSTNAME** (texte) : CT XMRIG : nom d'hôte. Défaut : xmrig.
- **XMRIG_IP** (texte) : CT XMRIG : adresse IPv4 en CIDR. Défaut : 10.10.10.105/24.
- **XMRIG_GATEWAY** (texte) : CT XMRIG : passerelle (l'hôte sur le réseau privé). Défaut : 10.10.10.1.
- **XMRIG_DISK** (texte) : CT XMRIG : taille du disque. Défaut : 8G.
- **DATA_THIN_POOL** (texte) : Mode thin : thin pool LVM (VG/LV) qui héberge le volume DATA. Défaut : pve/data.
- **DATA_THIN_LV** (texte) : Mode thin : nom du volume DATA créé dans le pool. Défaut : datafs.
- **DATA_LV_SIZE** (texte) : Mode thin : taille VIRTUELLE du volume DATA, « NN% » de la taille du pool ou valeur absolue (2T). Le volume ne prend que ce qu'il contient réellement ; df affiche cette taille virtuelle, pas la place réelle (voir lvs). Défaut : 90%.
- **DATA_TRIM** (true/false) : Active fstrim.timer sur l'hôte (passage hebdomadaire) : rend au thin pool l'espace des fichiers supprimés. Défaut : true.
- **DATA_MOUNT** (texte) : Point de montage du disque DATA. Défaut : /mnt/data.
- **SHARED_DIR** (chemin) : Dossier du partage Samba. Défaut : ${DATA_MOUNT}/SHARED.
- **PROXMOX_DATA_DIR** (chemin) : Dossier des sauvegardes vzdump. Défaut : ${DATA_MOUNT}/proxmox.
- **SHARED_GROUP** (texte) : Groupe propriétaire du partage. Défaut : fileshare.
- **SHARED_GID** (nombre) : GID de ce groupe (aussi utilisé par les conteneurs). Défaut : 2000.
- **VIRTIOFS_DIR_ID** (texte) : Identifiant VirtioFS de SHARED. Défaut : files_shared.
- **APPS_DIR** (chemin) : Données d'applications HORS Samba (Immich, Nextcloud, Sync-in, mail, dumps de bases). Défaut : ${DATA_MOUNT}/apps.
- **APPS_VIRTIOFS_DIR_ID** (texte) : Identifiant du 2e VirtioFS (APPS_DIR). Défaut : apps_data.
- **FILES_MOUNT** (texte) : Montage de SHARED dans la VM FILES. Défaut : /srv/data.
- **FILES_SAMBA_SHARE** (texte) : Nom du partage Samba. Défaut : SHARED.
- **DOCKER_SHARED_MOUNT** (texte) : Montage de SHARED dans la VM DOCKER. Défaut : /srv/data.
- **DOCKER_APPS_MOUNT** (texte) : Montage d'APPS_DIR dans la VM DOCKER. Défaut : /srv/apps.
- **DOCKER_APPS_UID** (nombre) : UID des conteneurs d'applications. Défaut : 1000.
- **DOCKER_APPS_GID** (nombre) : GID des conteneurs d'applications. Défaut : SHARED_GID.
- **SWAG_CERT_BACKUP** (texte) : Sauvegarde des certificats Let's Encrypt (évite la limite de 5 certificats identiques par semaine). Défaut : `/var/lib/homelab/swag-letsencrypt.tgz`.
- **NEXTCLOUD_SUBDOMAIN** (texte) : Sous-domaine(s) de Nextcloud : https://<nom>.<domaine>. UN OU PLUSIEURS noms séparés par des espaces (ex. "cloud nuage") : le premier est le nom principal, tous ont leur DNS, figurent dans le certificat Let's Encrypt et sont servis par SWAG. Un nom ne peut servir qu'à un seul service. Appliquer à une installation existante : ./install.sh --run repair_swag_subdomains. Défaut : cloud.
- **SYNCIN_SUBDOMAIN** (texte) : Sous-domaine(s) de Sync-in (même règle que NEXTCLOUD_SUBDOMAIN : un ou plusieurs noms). Défaut : sync.
- **IMMICH_SUBDOMAIN** (texte) : Sous-domaine(s) d'Immich (photos). Un ou plusieurs noms ; le premier est le principal. Défaut : "photos photo".
- **JELLYFIN_SUBDOMAIN** (texte) : Sous-domaine(s) de Jellyfin (actif si ENABLE_JELLYFIN). Un ou plusieurs noms, ex. "media movies". Défaut : media.
- **ENABLE_PORTAL** (true/false) : Portail : page d'accueil unique (https://<PORTAL_SUBDOMAIN>.<domaine>) avec un lien vers chaque service installé. Demande SWAG et un enregistrement DNS A. Valeurs : true | false. Défaut : true.
- **PORTAL_SUBDOMAIN** (texte) : Sous-domaine(s) du portail. Un ou plusieurs noms. Avec le DNS interne (AdGuard), le même nom marche en local et depuis Internet. Défaut : home.
- **PORTAL_TITLE** (texte) : Titre affiché en haut du portail. Défaut : Mon serveur.
- **PORTAL_AUTH** (texte) : Mot de passe du portail : public = demandé seulement depuis Internet (libre en réseau local/VPN) | all = partout | none = jamais. Défaut : public.
- **PORTAL_USER** (texte) : Utilisateur du mot de passe du portail. Défaut : admin.
- **PORTAL_PASSWORD** (texte) : Mot de passe du portail. Vide = généré et affiché dans le résumé (puis conservé dans le fichier de secrets).
- **PORTAL_LOCAL_PORT** (nombre) : Accès de secours sans DNS : http://<IP LAN hôte>:<port> (vue réseau local). Ne pas rediriger ce port depuis la box. Défaut : 8088.
- **AI_CORES** (nombre) : Cœurs du CT IA. Défaut : la moitié des cœurs de l'hôte (minimum 2).
- **AI_MEMORY** (nombre) : RAM du CT IA en Mo. Réduite automatiquement si les autres modules activés en laissent moins (minimum 8192, sinon l'installation s'arrête sauf AI_FORCE=true). Défaut : 16384.
- **AI_DISK** (texte) : Disque du CT IA (modèles de plusieurs Go chacun). Défaut : 120G.
- **AI_RAM_RESERVE** (nombre) : RAM (Mo) laissée à l'hôte Proxmox dans le calcul du budget. Défaut : 3072.
- **AI_FORCE** (true/false) : Installer l'IA même si la RAM disponible est insuffisante (risque de saturation). Valeurs : true | false. Défaut : false.
- **AI_GPU** (texte) : GPU NVIDIA : auto (détecté avec lspci) | true (exige la carte) | false (CPU seulement). Défaut : auto.
- **AI_NVIDIA_SOURCE** (texte) : Pilote NVIDIA de l'hôte : debian (paquets Debian non-free + DKMS) | run (installateur officiel NVIDIA, version AI_NVIDIA_VERSION ; versions hôte et CT identiques). Si debian échoue avec ton noyau, essaie run. Désactive Secure Boot dans le BIOS. Défaut : debian.
- **AI_NVIDIA_VERSION** (texte) : Version du pilote pour AI_NVIDIA_SOURCE=run (ex. 580.95.05). Défaut : vide.
- **AI_VRAM_MB** (texte) : VRAM en Mo, seulement si elle n'est pas lisible avant le premier redémarrage (une 3060 = 12288). Défaut : vide (hypothèse 12000).
- **AI_MODEL_CHAT** (texte) : Modèle de discussion Ollama. Vide = choisi selon la VRAM (≥ 20 Go : qwen2.5:32b, ≥ 10 Go : qwen2.5:14b, ≥ 6 Go : 7b, sinon 3b). Défaut : vide.
- **AI_MODEL_CODE** (texte) : Modèle de code Ollama. Vide = qwen2.5-coder à la taille choisie selon la VRAM. Défaut : vide.
- **AI_MODEL_EMBED** (texte) : Modèle d'embeddings (recherche dans les documents, multilingue). Défaut : bge-m3.
- **AI_MODEL_AUTOCOMPLETE** (texte) : Petit modèle rapide pour l'autocomplétion dans VS Code. Défaut : qwen2.5-coder:1.5b.
- **AI_KEEP_ALIVE** (texte) : Délai avant de libérer la VRAM après la dernière requête. Défaut : 5m.
- **AI_CONTEXT** (nombre) : Taille de contexte des modèles (jetons) ; plus grand = plus de VRAM. Défaut : 8192.
- **AI_WEB_PORT** (nombre) : Port d'Open WebUI : http://<IP LAN hôte>:8090 (LAN uniquement, ne pas rediriger depuis la box). Défaut : 8090.
- **AI_API_PORT** (nombre) : Port de l'API Ollama. Défaut : 11434.
- **AI_API_LAN** (true/false) : Rediriger l'API Ollama sur l'IP LAN de l'hôte (pour VS Code). Elle n'a PAS de mot de passe : réseau local uniquement. Valeurs : true | false. Défaut : true.
- **AI_WEBUI_NAME** (texte) : Nom affiché par Open WebUI. Défaut : Assistant.
- **AI_WEBUI_EMAIL** (texte) : E-mail du compte administrateur Open WebUI. Vide = LE_EMAIL.
- **AI_WEBUI_PASSWORD** (texte) : Mot de passe administrateur Open WebUI. Vide = généré et affiché dans le résumé.
- **AI_DOCS_DIR** (chemin) : Dossier des documents à indexer (normes en PDF, même scannés), accessible par Samba. OCR et indexation automatiques toutes les 15 minutes. Défaut : SHARED/IA/Normes.
- **AI_OCR** (true/false) : OCR des PDF scannés (ocrmypdf) avant indexation. Valeurs : true | false. Défaut : true.
- **AI_OCR_LANG** (texte) : Langues de l'OCR (codes Tesseract). Défaut : fra+eng.
- **AI_INGEST** (true/false) : Envoyer automatiquement les documents dans la base de connaissances d'Open WebUI. Valeurs : true | false. Défaut : true.
- **AI_COLLECTION** (texte) : Nom de la base de connaissances Open WebUI. Défaut : Normes.
- **AI_BACKUP** (true/false) : Inclure le CT IA dans les sauvegardes vzdump (lourd à cause des modèles). Valeurs : true | false. Défaut : false.
- **AI_ID** (nombre) : Identifiant Proxmox du CT IA. Défaut : 111.
- **AI_IP** (texte) : IP du CT IA. Défaut : 10.10.10.111/24.
- **NEXTCLOUD_HTTP_PORT** (nombre) : Port HTTP interne de Nextcloud (accès LAN ; ne le redirige pas depuis la box). Défaut : 8081.
- **SYNCIN_HTTP_PORT** (nombre) : Port Sync-in. Défaut : 6060.
- **IMMICH_HTTP_PORT** (nombre) : Port Immich. Défaut : 2283.
- **HOMEASSISTANT_HTTP_PORT** (nombre) : Port Home Assistant. Défaut : 8123.
- **JELLYFIN_HTTP_PORT** (nombre) : Port Jellyfin. Défaut : 8096.
- **COLLABORA_HTTP_PORT** (nombre) : Port Collabora. Défaut : 9980.
- **ONLYOFFICE_HTTP_PORT** (nombre) : Port OnlyOffice. Défaut : 8082.
- **KUMA_PORT** (nombre) : Port Uptime Kuma (redirigé depuis l'IP LAN, LAN seulement). Défaut : 3001.
- **HOMEPAGE_PORT** (nombre) : Port Homepage. Défaut : 3002.
- **NTFY_PORT** (nombre) : Port ntfy. Défaut : 8085.
- **DEBIAN_IMAGE_URL** (texte) : Image cloud Debian 13 des VM. Défaut : `https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2`.
- **DEBIAN_IMAGE_DIR** (chemin) : Dossier de stockage de l'image. Défaut : `${IMAGE_STORE_DIR}`.
- **DEBIAN_IMAGE** (chemin) : Chemin complet de l'image. Défaut : `${DEBIAN_IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2`.
- **LOG_FILE** (texte) : Journal de l'installation. Défaut : /var/log/proxmox-homelab-install-<version>.log.

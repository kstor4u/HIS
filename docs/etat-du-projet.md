# Homelab Proxmox : état du projet (Proxmox v2.61.0 + serveur de sauvegarde N54L v2.0.0, 22 nov 2026)

## Ce qu'est ce projet
Installateur bash pour un homelab Proxmox. Fichier de réponses : `proxmox-homelab-answers.json` (JSON groupé par section, depuis v2.56.0 ; avant : `.conf` bash). Secrets générés : `proxmox-homelab-secrets.json` (depuis v2.54.17, JSON depuis v2.56.0). Documentation des variables : `proxmox-homelab-variables.md` ou `./install.sh --describe`. Le script complet courant est `homelab-install-courant.sh` (sa version est dans SCRIPT_VERSION). Attention : `project_read` tronque ce gros fichier à l'affichage, mais renvoie aussi un chemin local (`local_file`) lisible en entier ; si la réponse n'en donne pas, relancer `project_read`. Pour le modifier : copier dans le dossier de travail, patcher, puis `project_write` avec `local_path`.
Deuxième produit : le **serveur de sauvegarde N54L** (tirage), son propre installateur `backup-server-install.sh` (voir la section dédiée).

## Fichiers du projet (tout est ici, un seul endroit)
- `homelab-install-courant.sh` : **référence unique** (monolithe Proxmox de la dernière version).
- `split-modules.py` : **découpe le monolithe en modules (et le reconstruit)**, voir « Travail en modules ». Contient la table des modules (MODULES). Il n'est pas dans le dossier de travail au départ : `project_read` renvoie son contenu en ligne, le réécrire dans un fichier.
- `proxmox-homelab-answers.json.example` et `proxmox-homelab-variables.md` : fichier de réponses neuf et documentation des variables, **générés** par `./install.sh --init-answers` (à régénérer quand une variable change ; hors Proxmox, un faux `ip` no-op dans le PATH est nécessaire). L'exemple publié = le fichier généré + une section `sites` de démonstration (`jq '.sites = {...}'`).
- Pas de patchs dans le projet (supprimés le 19 nov) : le monolithe fait foi, l'historique est dans la section ci-dessous.
- `homelab-carte-modules.md` : carte des modules (fonctions et lignes), **générée** par `split-modules.py` (`python3 -I split-modules.py map <dossier>`), à régénérer à chaque livraison.
- Serveur de sauvegarde N54L : `backup-server-install.sh` (installateur autonome, archive intégrée), `backup-server-README.md`, `backup-server-backup.json.example` (réglages, généré), `backup-server-source.json.example` (une source), `backup-server-build.py` (reconstruit l'installateur depuis l'arbre).
- `homelab-etat.md` : ce document.
- Les ZIP ne sont pas acceptés par les projets : les zip modulaires ne sont donnés qu'à l'utilisateur.

## Travail en modules (méthode, depuis le 13 nov 2026)
Les modules ne sont pas stockés : ils se régénèrent en une seconde, à l'identique, à partir du monolithe.
1. `python3 -I split-modules.py split homelab-install-courant.sh modulaire` : crée `modulaire/` (modules, MANIFEST, `install.sh`, `build.sh`, `MAP.md`) et vérifie que le rebuild redonne le monolithe **octet pour octet**.
2. Lire `MAP.md` (~15 Ko) puis **seulement** le(s) module(s) concernés (`sed -n`/grep), jamais le monolithe entier (700 Ko). Modifier les modules (patch Python ou Edit).
3. `./build.sh > proxmox-homelab-install-vX.Y.Z.sh` (puis `chmod +x`) ; test : `bash -n`, et `./install.sh --version|--help|--update-answers` (nécessite un faux `ip` dans le PATH hors Proxmox ; un faux `setfacl` no-op aide pour la création des dossiers).
4. Livrer : monolithe + `proxmox-homelab-modulaire.zip` (modulaire/ + `split-modules.py`) ; publier dans le projet le monolithe, `split-modules.py` si MODULES a changé, la carte régénérée et ce document.
- **Nouveau module** : l'ajouter à `MODULES` dans `split-modules.py` avec le titre de sa bannière d'ouverture (`####` / `# TITRE #` / `####`, titre unique), à sa place dans l'ordre de chargement ; il doit être contigu dans le monolithe. Un titre de bannière renommé doit l'être aussi dans MODULES (le script s'arrête avec un message clair sinon).
- Les messages d'erreur du mode modulaire citent le module et la ligne (`main.sh: line 177`) ; le monolithe cite une ligne dans le fichier entier.
- **Ajouter une variable** : la définir avec son défaut dans `core/00-config.sh`, puis ajouter UNE ligne `V^groupe^NOM^type^requis^init^défaut^description` dans `core/04-answers-schema.sh` (source unique : fichier JSON neuf, documentation, `--describe`, fusion `--update-answers`). Valeur calculée par machine : défaut « (calculé) ».
- Jamais de `log`/`info`/`die` dans `core/04` et `core/05` (chargés avant la journalisation : `--update-answers`, `--init-answers`, `--describe` tournent sans root ni Proxmox).
- **Tester des fonctions hors Proxmox** : sourcer `core/00-config.sh`, `core/35-subdomains.sh` et le module voulu avec un faux `ip` ; pour les fonctions qui parlent à une VM (`vm_read_file`, `vm_write_file`, `vm_run`), un faux `qm guest exec` qui exécute la commande en local et renvoie `{"out-data": ...}` suffit (utilisé pour `syncin_editors_apply`). Le YAML cloud-init se vérifie en extrayant le bloc du heredoc et en le passant à PyYAML. Pour un script généré par heredoc (ex. test de restauration), extraire le bloc voulu par `sed -n 'a,bp'` et le rejouer avec un faux `restic`.
- **Piège shell** : ne jamais nommer une variable `done` (mot réservé de bash).

## Règles de travail (à respecter à chaque échange)
- Chaque modification = une nouvelle version, livrée en monolithe `proxmox-homelab-install-vX.Y.Z.sh` + `proxmox-homelab-modulaire.zip` (+ `proxmox-homelab-answers.json.example` et `proxmox-homelab-variables.md` régénérés si des variables changent). Idem pour le N54L : installateur autonome + zip de l'arbre.
- **Une seule lignée de versions par produit.** Avant de modifier le code, relire `homelab-install-courant.sh` dans le projet et partir de sa version (si une autre conversation l'a fait évoluer, ne pas repartir de sa propre copie : fusionner).
- **Après chaque livraison, publier dans le projet, dans la même session** : le monolithe, le fichier de réponses d'exemple et la doc des variables si elles changent, la carte des modules régénérée et ce document. Ne jamais livrer à l'utilisateur sans l'avoir fait. (`project_write` exige un `project_read` préalable du même document dans la conversation, et refuse si le document a changé depuis : relire puis réécrire. Attention : `backup-server-install.sh` et `proxmox-homelab-variables.md` reviennent EN LIGNE à la lecture, très volumineux : ne les lire que si on doit les réécrire.)
- Réponses en français et concises.
- Plus besoin de rappeler à chaque livraison que rien n'est validé sur un vrai Proxmox (l'utilisateur le sait).
- Débogage : un groupe de commandes à la fois, depuis l'hôte, avec sudo ; demander le message d'erreur exact avant de corriger.
- Sécurité : les actions Telegram ne doivent ajouter aucun risque si Telegram est piraté.
- Aucun mot de passe, clé ou jeton dans ce projet ni dans les messages.
- Éviter les sous-agents (fork) : ils héritent de tout le contexte et butent sur les limites de débit.

## Serveurs
- pve9700 : 192.168.1.4.
- pve3700x : 192.168.1.128 (nouveau PC, 16 Go de RAM, CPU AMD Ryzen 3700X ; disque système Samsung SSD 840 avec ≈0,95 To écrits et ≈1 % d'usure au 9 nov ; disque DATA = disque dur). Toujours préciser lequel est concerné.

## Architecture (valeurs par défaut du script)
- Réseau : vmbr0 (LAN), vmbr1 privé 10.10.10.0/24 (NAT + redirections).
- CT 101 SWAG (10.10.10.16) : nginx + Let's Encrypt, ports 80/443/8088.
- VM 103 Docker (10.10.10.103) (disque 64G par défaut depuis 2.55.2) : Nextcloud (8081), Sync-in, Immich, Jellyfin, Home Assistant, arr. **8192 Mo de RAM minimum** (voir pièges ; 12288 avec Recognize).
- VM 104 Files : Samba + Webmin.
- CT 108 mail (docker-mailserver), CT 110 monitoring (Homepage, Uptime Kuma, ntfy), CT DNS (AdGuard), CT 106 WireGuard, Node, CT 105 xmrig, CT 111 IA (optionnel, GPU).
- Dossiers (par site, `DATA/<domaine>/SHARED` et `/apps` depuis 2.57.0) : SHARED (Samba, stockages externes Nextcloud) ; APPS_DIR (/srv/apps dans la VM, sur l'hôte en virtiofs) pour les données des applications.
- Disques des VM/CT : `GUEST_STORAGE` (2.55.1), défaut `local-lvm` (disque système) ; `DATA` les place sur le disque de données.
- Domaine : ipassed.fr ; portail `home.ipassed.fr`.
- SSH externe temporaire : port 2244, clé seulement, utilisateur ADMIN_USER (pas root).

## Commandes utiles (avec sudo si compte admin)
- Installer : `sudo ./install.sh` (lit le fichier de réponses, chmod 600). Toujours lancer depuis le même dossier.
- Une seule fonction : `sudo ./install.sh --run <fonction>`.
- SSH externe : `--ssh_external_on|off|status|expand N|diag`, `--ssh_key_sync`.
- Portail : `--run portal_apply` ; Homepage : `--run monitor_homepage_regen`.
- Nextcloud : `--run nextcloud_reinstall force` (supprime config + base + données Nextcloud, pas SHARED) ; `--run configure_nextcloud_office`.
- Sync-in + OnlyOffice/Collabora (2.58.0/2.59.0) : `--run syncin_editors_apply` (ancien nom `syncin_onlyoffice_apply` conservé ; voir la section dédiée).
- Nextcloud optimisé (2.55.0) : `--run nextcloud_optimize` ; `--run nextcloud_stack_apply` ; photos/IA : `--run nextcloud_photos_setup`, `nextcloud_photos_scan`, `nextcloud_photos_classify start|stop|status`, `nextcloud_photos_status`.
- PHP2Shell (2.55.0) : `--run php_cve_check`, `php_cve_hunt`, `php_cve_fix`.
- CPU de la VM Docker : `--run docker_vm_cpu_apply [reboot]` (`DOCKER_CPU_TYPE="host"` nécessaire pour l'IA : AVX2).
- SWAG : `--run swag_nginx_fix`, `--run verify_swag_certificate`.
- Mail : `--run mail_free_port25`, `--run mail_check`.
- Monitoring : `--run monitor_fix_ntfy_image`.
- Sites (2.57.0) : `--sites-status`, `--site-add domaine.tld [svc1,svc2] [/racine]`.
- Sauvegarde vers le N54L (2.60.0) : `--run backup_source_export <nom> 'HBREQ1:…'`, `backup_source_list`, `backup_source_revoke <nom>`.
- XMRig : logs `pct exec 105 -- journalctl -u xmrig -f` ; hugepages/MSR hôte : `--run configure_hugepages`, `--run configure_msr_optimization`.
- Fichier de réponses JSON (2.56.0) : voir la section dédiée. Modes de service (texte : `"keep"`...) : keep, run (paramètres seulement), cleanup, remove, skip. Ils s'appliquent à un invité entier (VM/CT), pas à une application : pour Nextcloud, c'est `ENABLE_DOCKER` (VM 103). Après un `cleanup` réussi, repasser le service en `keep`.

## Serveur de sauvegarde N54L (v2.0.0, 17 nov 2026) — configuration en JSON
- Modèle : **tirage** (le N54L va chercher ; aucun accès des sources vers lui). rsync en lecture seule par `rrsync -ro` (compte `backup-pull` sur les serveurs), miroir + instantanés par liens durs (`<BACKUP_ROOT>/<source>/mirror`, `snaps/<date>`, `.SUSPECT`), seuil de changements, fichiers témoins, SMART/RAID, contrôle périodique (scrub + intégrité SQLite), test de restauration, réveil RTC (`rtcwake`), mails (msmtp), Telegram (alertes + actions protégées par TOTP, bot `hb-bot`, sudo restreint vers `homelab-backup-actions`), disque USB d'export (marqueur `HOMELAB-BACKUP`), tunnel WireGuard par source.
- **v2.0.0 : plus aucun fichier `.conf`.** Réglages : `/etc/homelab-backup/backup.json` (groupes organisationnels : volume, reveil, changements, conservation, controle, restauration, admin_ssh, reseau, export, mail, telegram ; seul le nom de variable compte). Sources : `/etc/homelab-backup/sources.d/<nom>.json` (`HOST, PORT, USER, WG_CONF, SSH_KEY, THRESHOLD, EXCLUDES[], PATHS[], CANARIES[]`). Pas de migration : un ancien `backup.conf` et les anciens `sources.d/*.conf` sont ignorés (install.sh le dit).
- **Règle pour ajouter une variable N54L** : son défaut dans `lib/lib.sh` + UNE ligne `V^groupe^NOM^type^défaut^description` dans `conf/schema.txt` (source du modèle `backup.json`, de `homelab-backup-ctl describe` et de `update-conf`). Quelques défauts (BACKUP_MOUNT, RESTORE_*, TELEGRAM_EVENTS, TELEGRAM_ACTION_DELAY) sont aussi repris par `${VAR:-défaut}` dans les scripts : cohérents avec le schéma.
- `lib/lib.sh` : `hb_load_conf` (jq `-j`, séparateurs `\u001f`/`\u001e`, `printf -v`, aucun eval, noms réservés refusés), `hb_conf_set NOM VALEUR` (garde le type JSON), `hb_schema_json`, `hb_describe`, `hb_merge_conf` (ajoute les variables manquantes, liste `_nouveau`, `.bak-date`, code 10), `hb_source_load` (valide HOST/PORT/USER/WG_CONF/THRESHOLD et chaque chemin : `^[A-Za-z0-9._@+-][A-Za-z0-9._@+/-]*$`, pas de `..`), `hb_source_sites` (dossiers `*/apps/backups/db`).
- Commandes `homelab-backup-ctl` : status, run, ack, volume, update-conf, describe, version, restoretest, check, repair, dhcp, keep-on/off, totp-show/reset, arm, poweroff, export, test-mail, request, add-source, test-source, test-notify, telegram-id, diagnose.
- **Multi-site** : chemins de source relatifs à DATA (`proxmox/dump ipassed.fr/SHARED ipassed.fr/apps`) ; le test de restauration contrôle les dumps de CHAQUE site (`<site>/apps/backups/db/<cible>`, libellé `dump <site>/<cible>`).
- **Protocole d'ajout d'un serveur** : `homelab-backup-ctl request <nom>` (N54L, clés publiques SSH + WireGuard → `HBREQ1:…`) → sur Proxmox `./install.sh --run backup_source_export <nom> 'HBREQ1:…'` (autorise la clé en lecture seule, crée le pair WireGuard profil backup, fabrique `.hbsrc` = `#HBSRC2` + `@@FILE sources.d/<nom>.json` (JSON via `jq -n`, tous les sites) + `@@FILE wireguard/<nom>.conf` avec `@@WG_PRIVATE_KEY@`) → `homelab-backup-ctl add-source 'HBSRC2:…'` (N54L, valide le JSON, insère SA clé privée locale, teste). HBSRC1 (ancien, `.conf`) n'est plus accepté : N54L ≥ 2.0.0 et Proxmox ≥ 2.60.0 vont ensemble. `backup_source_auto` écrit aussi `${BACKUP_SOURCES_DIR}/<nom>.json` (sans tunnel).
- Installateur : `backup-server-install.sh` est autonome (archive tar.gz base64 intégrée, construit par `backup-server-build.py <arbre> <sortie>`). `HB_KEEP=dossier bash backup-server-install.sh --extract-only` extrait l'arbre (install.sh, lib/, bin/, conf/schema.txt, conf/source.json.example, README.md) ; modifier ; reconstruire avec le builder ; vérifier l'extraction à l'identique (`diff -r`). Arbre = pas de stockage dans le projet (le monolithe fait foi).
- Testé en bac à sable seulement (faux rsync/ssh) : `bash -n`, chargement/typage/merge/describe du JSON, validation de chemins dangereux, dumps par site, `add-source` HBSRC2 (JSON valide/invalide, droits 600). Rien sur le N54L réel.

## Stockage des invités : GUEST_STORAGE (2.55.1)
- `GUEST_STORAGE="local-lvm"` (défaut) ou `"DATA"` ou tout storage Proxmox acceptant `images` et `rootdir`. Appliqué à la création : disque, EFI et cloud-init des VM, rootfs des CT. `RESTORE_TEST_STORAGE` vide = `GUEST_STORAGE`.
- `check_guest_storage` (appelé dans `main` après la création du storage DATA) refuse l'installation si le storage est absent, inactif ou n'accepte pas images/rootdir. Pour DATA : lancer l'installation complète une fois.
- Les invités existants ne sont pas déplacés (`qm move-disk`, `pct move-volume` à la main, ou `cleanup` du service).
- Sur un storage « dir » (DATA) : pas d'instantané pour les CT, donc vzdump les sauvegarde en mode suspend (arrêt bref). Si DATA est un disque dur, les VM (Docker : bases, Immich) sont nettement plus lentes.
- Le swap de l'hôte (LV `pve/swap`) et le swapfile de 2 Go de la VM Docker ne sont pas concernés.

## Disque unique : DATA_MODE=thin (2.61.0) et garde-fou de stockage
- `DATA_MODE="disk"` (défaut) : `DATA_DISK` (ou `DATA_EXISTING_DEVICE`) formaté/réutilisé comme avant. `DATA_MODE="thin"` : **un seul disque** ; DATA = volume mince ext4 (label DATA) créé DANS le thin pool de Proxmox (`DATA_THIN_POOL` = `pve/data`, nom `DATA_THIN_LV` = `datafs`, taille VIRTUELLE `DATA_LV_SIZE` = `90%` du pool ou absolue `2T`), monté par UUID sur `DATA_MOUNT`. Aucun disque formaté ; marche sur un Proxmox déjà installé (LVM-thin requis) ; incompatible avec `DATA_EXISTING_DEVICE`. Idempotent (ext4/DATA réutilisé, autre système de fichiers refusé). Fonction `prepare_data_thin` (`host/40-storage.sh`). Pas de question interactive : se règle dans le fichier de réponses.
- Le système (`pve/root`, ≤ 96 Go) reste séparé et de taille fixe. Le pool est PARTAGÉ avec les disques de VM de `local-lvm` : `df` montre la taille virtuelle, la vraie occupation se lit avec `lvs` (Data% et Meta%).
- `DATA_TRIM=true` (défaut, tous modes) : `configure_trim` active `fstrim.timer` (hebdomadaire) ; pas d'option de montage `discard`. Les disques de VM ont déjà `discard=on`.
- **Garde-fou** (`host/59-pool-guard.sh`, `POOL_GUARD=true`, `POOL_GUARD_PCT=98`) : timer chaque minute, `/usr/local/sbin/homelab-pool-guard`, conf `/etc/homelab/pool-guard.conf`. Mesure les thin pools (données ET métadonnées) et le système de fichiers de `DATA_MOUNT`. Au seuil : arrête les vzdump, éteint toutes les VM/CT (`shutdown --timeout 90 --forceStop`), met `onboot 0` à tous (même après un reboot rien ne repart), notifie (`homelab-notify`, urgent, catégorie `disk`). Reprise À LA MAIN : `sudo homelab-pool-guard --resume` (refuse au-dessus du seuil, `--force` passe outre ; rétablit `onboot` et relance via `startall --vms … --force`) ; `--status`. Réarmement automatique 5 points sous le seuil (même si les invités ont été relancés à la main : pas de réextinction pendant le ménage). Commandes `--run pool_guard_status|pool_guard_resume [--force]|configure_pool_guard`. Aucune action Telegram (rien à pirater). Testé en bac à sable (faux lvs/df/qm/pct/pvesh : déclenchement, refus de reprise, reprise, réarmement) ; `prepare_data_thin` non testé hors Proxmox (`lvcreate`/`mkfs` réels).

## Petit disque système (2.55.2)
- `GUEST_STORAGE="DATA"` place disques de VM/CT sur DATA ; `IMAGES_STORAGE="auto"` (défaut : suit GUEST_STORAGE ; ou `local` / `DATA`) place aussi l'image cloud Debian, le pilote NVIDIA (`${PROXMOX_DATA_DIR}/template/iso`) et les templates CT (`template/cache`). Restent sur `local` : snippets cloud-init. `resolve_guest_storage` recalcule `IMAGE_STORE_DIR`/`DEBIAN_IMAGE`.
- Déplacer des invités existants : `--run guests_move_storage` (simulation) puis `guests_move_storage apply [storage]`.
- VM Docker : `--run docker_disk_grow 32G`, `docker_prune`, `docker_log_rotation_apply`. docker-update apply fait aussi `builder prune --filter until=72h`.
- homelab-health : alerte à `HEALTH_DISK_PCT` et paliers (`HEALTH_DISK_STEP`) sur le disque racine de chaque invité.

## Fichier de réponses JSON (2.56.0)
- Fichier `proxmox-homelab-answers.json` : objet JSON, groupes (`obligatoire`, `services`, `docker_apps`, `reseau`, `dns_zone`, `admin_ssh`, `wireguard`, `services_optionnels`, `sauvegardes`, `maintenance`, `xmrig`, `avance`) **organisationnels** : seul le nom de la variable compte (unique dans tout le fichier, clés feuilles aplaties au chargement). `null` ou absent = défaut du script ; `""` = vraie valeur vide. Types : texte, true/false, nombre ; liste de textes = noms séparés par des espaces (sous-domaines). `${AUTRE}` seulement pour les variables de type `ref`. Clés `_version`, `_note`, `_nouveau` ignorées ; inconnues rangées dans `personnalise`.
- Prévu pour la suite : plusieurs instances d'un même service (format hiérarchique prêt ; il faudra des groupes d'instances).
- Chargement (`answers_load_json`, `core/15-answers-load.sh`) : `jq -j` -> variables bash ; noms réservés refusés ; `ref` résolues en second. Fusion `--update-answers` (`answers_merge_json`) : valeurs conservées, variables manquantes ajoutées et listées dans `_nouveau`.
- Commandes : `--init-answers`, `--update-answers [f]`, `--describe [NOM|début|motif*]`. `jq` est installé automatiquement si on est root.
- Secrets générés : `proxmox-homelab-secrets.json` (`secrets_load`/`secrets_persist`).

## Multi-sites (2.57.0 phase 1 ; sauvegardes complétées en 2.58.1 et 2.60.0)
- Décisions : infrastructure commune (une VM Docker, un SWAG, un CT mail/DNS) ; par domaine : apps Docker, mail, partage Samba, Node+Mongo ; SWAG (un certificat par domaine), DNS, WireGuard, xmrig, supervision, sauvegardes restent communs. Pas de migration : les services existants sont recréés (ipassed.fr va directement dans `DATA/ipassed.fr/`).
- Section `sites` du JSON (hors groupes, ignorée de l'aplatissement) : `{ "domaine": { "racine": null, "services": [...], "groupe", "gid" } }`. Absente = un seul site (`DOMAIN`). Racine par défaut `${DATA_MOUNT}/<domaine>` avec `SHARED/` et `apps/` ; le site principal (= `DOMAIN`) redéfinit `SHARED_DIR`/`APPS_DIR` ; groupes `fs_<domaine>` GID 2001+ pour les secondaires, `fileshare`/2000 pour le principal.
- Module `core/36-sites.sh` : `sites_load`, `validate_sites`, `site_enter`/`site_leave`, `sites_data_dirs`, `sites_apps_list`, `site_tree_create`, `sites_tree_extra`, commandes `--sites-status`, `--site-add domaine [svc,svc] [/racine]`.
- Sauvegardes couvrant tous les sites : restic (`sites_data_dirs`), fichiers témoins par site, source de tirage N54L (`backup_source_paths/canaries`), export USB (`EXTRA_SITES`). 2.58.1 : `SITE_APPS_DIRS` dans `/etc/homelab/homelab.conf` ; test de restauration mensuel : un témoin restic par site ; `configure_db_dump` crée `backups/db` dans chaque site.
- Reste à faire côté sauvegarde : les DUMPS de bases ne concernent que le site principal (une seule pile de bases) ; les cibles par site (`nextcloud@domaine`...) arrivent avec les applications par site (phase 3). Mail et Node : site principal seulement.
- Phases suivantes : (2) SWAG/DNS/certificats par domaine ; (3) apps Docker par site dans la VM (projets compose par domaine, montages virtiofs par site, limite ~10 virtiofs/VM) + dumps par site ; (4) mail multi-domaine, Samba par domaine, Node+Mongo par site.

## Nextcloud : pile 2.55.0
- Le compose d'origine (cloud-init, `nextcloud:stable`) n'est jamais modifié : `/opt/apps/nextcloud/docker-compose.override.yml` (réécrit à chaque lancement) ajoute `nextcloud-redis`, `nextcloud-cron`, réglages PHP (`php-homelab.ini`) et fige l'étiquette d'image sur la version MAJEURE en cours.
- Recognize (`NEXTCLOUD_RECOGNIZE=true`) : image dérivée `nextcloud-homelab:<majeure>` (ffmpeg + nodejs). Besoins : AVX2 (`DOCKER_CPU_TYPE=host`), ~4 Go de RAM en plus (`DOCKER_MEMORY=12288`), ~1,5 Go de modèles.
- Memories (`NEXTCLOUD_PHOTOS=true`) : app Photos requise ; dossier `NEXTCLOUD_PHOTOS_PATH` (défaut /Photo) du compte `NEXTCLOUD_PHOTOS_USER`. Les stockages externes ne sont relus que par `files:scan` (`nextcloud_photos_scan`).
- Scripts de fond dans la VM : `/usr/local/sbin/nc-photos-index.sh`, `nc-recognize-models.sh`, `nc-recognize-classify.sh`.
- docker-update : `pull --ignore-buildable` + `build --pull`.
- PHP2Shell (CVE-2026-109618/109619, RCE sans authentification, exploitées) corrigées dans PHP 8.5.12, 8.4.27, 8.3.36, 8.2.35 ; image Nextcloud Apache = mod_php = la plus exposée. Collabora CODE intégré (richdocumentscode, CVE-2026-110447) : chercher `shx*.php`.

## Sync-in : éditeurs OnlyOffice (2.58.0) et Collabora (2.59.0)
- Principe : Sync-in réutilise les conteneurs déjà déployés pour Nextcloud, en mode « serveur externe » : OnlyOffice (`/opt/apps/onlyoffice`, port 8082, `onlyoffice.<domaine>`) et/ou Collabora (`/opt/apps/collabora`, port 9980, `office.<domaine>`), tous deux servis par SWAG. Pas de conteneur en plus.
- Variables (groupe `docker_apps`, défaut false) : `SYNCIN_ONLYOFFICE` (exige `ENABLE_SYNCIN` et `ENABLE_ONLYOFFICE`) et `SYNCIN_COLLABORA` (exige `ENABLE_SYNCIN` et `ENABLE_COLLABORA`) ; sans le serveur correspondant, l'option est ignorée avec un avertissement. Les deux ensemble : comportement de Sync-in NON documenté. OnlyOffice : secret JWT = `ONLYOFFICE_JWT_SECRET`. Collabora : pas de secret ; n'accepte que les hôtes WOPI listés.
- Nouvelle VM (cloud-init) : `/opt/apps/syncin/environment.yaml` reçoit `server.publicUrl` et `applications.files.editors` : `onlyoffice` (`enabled`, `externalServer`, `secret`, `verifySSL: true`) et/ou `collabora` (`enabled`, `externalServer`). `extra_hosts` : Sync-in résout les serveurs de documents vers SWAG ; OnlyOffice et Collabora résolvent Sync-in vers SWAG ; Collabora reçoit `aliasgroup2=https://<nom Sync-in>:443`. Fonctions (module `tools/10-repair.sh`) : `syncin_onlyoffice_wanted`, `syncin_collabora_wanted`, `syncin_editors_wanted`, `syncin_editor_fqdns`, `syncin_environment_text`, `syncin_extra_hosts_cloudinit`, `onlyoffice_syncin_hosts_cloudinit`, `collabora_syncin_hosts_cloudinit`, `collabora_syncin_alias_cloudinit`.
- Installation existante : mettre `SYNCIN_ONLYOFFICE=true` et/ou `SYNCIN_COLLABORA=true`, puis `--run syncin_editors_apply` : lit environment.yaml et les compose dans la VM (agent QEMU), REFUSE si les secrets du fichier de réponses ne sont pas ceux de la VM, sauvegarde `.bak.<date>`, réécrit environment.yaml, ajoute `extra_hosts` et `aliasgroupN` manquants (idempotent), `docker compose up -d` des serveurs de documents puis `up -d --force-recreate syncin`, affiche le healthcheck OnlyOffice (attendu `true`), le `hosting/discovery` de Collabora (attendu `200`), le code HTTP et les logs de Sync-in.
- Clés de configuration prises dans la doc officielle de Sync-in : chemin `applications.files.editors.*` ; les anciens `applications.files.onlyoffice`/`collabora` marchent mais sont dépréciés ; `publicUrl` sera obligatoire à la prochaine majeure. Image : `syncin/server:2`. La doc ne dit pas si l'éditeur s'ouvre dans la même interface ou un nouvel onglet ni ne décrit de contrainte WOPI pour Collabora.
- WebDAV : chemin `/webdav/` supposé, NON confirmé : test `curl -i -u USER -X PROPFIND -H 'Depth: 0' https://sync.<domaine>/webdav/` (attendu 207).
- Testé en bac à sable seulement (fonctions, YAML cloud-init dans les 4 combinaisons, `--update-answers`, `syncin_editors_apply` avec faux `qm`).

## Pièges connus
- **Nextcloud et cleanup de la VM Docker** : les données de Nextcloud sont sur l'hôte (APPS_DIR/nextcloud). Un `cleanup` de la VM recrée base et config neuves mais laissait l'ancien dossier de données : Nextcloud restait sur l'assistant web. Depuis 2.54.22, le cleanup met l'ancien dossier de côté (`nextcloud.ancien-DATE`). Réparation à la main : `--run nextcloud_reinstall force`.
- **VM Docker : 4096 Mo ne suffisent pas** pour Nextcloud + Immich + Sync-in + Jellyfin + HA : la VM gèle (« Under memory pressure »). `DOCKER_MEMORY="8192"` ; à chaud : `qm set 103 --memory 8192` (VM arrêtée). Les nouvelles VM ont 2 Go de swap (v2.54.19).
- **VM Docker : disque de 32G plein (11-12 nov, pve3700x)** : Postgres d'Immich ne peut plus écrire, boucle de redémarrage, « Error: 500 - undefined ». Images Docker ≈21 Go, volumes 3,8 Go, cache de build 2,8 Go, logs 1,4 Go. Correctif : `qm resize 103 scsi0 +32G`, puis dans la VM `docker builder prune -af; journalctl --vacuum-size=50M; apt-get clean; growpart /dev/sda 1; resize2fs /dev/sda1`, puis `docker compose up -d` ; test `curl http://10.10.10.103:2283/api/server/ping`. Depuis 2.55.2 : 64G par défaut, rotation des logs, alertes.
- **VM Docker : type de CPU `x86-64-v2-AES`** (défaut) n'expose pas AVX/AVX2 : TensorFlow (Recognize) ne marche pas. Utiliser `host` (2.55.0).
- Sans l'agent invité, `qm guest exec` ne marche pas : lire les journaux d'une VM en montant son disque en lecture seule depuis l'hôte (stop VM, `losetup -fP --show /dev/pve/vm-ID-disk-1`, `mount -o ro ${LOOP}p1 /mnt/vmID`, puis démonter et `losetup -d`). Avec `GUEST_STORAGE=DATA`, le disque est un fichier qcow2 (monter via `qemu-nbd`).
- Console des VM = série (`qm terminal ID`, Entrée pour le prompt, Ctrl+O pour sortir).
- `proxy.conf` de SWAG définit déjà proxy_read/send_timeout : ne jamais les redéfinir dans une conf de site.
- Let's Encrypt : un seul enregistrement A par nom (pas d'AAAA parasite), ports 80 et 443 redirigés vers l'hôte, limite 5 échecs/heure.
- Les mots de passe générés doivent rester stables entre deux lancements (sinon les bases Docker refusent la connexion).
- Les projets claude.ai n'acceptent pas les fichiers ZIP.
- XMRig : le CT monte HUGEPAGES_MOUNT (/mnt/huge) ; sans hugepages hôte, `pct start` échoue. Corrigé en 2.54.20.
- XMRig : dans le CT, `rdmsr`/`wrmsr` sont à false (CT non privilégié) : normal. Le réglage MSR se fait sur l'hôte (`xmrig-msr-tune.service`). `1gb-pages` et `huge-pages-jit` ne valent pas le coup (décision : config inchangé).
- XMRig MSR : depuis 2.54.21, détection du fabricant et de la génération (Intel ; AMD Zen1/2 = famille 23, Zen3 = 25, Zen4 = 25 modèle 97, Zen5 = 26).
- WireGuard : un CT à moitié installé faisait échouer `fw-up` et stoppait tout le script. Corrigé en 2.54.20.

- **Disques de VM bloqués à 3 Go (test pve9700, 18 nov)** : sur un storage dir (DATA = ext4 sur disque dur), `qemu-img resize --preallocation=metadata` expirait (« got timeout ») : le script ignorait l'échec, la VM gardait les 3 Go de l'image cloud, cloud-init échouait (paquets, agent QEMU absent). Cause aggravante : DATA plein (0 disponible, réserve ext4). Corrigé en 2.60.1. À la main : `pvesm set DATA --preallocation off`, détruire la VM (`qm destroy ID --purge`) et relancer. Symptôme déroutant : sur l'hôte, `qemu-guest-agent` absent et cloud-init « disabled » sont normaux (ce sont des services de VM). Le root de la VM n'a pas de mot de passe utilisable en console (cloud-init ignore `passwd` pour root) : lire les logs par `qm guest exec ID -- …` ou en montant le disque (`qemu-nbd --read-only`).
- Multi-sites : avec `DOMAIN=dev.ipassed.fr`, les dossiers sont `/mnt/data/dev.ipassed.fr/{SHARED,apps}` (mappings `files_shared`, `apps_data`) ; d'anciennes données dans `/mnt/data/SHARED` ne sont pas vues par les VM.

## Problèmes ouverts (au 19 nov 2026)
1. VM 103 : cause trouvée (mémoire 4096 Mo) et corrigée sur pve3700x (8192 Mo). Nextcloud réinstallé le 10 nov avec `nextcloud_reinstall force` : fonctionne, stockages externes créés.
2. VM 104 (Files) : cloud-init a signalé une erreur lors d'une installation (cause non lue ; la v2.54.18 affiche le détail).
3. SWAG : certificat Let's Encrypt jamais émis (« key authorization mismatch ») : vérifier DNS A/AAAA des noms. (Sans certificat valide pour `onlyoffice.<domaine>` / `office.<domaine>`, les éditeurs de Sync-in ne marcheront pas.)
4. Monitoring : relancer avec `monitor_fix_ntfy_image`.
5. Mail : port 25 occupé (corrigé en v2.54.12), clé DKIM à générer ensuite.
6. SSH externe : fonctionne.
7. Non testé sur le matériel : module IA (GPU 3060), mode `run`, STORE_IMAGES, sauvegardes, portail en vue externe, `GUEST_STORAGE=DATA`. WireGuard : CT 106 de pve3700x à réparer (`--run create_wireguard_ct`).
8. XMRig sur pve3700x : fonctionne (≈6,9 kH/s). À faire : `--run configure_msr_optimization`, contrôler `xmrig-msr-tune` et le hashrate ; ENABLE_XMRIG de « cleanup » à « keep » ; vérifier xmrig-monitor.service.
9. 2.55.0 : `--run php_cve_check` puis `php_cve_fix` si vulnérable (puis `php_cve_hunt`) ; premier essai de `nextcloud_optimize` et de Memories/Recognize.
10. Usure du SSD système de pve3700x : non préoccupante (≈1 %). `GUEST_STORAGE=DATA` n'a de sens que si DATA est assez rapide (disque dur sur pve3700x). Décision en attente.
11. Immich 500 (disque VM 103 plein) : résultat du resize/prune non communiqué.
12. 2.55.2 : à tester `IMAGES_STORAGE`/`GUEST_STORAGE=DATA` sur un hôte à petit disque système, alerte disque des invités, `guests_move_storage`.
13. 2.56.0 à tester sur le matériel : installation automatique de `jq`, arrêt « variables nouvelles ».
14. Écarts connus du modèle d'avant : défauts calculés (NODE_NAME, AI_CORES, XMRIG_CORES, LOG_FILE) non figés dans le JSON ; `ENABLE_*` tri-états restent des textes.
15. 2.58.0/2.59.0 (Sync-in + OnlyOffice/Collabora) : à tester sur le serveur (`ENABLE_ONLYOFFICE`/`ENABLE_COLLABORA`, puis `SYNCIN_*`, puis `--run syncin_editors_apply` ; ouvrir un .docx dans Sync-in). En cas d'erreur de clé `editors`, lire les logs du conteneur `syncin` et demander le message exact.
16. WebDAV de Sync-in : non confirmé (test PROPFIND à faire).
17. Multi-sites (2.57.0/2.58.1) à tester : `--sites-status`, `--site-add`, dossiers/groupes d'un 2e domaine, `--run restore_test_now` (une ligne `restic-temoin` par site).
19. Test pve9700 (2.60.0, 18 nov) : VM 103/104 à recréer avec la 2.60.1 ; le message `mount: /srv/data: wrong fs type` de cloud-init (virtiofs) est apparu alors que le montage manuel fonctionne : à revérifier une fois les disques à la bonne taille.
20. **2.61.0 à tester sur le matériel** : `DATA_MODE=thin` sur un Proxmox à disque unique (`lvs`, `findmnt /mnt/data`, `df`), `fstrim.timer`, garde-fou (`homelab-pool-guard --status`, simulation avec `POOL_GUARD_PCT=50`, puis `--resume`).
18. **N54L v2.0.0 + Proxmox 2.60.0 (JSON, HBSRC2) : à tester sur le matériel.** L'utilisateur doit recréer sa config N54L (backup.json depuis le modèle, sources via `request` → `backup_source_export` → `add-source`), puis `homelab-backup-ctl test-source`, `run`, `restoretest` (une ligne `dump <site>/<cible>` par site). Le réveil RTC reste à valider sur le BIOS du N54L.

## Historique résumé des versions récentes
**2.61.0 (22 nov)** `DATA_MODE=thin` (disque unique : volume mince DATA dans pve/data), `DATA_TRIM` (fstrim.timer), garde-fou `POOL_GUARD` (arrêt des invités à 98 %, reprise manuelle) ; nouveau module `host/59-pool-guard.sh` (ajouté à MODULES) · **2.60.1 (19 nov)** storage DATA créé/maintenu avec `--preallocation off` ; `create_cloud_vm` s'arrête si le disque scsi0 n'a pas la taille voulue · **N54L 2.0.0 (17 nov)** configuration et sources en JSON (`backup.json`, `sources.d/*.json`, schéma `conf/schema.txt`, `describe`/`version`), HBSRC2, validation des chemins de source, test de restauration par site, correction du globbing des EXCLUDES · **2.60.0** côté Proxmox : fichier source N54L en JSON, paquet `#HBSRC2` (`backup_source_json`, `jq -n`), `revoke` retire aussi le `.json` · 2.59.0 Sync-in : éditeur Collabora en plus d'OnlyOffice (variable `SYNCIN_COLLABORA`, `aliasgroupN` + extra_hosts, `--run syncin_editors_apply` remplace `syncin_onlyoffice_apply` ) · 2.58.1 sauvegardes par site : test de restauration (témoin restic par site), dossiers de dumps par site, `SITE_APPS_DIRS` · 2.58.0 Sync-in : éditeur OnlyOffice · 2.57.1 allègement : plus de conversion des anciens `.conf` ni de `repair_apps_data_location`/`repair_add_apps_share` (l'utilisateur recrée ses services) · 2.57.0 multi-sites phase 1 · 2.56.0 réponses en JSON + version modulaire · 2.51 portail · 2.52 module IA · 2.53 SSH externe + STORE_IMAGES · 2.54.0 mode run · 2.54.1 ssh_key_sync · 2.54.2-7 corrections sshd/locale/pct · 2.54.8 ssh_external_diag · 2.54.9 monitoring robuste · 2.54.10-11 nginx SWAG · 2.54.12 port 25 mail · 2.54.13-15 Nextcloud (test HTTP, réinstallation) · 2.54.16 image ntfy · 2.54.17 secrets conservés · 2.54.18 détail des erreurs cloud-init · 2.54.19 VM Docker 8 Go + swap · 2.54.20 XMRig (hugepages automatiques) + WireGuard (CT à moitié installé) · 2.54.21 réglage MSR Intel/AMD · 2.54.22 fusion des deux lignées + `nextcloud_wait_ready` + cleanup de la VM Docker met l'ancien dossier Nextcloud de côté · 2.55.0 Nextcloud optimisé, PHP2Shell, photos Memories + IA Recognize, CPU `host`, docker-update compatible images construites · 2.55.1 `GUEST_STORAGE` · 2.55.2 disque Docker 64G, rotation des logs, prune, alerte disque des invités, `IMAGES_STORAGE`, `--run` docker_disk_grow / docker_prune / docker_log_rotation_apply / guests_move_storage · 13 nov découpage modulaire automatique (`split-modules.py`) · 2.56.0 réponses et secrets en JSON (schéma unique `core/04-answers-schema.sh`, `--describe`, documentation générée).

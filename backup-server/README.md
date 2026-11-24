# Serveur de sauvegarde par tirage (N54L) — v2.0.0

Ce serveur **va chercher** les données sur tes serveurs Proxmox. Aucun serveur source n'a de clé ou d'accès vers lui, et il n'est allumé que quelques heures par semaine.

La configuration est en **JSON** (comme l'installateur Proxmox) : `/etc/homelab-backup/backup.json` pour le serveur, `/etc/homelab-backup/sources.d/<nom>.json` pour chaque serveur sauvegardé. Plus aucun fichier `.conf` n'est lu (un ancien `backup.conf` est ignoré : reporte-y tes valeurs ; refais une demande `request` par source).

## Cycle
1. Réveil par l'horloge matérielle (`rtcwake`) le `WAKE_DAY` à `WAKE_TIME` (dimanche 03:00).
2. Pour chaque source (`sources.d/*.json`) : `rsync` en lecture seule (clé limitée par `rrsync -ro`) vers un miroir, puis instantané (copie par liens durs).
3. Contrôles : volume de fichiers modifiés/supprimés (`CHANGE_THRESHOLD`, 10 % par défaut), fichiers témoins, SMART, RAID dégradé.
4. Mail récapitulatif, puis extinction et réveil programmé. Un démarrage manuel (hors fenêtre de réveil) ne lance rien et n'éteint pas.

## Configuration backup.json
Créé par `./install.sh` à la première exécution (toutes les variables, groupées : volume, reveil, changements, conservation, controle, restauration, admin_ssh, reseau, export, mail, telegram). Le groupe n'est qu'un rangement : seul le nom de la variable compte.
- `homelab-backup-ctl describe [NOM]` : explique une variable (ou toutes, ou celles dont le nom commence par NOM) avec son type et son défaut.
- `homelab-backup-ctl version` : version installée.
- Les valeurs gardent leur type JSON (nombre, booléen, texte). Pas de commentaires dans un JSON : utilise `describe`.

## Format d'une source (sources.d/<nom>.json)
```json
{
  "HOST": "10.10.10.1", "PORT": 22, "USER": "backup-pull", "WG_CONF": "prod",
  "SSH_KEY": null, "THRESHOLD": null, "EXCLUDES": [],
  "PATHS": ["proxmox/dump", "ipassed.fr/SHARED", "ipassed.fr/apps"],
  "CANARIES": ["ipassed.fr/SHARED/00_temoin/temoin.docx"]
}
```
Les chemins sont relatifs au point de montage des données du serveur source (`DATA`). Multi-sites : un dossier par domaine (`<domaine>/SHARED`, `<domaine>/apps`) ; les dumps de bases sont dans `<domaine>/apps/backups/db/<cible>/`. Tout chemin avec `..` ou caractères spéciaux est refusé à la lecture de la source. `null` = valeur par défaut (clé `/root/.ssh/homelab-pull`, seuil global).

## Alertes
- Une alerte met l'instantané à part (`*.SUSPECT`), bloque la purge, et **toutes les sauvegardes suivantes restent suspectes** tant que tu n'as pas acquitté : `homelab-backup-ctl ack <source>` (accepter) ou `ack <source> --discard` (supprimer les suspects et revenir au dernier état valide).
- La première sauvegarde sert de référence, sans alerte.
- Fichiers témoins (docx/jpg/avi créés sur les serveurs) : toute modification ou suppression alerte, quel que soit le seuil.

## Disque externe
Crée un fichier `HOMELAB-BACKUP` à la racine du disque (USB). En le branchant, le dernier instantané **valide** de chaque source y est copié, un mail te prévient quand tu peux le débrancher. Contenu facultatif du fichier (texte, une option par ligne, `#` = commentaire) : `clusters=prod,maison` (les sources à exporter ; absent = toutes) et `keep=2`. Un disque sans ce fichier n'est pas touché (monté en lecture seule le temps de vérifier).

## Commandes
`homelab-backup-ctl status | run | ack | keep-on | keep-off | arm | poweroff | export | test-mail | request | add-source | test-source | update-conf | describe | version | restoretest | check | repair | volume | dhcp | totp-show | totp-reset | test-notify | telegram-id | diagnose`

## Limites connues
- Testé uniquement avec un faux `rsync` : à valider une première fois à la main (`homelab-backup-ctl run`).
- Le réveil RTC dépend du BIOS du N54L : tester une extinction + réveil avant de compter dessus.
- Les instantanés ne sont pas protégés contre l'écriture ; la protection vient de l'isolement du serveur (pare-feu, pas de service ouvert vers les sources, extinction).
- Si le serveur source est infecté AVANT la première sauvegarde, la référence l'est aussi.
- Ce serveur (v2.x, JSON) et l'installateur Proxmox ≥ 2.60.0 (paquet HBSRC2) vont ensemble : l'ancien protocole HBSRC1 n'est plus accepté.

## Ajouter un serveur à sauvegarder (sans rien recopier)
1. Ici : `homelab-backup-ctl request <nom>` → affiche une ligne `./install.sh --run backup_source_export <nom> 'HBREQ1:…'` (clés publiques uniquement ; la clé SSH `homelab-pull` et une clé WireGuard par source sont créées si besoin).
2. Sur le serveur Proxmox : coller cette ligne. Il autorise la clé en lecture seule, crée le pair WireGuard (profil backup) et affiche `homelab-backup-ctl add-source 'HBSRC2:…'`. Le paquet contient les dossiers (`PATHS`) et témoins (`CANARIES`) de **tous les sites** du serveur.
3. Ici : coller cette commande. Elle installe `sources.d/<nom>.json` et `/etc/wireguard/<nom>.conf` (avec TA clé privée, jamais transmise), puis teste tunnel, SSH, dossiers et fichiers témoins (`test-source <nom>`).
Révoquer côté serveur : `./install.sh --run backup_source_revoke <nom>`.

## Alertes Telegram (en plus du mail)
1. Dans Telegram, @BotFather > `/newbot` : tu obtiens un jeton ; écris un message à ton bot.
2. Dans `backup.json` : `TELEGRAM_BOT_TOKEN`, puis `homelab-backup-ctl telegram-id` affiche ton identifiant à mettre dans `TELEGRAM_CHAT_ID`.
3. `homelab-backup-ctl test-notify` envoie un message de test.
`TELEGRAM_EVENTS` choisit les catégories (défaut : `usb backup check restore alert power security`) :
- `usb` : disque USB branché, export démarré/terminé (tu peux débrancher) ;
- `backup` : sauvegarde démarrée, début et fin de chaque source, rapport final, extinction et prochain réveil ;
- `check` : contrôle RAID + intégrité ; `restore` : test de restauration ;
- `alert` : tout échec ou alerte ; `power` : serveur allumé / éteint / redémarré ; `security` : actions à distance.
Le mail continue de partir comme avant.

## Tunnel WireGuard (recommandé)
Dans la source : `"WG_CONF": "<nom>"` (fichier `/etc/wireguard/<nom>.conf`) et `"HOST": "10.10.10.1"` (IP privée du Proxmox dans le tunnel). Le tunnel n'est monté que pendant la copie de cette source, puis coupé : une seule connexion à la fois, pas de conflit entre serveurs ayant le même réseau privé.

## Contrôle périodique (RAID + intégrité)
Au réveil, si le dernier contrôle complet date de plus de `CHECK_INTERVAL_DAYS` (28) jours — ou n'a jamais eu lieu —, après la copie :
1. **RAID** : vérification mdadm (`check`, reprise si interrompue), scrub ZFS ou btrfs, selon le volume monté sur `BACKUP_ROOT`.
2. **Intégrité** : tous les fichiers du miroir sont relus et comparés aux empreintes mémorisées (SQLite par source). Un contenu qui change sans que taille ni date changent = corruption silencieuse : alerte. `homelab-backup-ctl repair <source>` recopie alors depuis la source en comparant le contenu.
Durée plafonnée par `CHECK_MAX_H` (20 h) : au-delà, reprise au réveil suivant. `homelab-backup-ctl check` le lance à la main.

## Réseau en DHCP
`"NETWORK_MODE": "dhcp"` dans `backup.json` (ou `homelab-backup-ctl dhcp [--now]`) : `vmbr0` passe en DHCP (ancienne configuration sauvegardée), un hook garde `/etc/hosts` à jour. Appliqué au prochain démarrage sauf `--now`. Réserve une IP à ce PC dans ta box.

## Volume RAID existant (sans formatage)
`homelab-backup-ctl volume` (lancé aussi par `install.sh` si le volume n'est pas monté) : assemble les grappes mdadm trouvées, active LVM, liste les pools ZFS importables, puis te laisse **choisir** : volume, aperçu en lecture seule, point de montage, racine ou sous-dossier `homelab-backup`. Il monte par UUID (`fstab`, `nofail`), déclare la grappe (`mdadm.conf` + initramfs) et renseigne `BACKUP_MOUNT` / `BACKUP_ROOT` dans `backup.json`. **Il ne crée ni ne formate jamais rien.**

## Sans root, de bout en bout
- **Tirage** : sur les serveurs sources, `ENABLE_BACKUP_PULL` crée un compte système `backup-pull` (sans mot de passe). Sa clé est limitée à `rrsync -ro` et le `rsync` utilisé n'a qu'une capacité (`CAP_DAC_READ_SEARCH`). Dans la source : `"USER": "backup-pull"`.
- **Ce N54L** : `ADMIN_USER` / `ADMIN_SSH_KEY` / `SSH_ROOT_LOGIN: "no"` créent un compte sudo et interdisent le SSH direct de root (refusé si le compte n'a ni clé ni mot de passe, ou n'est pas sudo).

## Mettre à jour backup.json après une nouvelle version
`homelab-backup-ctl update-conf` (et `./install.sh` à chaque lancement) ajoute à `backup.json` les variables apparues : **tes valeurs sont conservées**, les nouvelles sont listées dans `_nouveau`, l'ancien fichier est gardé en `backup.json.bak-<date>`. `install.sh` s'arrête une fois pour que tu les complètes (`HB_SKIP_CONF_CHECK=1` pour passer outre). Les `sources.d/<nom>.json` ne sont pas touchés.
Pour le développeur : ajouter une variable = son défaut dans `lib/lib.sh` + une ligne dans `conf/schema.txt` (`V^groupe^NOM^type^défaut^description`).

## Test de restauration
À chaque sauvegarde réussie (`RESTORE_TEST`), `homelab-backup-restoretest` vérifie que ce qui est sauvegardé est **récupérable** :
- un échantillon de fichiers au hasard (`RESTORE_SAMPLE`, témoins toujours inclus) est copié puis comparé octet par octet ;
- le dernier dump de chaque base **de chaque site** (`<site>/apps/backups/db/*`) est contrôlé : archive lisible et, pour PostgreSQL/MariaDB, fin de dump présente ;
- la dernière archive vzdump de chaque VM/CT est lue en entier ;
- option `RESTORE_TEST_STORAGE` : le plus petit CT est vraiment restauré dans un CT temporaire (`RESTORE_TEST_ID`), puis supprimé.
Un échec déclenche l'alerte. À la main : `homelab-backup-ctl restoretest [source]`.

## Formats de disque et arborescences
- **Volume de sauvegarde** : ext4, xfs, btrfs (ou ZFS) obligatoires (liens durs, droits Unix).
- **Disque externe d'export** : ext4 / xfs / btrfs recommandés ; exFAT / NTFS acceptés (droits non conservés, exports complets) ; FAT32 refusé.
- **Sur le volume** : `<BACKUP_ROOT>/<source>/mirror/` et `<BACKUP_ROOT>/<source>/snaps/<date>/` (`.SUSPECT` si alerte). Réglages et états : `/etc/homelab-backup`, `/var/lib/homelab-backup`.
- **Sur le disque d'export** : `HOMELAB-BACKUP` (marqueur) et `homelab-backup/<source>/<instantané>/` (contenant `.export-complete`).

## Actions à distance par Telegram (optionnel, désactivé par défaut)
`"TELEGRAM_ACTIONS": "backup power"` + `TELEGRAM_ADMIN_ID` dans `backup.json`, puis `./install.sh`. Utilise un bot **différent** de celui du serveur principal.

Sécurité (un compte ou un jeton Telegram volé ne suffit pas) :
- chaque action exige un **code TOTP** (secret sur le serveur, `homelab-backup-ctl totp-show`) ; 3 codes faux = verrouillage 30 min + alerte ; un code ne sert qu'une fois ;
- discussion privée et `TELEGRAM_ADMIN_ID` uniquement ;
- le bot tourne sous `hb-bot`, sans privilège ; il n'appelle que `homelab-backup-actions` via un sudo restreint, liste fermée : `run check restoretest keep-on keep-off poweroff reboot cancel status` ;
- volontairement absent : acquitter une alerte, réparer, restaurer, modifier la configuration ;
- chaque action est journalisée (`/var/log/homelab-backup-actions.log`) et notifiée ; arrêt/redémarrage après `TELEGRAM_ACTION_DELAY` s (`/annuler`).

Commandes : `/etat`, `/sauvegarder`, `/integrite`, `/testrestauration`, `/rester_allume`, `/extinction_auto`, `/eteindre`, `/redemarrer`, `/annuler` (code à 6 chiffres à la fin). Un serveur éteint ne peut pas être réveillé par Telegram (alarme RTC ou Wake-on-LAN).

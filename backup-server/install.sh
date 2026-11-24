#!/usr/bin/env bash
# Installation du SERVEUR DE SAUVEGARDE (N54L sous Proxmox/Debian).
# À lancer en root sur le N54L, depuis le dossier décompressé. Idempotent.
#
# Principe : ce serveur va CHERCHER les données (tirage) ; aucun serveur source n'a
# la moindre clé ou le moindre accès vers lui. Il n'est allumé que pour la sauvegarde.
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC=/etc/homelab-backup
[[ $EUID -eq 0 ]] || { echo "À lancer en root." >&2; exit 1; }

echo "== Paquets"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y rsync msmtp smartmontools util-linux curl wireguard-tools ntfs-3g zstd lzop jq sudo python3 >/dev/null

echo "== Fichiers"
install -d -m 755 /usr/local/lib/homelab-backup
install -m 644 "$SRC_DIR/lib/lib.sh" /usr/local/lib/homelab-backup/lib.sh
install -m 644 "$SRC_DIR/lib/admin.sh" /usr/local/lib/homelab-backup/admin.sh
install -m 755 "$SRC_DIR/lib/verify.py" /usr/local/lib/homelab-backup/verify.py
install -m 755 "$SRC_DIR/lib/totp.py" /usr/local/lib/homelab-backup/totp.py
for b in homelab-backup-run homelab-backup-export homelab-backup-check homelab-backup-restoretest homelab-backup-net homelab-backup-volume homelab-backup-ctl homelab-backup-actions homelab-backup-bot; do
    install -m 755 "$SRC_DIR/bin/$b" "/usr/local/sbin/$b"
done
ln -sf /usr/local/sbin/homelab-backup-ctl /usr/local/bin/homelab-backup-ctl
install -d -m 700 "$ETC" "$ETC/sources.d" /var/lib/homelab-backup
install -d -m 755 /usr/local/share/homelab-backup
install -m 644 "$SRC_DIR/conf/schema.txt" /usr/local/share/homelab-backup/schema.txt
install -m 644 "$SRC_DIR/conf/source.json.example" /usr/local/share/homelab-backup/source.json.example

# shellcheck disable=SC1091
source /usr/local/lib/homelab-backup/lib.sh

if [[ ! -f "$ETC/backup.json" ]]; then
    ( umask 077; hb_schema_json > "$ETC/backup.json" )
    install -m 600 /usr/local/share/homelab-backup/source.json.example "$ETC/sources.d/exemple.json.disabled"
    echo
    echo "Configuration créée : $ETC/backup.json"
    if [[ -f "$ETC/backup.conf" ]]; then
        echo "  (l'ancien $ETC/backup.conf n'est plus lu : reporte-y tes valeurs ; les anciens sources.d/*.conf non plus :"
        echo "   refais « homelab-backup-ctl request <nom> » pour chaque serveur sauvegardé)"
    fi
    echo "  1. Édite-la (volume de sauvegarde, mail, seuil...). homelab-backup-ctl describe NOM explique une variable."
    echo "  2. Ajoute une source par serveur : homelab-backup-ctl request <nom> (ou copie $ETC/sources.d/exemple.json.disabled en"
    echo "     $ETC/sources.d/<nom>.json)"
    echo "  3. Relance ./install.sh"
    exit 0
fi

# Configuration existante : les variables apparues depuis la dernière version sont AJOUTÉES (tes valeurs
# sont conservées, l'ancien fichier est gardé en .bak). Si c'est le cas, on s'arrête pour que tu les vérifies.
rc=0
hb_merge_conf /usr/local/share/homelab-backup/schema.txt "$ETC/backup.json" || rc=$?
if (( rc == 10 )) && [[ "${HB_SKIP_CONF_CHECK:-}" != "1" ]]; then
    echo
    echo "ARRÊT : complète les nouvelles variables si besoin (les valeurs par défaut sont déjà bonnes),"
    echo "puis relance l'installation (ou : HB_SKIP_CONF_CHECK=1 ./install.sh)."
    exit 0
fi

hb_load_conf || exit 1
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backups}"

echo "== Compte administrateur / SSH"
# shellcheck disable=SC1091
source /usr/local/lib/homelab-backup/admin.sh
hb_configure_admin || echo "(compte/SSH non modifié : voir le message ci-dessus)"

echo "== Volume de sauvegarde"
if mountpoint -q "${BACKUP_MOUNT:-$BACKUP_ROOT}"; then
    echo "Déjà monté : ${BACKUP_MOUNT:-$BACKUP_ROOT}"
elif [[ -t 0 ]]; then
    echo "Le volume de sauvegarde n'est pas monté : recherche d'un RAID / disque existant (rien ne sera formaté)."
    homelab-backup-volume || echo "(volume non configuré : relance plus tard  homelab-backup-ctl volume)"
    hb_load_conf || exit 1
else
    echo "Volume non monté et pas de terminal : lance  homelab-backup-ctl volume  dans une session interactive."
fi

echo "== Clé SSH de tirage"
if [[ ! -f /root/.ssh/homelab-pull ]]; then
    install -d -m 700 /root/.ssh
    ssh-keygen -q -t ed25519 -N "" -C "homelab-pull@$(hostname -s)" -f /root/.ssh/homelab-pull
fi

echo "== Mail (msmtp)"
if [[ -n "${SMTP_HOST:-}" ]]; then
    tls_opts="tls on
tls_starttls on"
    case "${SMTP_TLS:-starttls}" in
        tls)  tls_opts="tls on
tls_starttls off";;
        off)  tls_opts="tls off";;
    esac
    umask 077
    {
        echo "defaults"
        echo "$tls_opts"
        echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
        echo "logfile /var/log/msmtp.log"
        echo "account homelab"
        echo "host $SMTP_HOST"
        echo "port ${SMTP_PORT:-587}"
        echo "from ${MAIL_FROM:-$MAIL_TO}"
        if [[ -n "${SMTP_USER:-}" ]]; then
            echo "auth on"
            echo "user $SMTP_USER"
            echo "password $SMTP_PASSWORD"
        fi
        echo "account default : homelab"
    } > "$ETC/msmtprc"
    chmod 600 "$ETC/msmtprc"
else
    echo "SMTP_HOST vide : pas d'alertes par mail (les messages iront dans le journal)."
fi

echo "== Services systemd et règle udev"
cat > /etc/systemd/system/homelab-backup.service <<UNIT
[Unit]
Description=Sauvegarde homelab par tirage (réveil hebdomadaire)
After=network-online.target local-fs.target
Wants=network-online.target
RequiresMountsFor=${BACKUP_MOUNT:-$BACKUP_ROOT}

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-backup-run
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/homelab-backup-export@.service <<'UNIT'
[Unit]
Description=Export des sauvegardes vers le disque externe %I

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-backup-export /dev/%I
TimeoutStartSec=infinity
UNIT

# Alertes d'allumage et d'extinction (catégorie « power » de TELEGRAM_EVENTS)
cat > /usr/local/sbin/homelab-backup-power-notify <<'POWER'
#!/usr/bin/env bash
# Usage : homelab-backup-power-notify start|stop   (appelé par homelab-backup-power.service)
set -u
HB_LIB="${HB_LIB:-/usr/local/lib/homelab-backup/lib.sh}"
# shellcheck disable=SC1090
source "$HB_LIB"
hb_load_conf || exit 0

nw="$(cat "$HB_STATE/next-wake" 2>/dev/null || echo 0)"
planned="aucun réveil programmé"
(( nw > 0 )) && planned="réveil programmé : $(date -d "@$nw" '+%F %T')"

case "${1:-}" in
    start)
        for _ in $(seq 1 10); do getent hosts api.telegram.org >/dev/null 2>&1 && break; sleep 3; done
        if (( nw > 0 )) && (( $(date +%s) - nw < 1800 && $(date +%s) - nw > -1800 )); then
            why="Réveil prévu : la sauvegarde va démarrer."
        else
            why="Démarrage hors planning (manuel ou coupure de courant) : pas de sauvegarde ni d'extinction automatiques ; ${planned}."
        fi
        hb_notify power "Serveur allumé" "${why} Volume de sauvegarde : $(mountpoint -q "${BACKUP_MOUNT:-$BACKUP_ROOT}" && echo monté || echo 'NON MONTÉ')."
        ;;
    stop)
        if systemctl list-jobs 2>/dev/null | grep -q 'reboot.target'; then what="redémarrage"; else what="extinction"; fi
        hb_notify power "Serveur : ${what}" "Le serveur s'arrête (${what}) ; ${planned}."
        ;;
esac
exit 0
POWER
chmod 755 /usr/local/sbin/homelab-backup-power-notify

cat > /etc/systemd/system/homelab-backup-power.service <<'UNIT'
[Unit]
Description=Alertes d'allumage et d'extinction du serveur de sauvegarde
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/homelab-backup-power-notify start
ExecStop=/usr/local/sbin/homelab-backup-power-notify stop
TimeoutStartSec=90
TimeoutStopSec=40

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/udev/rules.d/99-homelab-backup-export.rules <<'RULE'
# Un disque avec système de fichiers est branché : l'export ne s'active que s'il porte le fichier marqueur.
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="homelab-backup-export@%k.service"
RULE

echo "== Telegram : actions à distance (bot sans privilège)"
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_ACTIONS// /}" ]]; then
    [[ "${TELEGRAM_ADMIN_ID:-}" =~ ^[0-9]{1,15}$ ]] || { echo "TELEGRAM_ACTIONS demande TELEGRAM_ADMIN_ID (identifiant numérique) : homelab-backup-ctl telegram-id" >&2; exit 1; }
    for g in $TELEGRAM_ACTIONS; do [[ "$g" =~ ^(backup|power)$ ]] || { echo "TELEGRAM_ACTIONS : « $g » inconnu (backup | power)" >&2; exit 1; }; done
    id hb-bot >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin hb-bot
    printf 'hb-bot ALL=(root) NOPASSWD: /usr/local/sbin/homelab-backup-actions\n' > /etc/sudoers.d/homelab-backup-bot.tmp
    chmod 0440 /etc/sudoers.d/homelab-backup-bot.tmp
    if visudo -cf /etc/sudoers.d/homelab-backup-bot.tmp >/dev/null 2>&1; then mv /etc/sudoers.d/homelab-backup-bot.tmp /etc/sudoers.d/homelab-backup-bot
    else rm -f /etc/sudoers.d/homelab-backup-bot.tmp; echo "Règle sudo invalide : abandon." >&2; exit 1; fi
    # /etc/homelab-backup est en 0700 : le bot lit son seul fichier, dans un dossier à part
    install -d -m 755 /etc/homelab-backup-bot
    printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\nTELEGRAM_ADMIN_ID=%q\nTELEGRAM_ACTIONS=%q\n' \
        "$TELEGRAM_BOT_TOKEN" "${TELEGRAM_CHAT_ID:-}" "$TELEGRAM_ADMIN_ID" "$TELEGRAM_ACTIONS" > /etc/homelab-backup-bot/telegram.conf
    chown root:hb-bot /etc/homelab-backup-bot/telegram.conf; chmod 0640 /etc/homelab-backup-bot/telegram.conf
    [[ -s "$ETC/totp.secret" ]] || { homelab-backup-ctl totp-show; }
    cat > /etc/systemd/system/homelab-backup-bot.service <<'UNIT'
[Unit]
Description=Bot Telegram du serveur de sauvegarde (sans privilège, actions via sudo restreint)
After=network-online.target
Wants=network-online.target

[Service]
User=hb-bot
Group=hb-bot
StateDirectory=homelab-backup-bot
Environment=BOT_CONF=/etc/homelab-backup-bot/telegram.conf
ExecStart=/usr/local/sbin/homelab-backup-bot
Restart=always
RestartSec=10
ProtectHome=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now homelab-backup-bot.service >/dev/null 2>&1 || echo "(bot Telegram non démarré : journalctl -u homelab-backup-bot)"
else
    systemctl disable --now homelab-backup-bot.service >/dev/null 2>&1 || true
    echo "Actions Telegram : aucune (TELEGRAM_ACTIONS vide) : pas de bot de commande."
fi

systemctl daemon-reload
udevadm control --reload
systemctl enable homelab-backup.service >/dev/null
systemctl enable homelab-backup-power.service >/dev/null

if [[ "${NETWORK_MODE:-}" == "dhcp" ]]; then
    echo "== Réseau : DHCP"
    homelab-backup-net dhcp
fi

homelab-backup-ctl arm

echo
echo "================ À FAIRE ================"
echo "1) Pour CHAQUE serveur Proxmox à sauvegarder :  homelab-backup-ctl request <nom>   (donne la ligne à coller sur ce serveur,"
echo "   puis le paquet à coller ici avec  homelab-backup-ctl add-source). Sans demande, à la main : dans le fichier de réponses"
echo "   de l'installateur (proxmox-homelab-answers.json, groupe sauvegardes) :"
echo "     \"ENABLE_BACKUP_PULL\": true,  \"BACKUP_PULL_FROM\": \"\",  \"BACKUP_PULL_PUBKEY\": \"$(cat /root/.ssh/homelab-pull.pub)\""
echo "   puis relancer l'installateur (ou ./install.sh --run configure_backup_pull_access)."
echo "2) Ici : un fichier $ETC/sources.d/<nom>.json par serveur (créé par add-source)."
echo "3) Teste :  homelab-backup-ctl test-mail   puis   homelab-backup-ctl run"
echo "4) Quand c'est bon :  homelab-backup-ctl poweroff   (réveil auto : ${WAKE_DAY:-Sunday} ${WAKE_TIME:-03:00})"
echo "   Vérifie que le réveil fonctionne (alarme RTC) en le testant une fois à la main."
echo "5) Disque externe : crée un fichier vide nommé ${EXPORT_MARKER:-HOMELAB-BACKUP} à sa racine."
echo
echo "Diagnostic du RAID existant :  homelab-backup-ctl diagnose"

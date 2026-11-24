###############################################################################
#                EXPORT VERS DISQUE EXTERNE (BRANCHER = COPIER)               #
###############################################################################

# Branche un disque USB portant un fichier BACKUP_USB_MARKER à sa racine : le serveur y copie sa
# dernière sauvegarde (vzdump des VM/CT, et selon le fichier : dossiers d'applications, partage SHARED).
# Un disque sans ce fichier n'est jamais touché (monté en lecture seule le temps de vérifier).
#
# Contenu facultatif du fichier marqueur (texte, une option par ligne, # = commentaire) :
#   content=dump,apps,shared   ce qui est copié (défaut : BACKUP_USB_CONTENT)
#                                dump   = dernière sauvegarde vzdump de chaque VM/CT
#                                apps   = dossiers d'applications (Immich, Nextcloud, mails...)
#                                shared = partage Samba SHARED (volumineux)
#   fresh=yes                  lance d'abord une nouvelle sauvegarde vzdump (plus long)
#   keep=2                     nombre d'exports conservés sur le disque (défaut : BACKUP_USB_KEEP)
#
# Le script installé est aussi utilisable à la main : homelab-usb-export --dir /point/de/montage

configure_usb_export() {

    [[ "$ENABLE_BACKUP_USB" == "true" ]] || return 0

    info "Export vers disque externe : installation..."

    # Pilote NTFS (exFAT est géré par le noyau)
    command -v mount.ntfs >/dev/null 2>&1 || apt-get install -y ntfs-3g >/dev/null 2>&1 || true

    local dump_dir="${PROXMOX_DATA_DIR}/dump"

    install -d -m 755 /usr/local/sbin

    cat > /usr/local/sbin/homelab-usb-export <<'USB_EXPORT_SCRIPT'
#!/usr/bin/env bash
# Généré par l'installateur homelab (host/55-usb-export.sh). Ne pas modifier : relancer l'installateur.
set -Eeuo pipefail

DUMP_DIR="@@DUMP_DIR@@"
APPS_DIR="@@APPS_DIR@@"
SHARED_DIR="@@SHARED_DIR@@"
EXTRA_SITES="@@EXTRA_SITES@@"   # sites secondaires : domaine|dossier_apps|dossier_shared, séparés par des espaces
STORAGE="@@STORAGE@@"
VZ_MODE="@@VZ_MODE@@"
VZ_COMPRESS="@@VZ_COMPRESS@@"
MARKER="@@MARKER@@"
DEF_CONTENT="@@CONTENT@@"
DEF_KEEP="@@KEEP@@"
WEBHOOK="@@WEBHOOK@@"
ALLOWED_UUIDS="@@UUIDS@@"
LOG=/var/log/homelab-usb-export.log

log() { local m; m="$(date '+%F %T') $*"; echo "$m"; echo "$m" >> "$LOG" 2>/dev/null || true; }

notify() {   # notify "titre" "texte"
    log "$1 — $2"
    command -v wall >/dev/null 2>&1 && echo "[homelab] $1 : $2" | wall 2>/dev/null || true
    if [[ -n "$WEBHOOK" ]]; then
        curl -fsS -m 15 -H "Title: $1" -d "$2" "$WEBHOOK" >/dev/null 2>&1 || true
    fi
    [[ -x /usr/local/sbin/homelab-notify ]] && /usr/local/sbin/homelab-notify -p default -t floppy_disk -c usb "$1" "$2" || true
}

MNT="" DEV="" OWN_MOUNT=0
if [[ "${1:-}" == "--dir" ]]; then
    MNT="${2:?point de montage manquant}"
else
    DEV="${1:?périphérique manquant}"
    [[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
fi

exec 8>/run/homelab-usb-export.lock
flock -n 8 || { log "Export : un autre export est en cours."; exit 0; }

cleanup() {
    if (( OWN_MOUNT )) && mountpoint -q "$MNT"; then sync; umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; fi
}
trap cleanup EXIT

# --- Montage prudent : lecture seule d'abord, pour chercher le marqueur -------------------
if [[ -z "$MNT" ]]; then
    [[ -b "$DEV" ]] || exit 0
    findmnt -rn -S "$DEV" >/dev/null 2>&1 && exit 0                 # déjà monté (ex. disque DATA) : jamais touché
    fstype="$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)"
    case "$fstype" in ""|swap|linux_raid_member|LVM2_member|zfs_member|crypto_LUKS|bcache) exit 0;; esac

    uuid="$(blkid -o value -s UUID "$DEV" 2>/dev/null || true)"
    # Alerte de branchement : tout disque USB reconnu, avec ou sans marqueur.
    [[ -x /usr/local/sbin/homelab-notify ]] && /usr/local/sbin/homelab-notify -p default -t floppy_disk -c usb \
        "Disque USB branché" "${DEV} : $(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null | xargs) · ${fstype} · étiquette « $(blkid -o value -s LABEL "$DEV" 2>/dev/null || true) » · UUID ${uuid:-?}. Export seulement s'il porte le fichier ${MARKER}." || true
    if [[ -n "$ALLOWED_UUIDS" ]] && ! grep -qw -- "$uuid" <<<"$ALLOWED_UUIDS"; then
        log "Export : disque $DEV (UUID $uuid) non autorisé, ignoré."
        exit 0
    fi

    MNT="/mnt/homelab-usb-export"
    mkdir -p "$MNT"
    mountpoint -q "$MNT" && exit 0
    mount -o ro,nosuid,nodev,noexec "$DEV" "$MNT" 2>/dev/null || { log "Export : $DEV (type ${fstype}) ne peut pas être monté (pilote absent ? NTFS : apt install ntfs-3g)."; rmdir "$MNT" 2>/dev/null || true; exit 0; }
    OWN_MOUNT=1
    [[ -f "$MNT/$MARKER" ]] || exit 0                                # disque ordinaire : on ne touche à rien
    mount -o remount,rw "$MNT" || { notify "Export impossible" "$DEV ne peut pas être monté en écriture."; exit 1; }
fi

[[ -f "$MNT/$MARKER" ]] || { log "Pas de fichier $MARKER dans $MNT."; exit 0; }

# --- Options du marqueur (lues sans être exécutées) ----------------------------------------
opt() { sed -n "s/^$1[[:space:]]*=//p" "$MNT/$MARKER" | sed 's/#.*//' | tr -d '\r' | head -n1 | xargs 2>/dev/null || true; }
content="$(opt content)"; content="${content:-$DEF_CONTENT}"; content="${content//,/ }"
fresh="$(opt fresh)"
keep="$(opt keep | tr -dc '0-9')"; keep="${keep:-$DEF_KEEP}"; (( keep >= 1 )) || keep=1

fs="$(findmnt -no FSTYPE -T "$MNT" 2>/dev/null || true)"
case "$fs" in
    vfat|msdos|fat)
        notify "Export refusé : disque en FAT32" "Le disque ($fs) limite les fichiers à 4 Go : les sauvegardes ne peuvent pas y être copiées. Utilise ext4, xfs, btrfs, exFAT ou NTFS."
        exit 1;;
esac
case "$fs" in
    ext2|ext3|ext4|xfs|btrfs|f2fs) RS=(-aHAX --numeric-ids); LINK=1;;
    *) RS=(-rt --no-perms --no-owner --no-group --modify-window=2); LINK=0   # pas de liens symboliques ni de fichiers spéciaux
       log "Export : système de fichiers '$fs' sans droits Unix : permissions et propriétaires NON conservés.";;
esac

host="$(hostname -s)"
stamp="$(date +%F_%H%M%S)"
base="$MNT/homelab-export/$host"
dest="$base/$stamp"
REPORT="" FAILS=0
add() { REPORT+="$*"$'\n'; }

log "=== Export vers le disque externe ($MNT) : $content ==="

# Exports incomplets d'une tentative précédente
mkdir -p "$base"
for d in "$base"/*/; do [[ -d "$d" && ! -f "${d}.export-complete" ]] && rm -rf "$d"; done
mkdir -p "$dest"
prev="$(find "$base" -mindepth 1 -maxdepth 1 -type d ! -name "$stamp" -printf '%f\n' | sort | tail -n1)"

# --- 1. Sauvegarde vzdump ----------------------------------------------------------------------
if grep -qw dump <<<"$content"; then
    if [[ "$fresh" =~ ^(yes|oui|true|1)$ ]]; then
        log "Nouvelle sauvegarde vzdump demandée (fresh=yes)..."
        if vzdump --all --storage "$STORAGE" --mode "$VZ_MODE" --compress "$VZ_COMPRESS" >>"$LOG" 2>&1; then
            add "Nouvelle sauvegarde vzdump réalisée."
        else
            add "⚠ La nouvelle sauvegarde vzdump a échoué : on exporte la dernière existante."; FAILS=$(( FAILS + 1 ))
        fi
    fi

    list="$(mktemp)"
    # dernière sauvegarde de chaque VM/CT : type, id, horodatage
    ls -1 "$DUMP_DIR" 2>/dev/null | sed -n 's/^vzdump-\(qemu\|lxc\)-\([0-9]\+\)-\([0-9_-]\+\)\..*/\1 \2 \3/p' | sort -u |
        awk '{k=$1" "$2; if ($3 > ts[k]) ts[k]=$3} END {for (k in ts) print k, ts[k]}' > "$list.ids"

    : > "$list"
    while read -r t id ts; do
        for f in "$DUMP_DIR"/vzdump-"$t"-"$id"-"$ts".*; do [[ -f "$f" ]] && echo "$f" >> "$list"; done
    done < "$list.ids"

    if [[ ! -s "$list" ]]; then
        add "⚠ Aucune sauvegarde vzdump trouvée dans $DUMP_DIR."; FAILS=$(( FAILS + 1 ))
    else
        need="$(xargs -d '\n' du -cb < "$list" | tail -n1 | cut -f1)"
        avail="$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')"
        if (( need > avail )); then
            add "⚠ Espace insuffisant pour la sauvegarde vzdump : $(( need / 1048576 )) Mo nécessaires, $(( avail / 1048576 )) Mo disponibles. Supprime d'anciens exports du disque ou utilise un disque plus grand."
            FAILS=$(( FAILS + 1 ))
        else
            mkdir -p "$dest/dump"
            if xargs -d '\n' -I{} cp -p {} "$dest/dump/" < "$list"; then
                add "Sauvegarde vzdump copiée : $(wc -l < "$list.ids") VM/CT ($(( need / 1048576 )) Mo)."
            else
                add "⚠ Échec de la copie vzdump (disque plein ?)."; FAILS=$(( FAILS + 1 ))
            fi
        fi
    fi
    rm -f "$list" "$list.ids"
fi

# --- 2. Dossiers d'applications / SHARED -----------------------------------------------------------
copy_tree() {   # copy_tree <nom> <source>
    local n="$1" src="$2" opts=("${RS[@]}")
    [[ -d "$src" ]] || { add "⚠ $n : $src introuvable."; FAILS=$(( FAILS + 1 )); return; }
    (( LINK )) && [[ -n "$prev" && -d "$base/$prev/$n" ]] && opts+=(--link-dest="$base/$prev/$n")
    mkdir -p "$dest/$n"
    if rsync "${opts[@]}" "$src/" "$dest/$n/" >>"$LOG" 2>&1; then
        add "$n copié."
    else
        add "⚠ Échec de la copie de $n (disque plein ? voir $LOG)."; FAILS=$(( FAILS + 1 ))
    fi
}
grep -qw apps   <<<"$content" && copy_tree apps "$APPS_DIR"
grep -qw shared <<<"$content" && copy_tree shared "$SHARED_DIR"
for _s in $EXTRA_SITES; do
    IFS='|' read -r _d _a _sh <<<"$_s"
    grep -qw apps   <<<"$content" && copy_tree "sites/${_d}/apps" "$_a"
    grep -qw shared <<<"$content" && copy_tree "sites/${_d}/shared" "$_sh"
done

# --- 3. Clôture, rotation -----------------------------------------------------------------------------------
if (( FAILS == 0 )); then
    date -Is > "$dest/.export-complete"
    mapfile -t all < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    if (( ${#all[@]} > keep )); then
        for (( i = 0; i < ${#all[@]} - keep; i++ )); do rm -rf "${base:?}/${all[i]}"; done
    fi
else
    rm -rf "${dest:?}"      # un export partiel ne doit pas passer pour une sauvegarde
fi

add "Espace libre sur le disque : $(df -h --output=avail "$MNT" | tail -n1 | xargs)"
sync
if (( FAILS )); then
    notify "Export disque externe : ÉCHEC" "$(echo "$REPORT" | tr '\n' ' ')"
else
    notify "Export terminé : tu peux débrancher le disque" "$(echo "$REPORT" | tr '\n' ' ')"
fi
USB_EXPORT_SCRIPT

    local extra_sites="" _d
    for _d in "${SITE_LIST[@]}"; do
        [[ "$_d" == "$SITE_PRIMARY" ]] || extra_sites+="${extra_sites:+ }${_d}|${SITE_APPS[$_d]}|${SITE_SHARED[$_d]}"
    done

    sed -i \
        -e "s|@@DUMP_DIR@@|${dump_dir}|" \
        -e "s|@@APPS_DIR@@|${APPS_DIR}|" \
        -e "s|@@SHARED_DIR@@|${SHARED_DIR}|" \
        -e "s|@@EXTRA_SITES@@|${extra_sites}|" \
        -e "s|@@STORAGE@@|${BACKUP_STORAGE}|" \
        -e "s|@@VZ_MODE@@|${BACKUP_MODE}|" \
        -e "s|@@VZ_COMPRESS@@|${BACKUP_COMPRESS}|" \
        -e "s|@@MARKER@@|${BACKUP_USB_MARKER}|" \
        -e "s|@@CONTENT@@|${BACKUP_USB_CONTENT}|" \
        -e "s|@@KEEP@@|${BACKUP_USB_KEEP}|" \
        -e "s|@@WEBHOOK@@|${BACKUP_USB_WEBHOOK}|" \
        -e "s|@@UUIDS@@|${BACKUP_USB_ALLOWED_UUIDS}|" \
        /usr/local/sbin/homelab-usb-export
    chmod 755 /usr/local/sbin/homelab-usb-export

    cat > /etc/systemd/system/homelab-usb-export@.service <<'UNIT'
[Unit]
Description=Export de la sauvegarde vers le disque externe %I

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-usb-export /dev/%I
TimeoutStartSec=infinity
UNIT

    cat > /etc/udev/rules.d/99-homelab-usb-export.rules <<'RULE'
# Disque USB avec système de fichiers branché : l'export ne s'active que s'il porte le fichier marqueur.
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="homelab-usb-export@%k.service"
RULE

    systemctl daemon-reload
    udevadm control --reload

    info "Export vers disque externe : prêt. Crée un fichier '${BACKUP_USB_MARKER}' à la racine d'un disque USB (ext4/xfs/btrfs de préférence) et branche-le."
    info "Options dans ce fichier : content=dump,apps,shared  fresh=yes  keep=2  (défaut : ${BACKUP_USB_CONTENT}, ${BACKUP_USB_KEEP} exports)."
}

# Lance l'export à la main sur un disque déjà monté : ./install.sh --run usb_export_now /mnt/disque
usb_export_now() {

    local dir="${1:-}"

    [[ -n "$dir" && -d "$dir" ]] || die "Usage : usb_export_now /point/de/montage (avec le fichier ${BACKUP_USB_MARKER} à la racine)"
    [[ -x /usr/local/sbin/homelab-usb-export ]] || die "Export non installé : ENABLE_BACKUP_USB=true puis ./install.sh --run configure_usb_export"

    /usr/local/sbin/homelab-usb-export --dir "$dir"
}

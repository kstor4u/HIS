###############################################################################
#                     VOLUME EXISTANT (RAID / DISQUE DE DONNÉES)              #
###############################################################################

# Avant de proposer le formatage de DATA_DISK, on cherche un volume EXISTANT à réutiliser :
# grappes RAID logicielles (mdadm) assemblées automatiquement, volumes LVM, systèmes de fichiers
# ext4 / xfs / btrfs. Rien n'est jamais formaté ni modifié pour cela : le volume choisi est
# simplement monté sur DATA_MOUNT (DATA_EXISTING_DEVICE).

# Assemble les grappes mdadm trouvées sur les disques (même créées sur une autre machine, ex. Ubuntu)
# et active les volumes LVM. Les grappes incomplètes (dégradées) ne sont PAS démarrées ici.
assemble_existing_arrays() {

    if ! command -v mdadm >/dev/null 2>&1; then
        apt-get install -y mdadm >/dev/null 2>&1 || true
    fi

    if command -v mdadm >/dev/null 2>&1; then
        local conf
        conf="$(mktemp)"
        mdadm --examine --scan > "$conf" 2>/dev/null || true
        if [[ -s "$conf" ]]; then
            mdadm --assemble --scan --config="$conf" --no-degraded >/dev/null 2>&1 || true
        fi
        rm -f "$conf"
    fi

    if command -v vgchange >/dev/null 2>&1; then
        vgchange -ay >/dev/null 2>&1 || true
    fi

    udevadm settle 2>/dev/null || true
}

# Lignes "périphérique|type|taille|label|montage|origine" des systèmes de fichiers réutilisables.
# Exclut le système, le swap, les disques de VM/CT de Proxmox et les membres de RAID.
list_existing_volumes() {

    local line origin
    local NAME FSTYPE SIZE LABEL MOUNTPOINT TYPE
    while IFS= read -r line; do

        # lsblk -P : paires CLE="valeur" ; les caractères spéciaux y sont échappés (\xNN), donc eval sûr
        NAME="" FSTYPE="" SIZE="" LABEL="" MOUNTPOINT="" TYPE=""
        eval "$line"

        case "$FSTYPE" in ext4 | xfs | btrfs) ;; *) continue ;; esac
        [[ "$NAME" == *--disk--* || "$NAME" == */pve-* || "$NAME" == /dev/pve/* ]] && continue
        case "$MOUNTPOINT" in / | /boot | /boot/efi | "[SWAP]") continue ;; esac

        case "$TYPE" in
            raid*) origin="RAID" ;;
            lvm)   origin="LVM" ;;
            *)     origin="disque" ;;
        esac

        printf '%s|%s|%s|%s|%s|%s\n' "$NAME" "$FSTYPE" "$SIZE" "${LABEL:--}" "${MOUNTPOINT:--}" "$origin"
    done < <(lsblk -prP -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT,TYPE 2>/dev/null)
}

# Interactif : propose les volumes existants. Positionne DATA_EXISTING_DEVICE si l'un est choisi.
# Ne formate jamais rien. Sans choix, le script continue avec DATA_DISK (formatage confirmé ensuite).
choose_existing_volume() {

    local -a vols=()
    local line

    assemble_existing_arrays

    while IFS= read -r line; do
        [[ -n "$line" ]] && vols+=("$line")
    done < <(list_existing_volumes)

    # Grappes détectées mais non démarrées (dégradées / incomplètes)
    if command -v mdadm >/dev/null 2>&1; then
        local inactive
        inactive="$(awk '/^md[0-9]+ : inactive/ {print $1}' /proc/mdstat 2>/dev/null | tr '\n' ' ')"
        if [[ -n "$inactive" ]]; then
            warn "Grappe(s) RAID incomplète(s) non démarrée(s) : ${inactive}(disque manquant ?). Voir : cat /proc/mdstat ; mdadm --detail --scan"
        fi
    fi

    (( ${#vols[@]} > 0 )) || return 0

    echo
    echo "Volumes existants détectés (réutilisables SANS formatage) :"
    local i=1 dev fstype size label mnt origin
    for line in "${vols[@]}"; do
        IFS='|' read -r dev fstype size label mnt origin <<< "$line"
        printf '  %d) %-22s %-6s %-8s %-7s label=%s  monté: %s\n' "$i" "$dev" "$fstype" "$size" "$origin" "$label" "$mnt"
        i=$(( i + 1 ))
    done
    echo "  f) Ignorer ces volumes et formater ${DATA_DISK} (efface TOUT, confirmation demandée)"
    echo "  q) Quitter"
    echo

    local choice
    read -r -p "Que faire ? [1-$(( ${#vols[@]} )) / f / q] : " choice

    case "$choice" in
        q | Q) die "Abandon à la demande de l'utilisateur." ;;
        f | F | "") return 0 ;;
    esac

    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#vols[@]} )) \
        || die "Choix invalide : ${choice}"

    IFS='|' read -r dev fstype size label mnt origin <<< "${vols[choice-1]}"

    if [[ "$mnt" != "-" && "$mnt" != "$DATA_MOUNT" ]]; then
        die "${dev} est déjà monté sur ${mnt} : démonte-le (umount ${mnt}) puis relance."
    fi

    # Aperçu en lecture seule avant de s'engager
    local preview
    preview="$(mktemp -d)"
    if [[ "$mnt" == "-" ]] && mount -o ro "$dev" "$preview" 2>/dev/null; then
        echo
        echo "Contenu de ${dev} (premier niveau) :"
        ls -la "$preview" | head -n 15
        df -h --output=size,used,avail "$preview" | tail -n1
        umount "$preview"
    fi
    rmdir "$preview" 2>/dev/null || true

    echo
    read -r -p "Utiliser ${dev} tel quel comme disque DATA, monté sur ${DATA_MOUNT} (aucun formatage) ? [o/N] : " choice
    [[ "$choice" =~ ^[oOyY]$ ]] || die "Abandon : rien n'a été modifié."

    DATA_EXISTING_DEVICE="$dev"
}

# Monte DATA_EXISTING_DEVICE sur DATA_MOUNT (fstab par UUID) sans rien formater.
use_existing_data_volume() {

    local dev="$DATA_EXISTING_DEVICE" fstype uuid

    assemble_existing_arrays

    [[ -b "$dev" ]] || die "DATA_EXISTING_DEVICE introuvable : ${dev}"

    fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
    case "$fstype" in
        ext4 | xfs | btrfs) ;;
        *) die "${dev} : système de fichiers '${fstype:-aucun}' non pris en charge (ext4, xfs ou btrfs attendus). Rien n'a été modifié." ;;
    esac

    uuid="$(blkid -s UUID -o value "$dev")"
    [[ -n "$uuid" ]] || die "Impossible de lire l'UUID de ${dev}."

    info "Volume existant réutilisé SANS formatage : ${dev} (${fstype}) sur ${DATA_MOUNT}."

    # Grappe mdadm : la déclarer pour qu'elle soit réassemblée au démarrage
    local md
    md="$(lsblk -nsro NAME,TYPE "$dev" 2>/dev/null | awk '$2 ~ /^raid/ {print "/dev/" $1; exit}' || true)"
    [[ "$dev" == /dev/md* ]] && md="$dev"

    [[ -n "$md" ]] && persist_md_array "$md"

    mkdir -p "$DATA_MOUNT"

    if grep -qE "[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab; then
        cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
        sed -i "\|[[:space:]]${DATA_MOUNT}[[:space:]]|d" /etc/fstab
    fi

    printf 'UUID=%s %s %s defaults,noatime,x-systemd.device-timeout=60s 0 2\n' \
        "$uuid" "$DATA_MOUNT" "$fstype" >> /etc/fstab

    systemctl daemon-reload 2>/dev/null || true

    if ! mountpoint -q "$DATA_MOUNT"; then
        mount "$DATA_MOUNT"
    fi

    mountpoint -q "$DATA_MOUNT" || die "${DATA_MOUNT} n'est pas monté."

    findmnt -rn -T "$DATA_MOUNT" -o SOURCE,FSTYPE,TARGET
}


###############################################################################
#            CHOIX DU DISQUE / DE LA GRAPPE RAID À FORMATER (liste détectée)   #
###############################################################################

# Partition de données d'un périphérique : une grappe RAID (ou volume LVM/dm) est formatée en entier,
# un disque reçoit une partition (sdb1, nvme0n1p1, mmcblk0p1).
data_partition_for() {

    local dev="$1"

    case "$dev" in
        /dev/md* | /dev/dm-* | /dev/mapper/*) printf '%s' "$dev" ;;
        /dev/nvme* | /dev/mmcblk* | /dev/loop*) printf '%sp1' "$dev" ;;
        *) printf '%s1' "$dev" ;;
    esac
}

# Déclare une grappe mdadm dans mdadm.conf pour son réassemblage au démarrage (idempotent).
persist_md_array() {

    local md="$1" arr_uuid

    [[ "$md" == /dev/md* ]] && command -v mdadm >/dev/null 2>&1 || return 0

    mkdir -p /etc/mdadm
    touch /etc/mdadm/mdadm.conf
    arr_uuid="$(mdadm --detail "$md" 2>/dev/null | awk '/UUID :/ {print $3}')"

    if [[ -n "$arr_uuid" ]] && ! grep -qi "$arr_uuid" /etc/mdadm/mdadm.conf; then
        mdadm --detail --scan "$md" >> /etc/mdadm/mdadm.conf
        info "Grappe ${md} ajoutée à /etc/mdadm/mdadm.conf (réassemblage au démarrage)."
        update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs a échoué : vérifie que ${md} se réassemble au démarrage."
    fi
}

# Noms (sans /dev/) du disque de boot/système et de tous les disques qui portent / , /boot, le swap ou un LV pve.
protected_disk_names() {

    local src pk
    {
        src="$(findmnt -no SOURCE / 2>/dev/null || true)"
        [[ -n "$src" ]] && lsblk -nso NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk" {print $1}'
        lsblk -nro NAME,MOUNTPOINTS 2>/dev/null | awk '$2 ~ /^\/(boot(\/efi)?)?$/ || $2 == "[SWAP]" {print $1}' |
            while read -r pk; do lsblk -nso NAME,TYPE "/dev/${pk}" 2>/dev/null | awk '$2=="disk" {print $1}'; done
        pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '$2=="pve" {print $1}' |
            while read -r pk; do lsblk -nso NAME,TYPE "$pk" 2>/dev/null | awk '$2=="disk" {print $1}'; done
    } | tr -d '└├─│ ' | sed 's#^/dev/##' | sort -u
}

# Lignes "périphérique|nature|taille|modèle|contenu|remarque" des disques et grappes pouvant être formatés.
# Exclus : disque système/boot (et grappe qui le contient), éléments d'une grappe, périphériques montés
# ailleurs que sur DATA_MOUNT, lecteurs optiques, zram.
list_format_candidates() {

    local dev type size model protected content mnts kind note n members
    protected=" $(protected_disk_names | tr '\n' ' ') "

    while read -r dev type size; do

        [[ "$dev" == /dev/zram* || "$dev" == /dev/sr* || "$dev" == /dev/loop* ]] && continue
        [[ "$type" == "disk" || "$type" == raid* ]] || continue

        # Tous les disques physiques sous-jacents (le disque lui-même, ou les membres d'une grappe)
        members="$(lsblk -nso NAME,TYPE "$dev" 2>/dev/null | tr -d '└├─│' | awk '$2=="disk" {print $1}')"
        [[ -n "$members" ]] || members="${dev#/dev/}"

        local skip=false m
        for m in $members; do [[ "$protected" == *" ${m} "* ]] && skip=true; done
        [[ "$skip" == "true" ]] && continue

        # Montages sur le périphérique et ses partitions (hors DATA_MOUNT : cas d'une relance)
        mnts="$(lsblk -nro MOUNTPOINTS "$dev" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -vx "$DATA_MOUNT" | sort -u | tr '\n' ' ')"
        [[ -z "${mnts// /}" ]] || continue

        # Élément d'une grappe : on propose la grappe, pas ses disques
        if [[ "$type" == "disk" ]] && lsblk -nro FSTYPE,TYPE "$dev" 2>/dev/null | awk '$1=="linux_raid_member" || $2 ~ /^raid/ {f=1} END {exit !f}'; then
            continue
        fi

        model="$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/ *$//')"
        [[ -n "$model" ]] || model="-"
        model="${model// /_}"

        if [[ "$type" == raid* ]]; then
            kind="RAID"
            n="$(lsblk -nso NAME,TYPE "$dev" 2>/dev/null | tr -d '└├─│' | awk '$2=="disk"' | wc -l)"
            model="${type} (${n} disques)"
            model="${model// /_}"
        else
            kind="disque"
        fi

        content="$(lsblk -nro FSTYPE,LABEL "$dev" 2>/dev/null | awk 'NF && $1 != "" {printf "%s%s ", $1, ($2 != "" ? "(" $2 ")" : "")}' | sed 's/ *$//')"
        if [[ -n "$content" ]]; then note="DONNÉES PRÉSENTES"; else content="vide"; note="-"; fi
        content="${content// /,}"

        printf '%s|%s|%s|%s|%s|%s\n' "$dev" "$kind" "$size" "$model" "$content" "$note"

    done < <(lsblk -dpnro NAME,TYPE,SIZE 2>/dev/null; lsblk -pnro NAME,TYPE,SIZE 2>/dev/null | awk '$2 ~ /^raid/')
}

# Interactif : liste ce qui est détecté et positionne DATA_DISK. Ne formate rien (la confirmation FORMAT-YES suit).
choose_data_disk() {

    local -a cands=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && cands+=("$line")
    done < <(list_format_candidates | sort -u)

    if (( ${#cands[@]} == 0 )); then
        warn "Aucun disque ou grappe disponible détecté (le disque système est exclu automatiquement)."
        return 1
    fi

    echo "Disques et grappes pouvant recevoir les DONNÉES (le disque système est exclu) :"
    local i=1 dev kind size model content note
    for line in "${cands[@]}"; do
        IFS='|' read -r dev kind size model content note <<< "$line"
        printf '  %d) %-14s %-7s %-8s %-24s contenu: %s%s\n' "$i" "$dev" "$kind" "$size" "${model//_/ }" "${content//,/ }" \
            "$([[ "$note" != "-" ]] && echo '   ⚠ SERA EFFACÉ')"
        i=$(( i + 1 ))
    done
    echo "  m) Saisir un chemin à la main"
    echo "  q) Quitter"
    echo

    local choice
    while true; do
        read -r -p "Quel disque ou quelle grappe formater pour DATA ? [1-${#cands[@]} / m / q] (défaut : ${DATA_DISK}) : " choice
        case "$choice" in
            q | Q) die "Abandon à la demande de l'utilisateur." ;;
            "") return 0 ;;
            m | M) read -r -p "Chemin du disque ou de la grappe [${DATA_DISK}] : " choice
                   [[ -n "$choice" ]] && DATA_DISK="$choice"
                   return 0 ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cands[@]} )); then
            IFS='|' read -r dev _ <<< "${cands[choice-1]}"
            DATA_DISK="$dev"
            return 0
        fi
        echo "Choix invalide."
    done
}

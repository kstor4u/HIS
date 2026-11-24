###############################################################################
#                              DATA DISK                                      #
###############################################################################

# Libère complètement DATA_DISK avant de le toucher avec wipefs/parted.
# Un simple "umount" ne suffit pas toujours : si une entrée fstab d'un
# run précédent existe encore, systemd peut remonter le point de montage
# automatiquement juste après notre umount (l'unité générée depuis fstab
# reprend la main), ce qui laisse le disque "busy" au moment du wipefs.
# On arrête explicitement cette unité, on essaie un umount classique puis
# un umount -l (lazy) en secours, on désactive un éventuel VG LVM qui
# tiendrait le disque, et on désactive un swap actif dessus.
release_data_disk() {

    local disk="$1"
    local mount_point="$2"

    local mount_unit
    mount_unit="$(systemd-escape --path --suffix=mount "$mount_point" 2>/dev/null || true)"

    if [[ -n "$mount_unit" ]]; then
        systemctl stop "$mount_unit" 2>/dev/null || true
    fi

    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || true
    fi

    local part

    for part in "$disk" "${disk}"*[0-9] "${disk}"p[0-9]*; do

        [[ -b "$part" ]] || continue

        if findmnt -rn -S "$part" >/dev/null 2>&1; then
            umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
        fi

        if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$part"; then
            swapoff "$part" 2>/dev/null || true
        fi
    done

    if command -v pvs >/dev/null 2>&1; then

        local vg
        vg="$(pvs --noheadings -o vg_name "$disk" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ -n "$vg" ]]; then
            warn "Le disque ${disk} porte une signature LVM (VG ${vg}) : désactivation avant wipefs."
            vgchange -an "$vg" 2>/dev/null || true
        fi
    fi

    udevadm settle
}

prepare_data_disk() {

    # Disque unique : DATA est un volume mince dans le thin pool de Proxmox.
    if [[ "${DATA_MODE:-disk}" == "thin" ]]; then
        prepare_data_thin
        return 0
    fi

    # Volume existant choisi (grappe RAID, disque déjà formaté) : on le monte tel quel, sans rien effacer.
    if [[ -n "${DATA_EXISTING_DEVICE:-}" ]]; then
        use_existing_data_volume
        return 0
    fi

    info "Préparation du disque DATA ${DATA_DISK}..."

    # Idempotence : si la partition existe déjà, est en ext4 et porte le
    # label DATA, on considère qu'un run précédent l'a déjà préparée et on
    # NE LA REFORMATE PAS. Sans ça, supprimer uniquement les VM/CT pour
    # relancer le script à zéro effacerait aussi SHARED (Users/Photo/
    # Movies/Music) à chaque tentative, alors que seul le disque compute
    # (VM/CT) a besoin d'être recréé.
    local already_prepared=false

    if [[ -b "$DATA_PARTITION" ]]; then

        local existing_fstype existing_label

        existing_fstype="$(blkid -s TYPE -o value "$DATA_PARTITION" 2>/dev/null || true)"
        existing_label="$(blkid -s LABEL -o value "$DATA_PARTITION" 2>/dev/null || true)"

        if [[ "$existing_fstype" == "ext4" && "$existing_label" == "DATA" ]]; then
            already_prepared=true
        fi
    fi

    if [[ "$already_prepared" == "true" ]]; then

        info "${DATA_PARTITION} est déjà en ext4 avec le label DATA : formatage sauté (idempotent)."
        info "Pour forcer un reformatage complet, efface le disque toi-même avant de relancer (ex: wipefs -a ${DATA_DISK})."

    else

        release_data_disk "$DATA_DISK" "$DATA_MOUNT"

        local wipefs_attempt wipefs_ok=false

        for wipefs_attempt in 1 2 3; do

            if wipefs -a "$DATA_DISK"; then
                wipefs_ok=true
                break
            fi

            warn "wipefs a échoué sur ${DATA_DISK} (tentative ${wipefs_attempt}/3, disque probablement encore 'busy'). Nouvelle tentative après libération..."

            release_data_disk "$DATA_DISK" "$DATA_MOUNT"
            sleep 3
        done

        [[ "$wipefs_ok" == "true" ]] \
            || die "wipefs échoue toujours sur ${DATA_DISK} après 3 tentatives. Vérifie manuellement : lsblk ${DATA_DISK} ; mount | grep ${DATA_DISK##*/} ; fuser -vm ${DATA_DISK}* ; dmsetup ls."

        if [[ "$DATA_PARTITION" != "$DATA_DISK" ]]; then
            parted -s "$DATA_DISK" mklabel gpt
            parted -s "$DATA_DISK" mkpart primary ext4 1MiB 100%

            partprobe "$DATA_DISK"
        else
            info "${DATA_DISK} est une grappe/un volume : formaté en entier, sans table de partitions."
        fi

        udevadm settle

        [[ -b "$DATA_PARTITION" ]] \
            || die "La partition ${DATA_PARTITION} n'existe pas après partitionnement."

        mkfs.ext4 -F -L DATA "$DATA_PARTITION"
    fi

    mkdir -p "$DATA_MOUNT"

    local DATA_UUID

    DATA_UUID="$(
        blkid -s UUID -o value "$DATA_PARTITION"
    )"

    [[ -n "$DATA_UUID" ]] \
        || die "Impossible de récupérer l'UUID de ${DATA_PARTITION}."

    if grep -qE "[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab; then
        sed -i "\|[[:space:]]${DATA_MOUNT}[[:space:]]|d" /etc/fstab
    fi

    if [[ "$DATA_DISK" == /dev/md* ]]; then
        persist_md_array "$DATA_DISK"
        printf 'UUID=%s %s ext4 defaults,noatime,x-systemd.device-timeout=60s 0 2\n' "$DATA_UUID" "$DATA_MOUNT" >> /etc/fstab
    else
        printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$DATA_UUID" "$DATA_MOUNT" >> /etc/fstab
    fi

    if ! mountpoint -q "$DATA_MOUNT"; then
        mount "$DATA_MOUNT"
    fi

    mountpoint -q "$DATA_MOUNT" \
        || die "${DATA_MOUNT} n'est pas monté."

    findmnt -rn -T "$DATA_MOUNT" -o SOURCE,FSTYPE,TARGET
}

# Mode « thin » (DATA_MODE=thin) : crée le volume mince DATA_THIN_LV dans DATA_THIN_POOL (taille VIRTUELLE
# DATA_LV_SIZE), y met de l'ext4 (label DATA) et le monte sur DATA_MOUNT. Ne touche à aucun disque ; idempotent :
# un volume existant portant déjà ext4/DATA est réutilisé tel quel, un volume portant autre chose est refusé.
prepare_data_thin() {

    local pool="${DATA_THIN_POOL:-pve/data}" lvname="${DATA_THIN_LV:-datafs}" size="${DATA_LV_SIZE:-90%}"
    local vg="${pool%%/*}" attr dev uuid fstype label pool_bytes pct size_arg

    [[ "$pool" == */* && -n "$vg" ]] || die "DATA_THIN_POOL='${pool}' invalide (forme VG/LV, ex. pve/data)."
    command -v lvs > /dev/null 2>&1 || die "DATA_MODE=thin : LVM introuvable (lvs)."

    attr="$(lvs --noheadings -o lv_attr "$pool" 2> /dev/null | tr -d '[:space:]' || true)"
    [[ "$attr" == t* ]] \
        || die "DATA_MODE=thin : ${pool} n'est pas un thin pool LVM (installation Proxmox sur LVM-thin requise ; sinon utilise DATA_MODE=disk)."

    dev="/dev/${vg}/${lvname}"
    info "Volume DATA mince ${vg}/${lvname} dans ${pool}..."

    if [[ ! -e "$dev" ]]; then

        pool_bytes="$(lvs --noheadings --units b --nosuffix -o lv_size "$pool" | tr -d '[:space:]')"

        case "$size" in
            *%)
                pct="${size%\%}"
                [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 1 && pct <= 100 )) \
                    || die "DATA_LV_SIZE='${size}' invalide (« NN% » entre 1 et 100, ou une taille comme 2T)."
                size_arg="$(( pool_bytes * pct / 100 / 1048576 ))m"
                ;;
            *) size_arg="$size" ;;
        esac

        lvcreate -y -V "$size_arg" -T "$pool" -n "$lvname" > /dev/null \
            || die "Création du volume mince ${vg}/${lvname} (${size_arg}) impossible."
        udevadm settle
        [[ -b "$dev" ]] || die "Le volume ${dev} n'existe pas après sa création."
    fi

    fstype="$(blkid -s TYPE -o value "$dev" 2> /dev/null || true)"
    label="$(blkid -s LABEL -o value "$dev" 2> /dev/null || true)"

    if [[ -z "$fstype" ]]; then
        mkfs.ext4 -F -m 1 -L DATA -E lazy_itable_init=1,lazy_journal_init=1 "$dev" > /dev/null \
            || die "mkfs.ext4 a échoué sur ${dev}."
    elif [[ "$fstype" == "ext4" && "$label" == "DATA" ]]; then
        info "${dev} est déjà en ext4 avec le label DATA : formatage sauté (idempotent)."
    else
        die "${dev} existe déjà et porte ${fstype:-?} (label ${label:-aucun}) : refus de le formater. Choisis un autre DATA_THIN_LV."
    fi

    uuid="$(blkid -s UUID -o value "$dev")"
    [[ -n "$uuid" ]] || die "Impossible de récupérer l'UUID de ${dev}."

    mkdir -p "$DATA_MOUNT"
    if grep -qE "[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab; then
        sed -i "\|[[:space:]]${DATA_MOUNT}[[:space:]]|d" /etc/fstab
    fi
    printf 'UUID=%s %s ext4 defaults,noatime,x-systemd.device-timeout=60s 0 2\n' "$uuid" "$DATA_MOUNT" >> /etc/fstab
    systemctl daemon-reload

    mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
    mountpoint -q "$DATA_MOUNT" || die "${DATA_MOUNT} n'est pas monté."

    findmnt -rn -T "$DATA_MOUNT" -o SOURCE,FSTYPE,TARGET
    info "Volume DATA mince : taille VIRTUELLE ${size}. Le pool est partagé avec les disques de VM : surveille lvs (colonne Data%), pas seulement df."
}

# TRIM hebdomadaire de l'hôte (DATA_TRIM) : sans lui, les fichiers supprimés gardent leur place dans le thin pool.
# Pas d'option de montage « discard » (continu) : elle ralentit les suppressions.
configure_trim() {

    if [[ "${DATA_TRIM:-true}" != "true" ]]; then
        info "TRIM : DATA_TRIM=false, ignoré."
        return 0
    fi

    command -v fstrim > /dev/null 2>&1 || { warn "TRIM : fstrim introuvable, ignoré."; return 0; }

    systemctl enable --now fstrim.timer > /dev/null 2>&1 || { warn "TRIM : fstrim.timer non activé."; return 0; }
    info "TRIM : fstrim.timer actif (passage hebdomadaire sur les systèmes de fichiers de l'hôte)."
}

###############################################################################
#                              DATA TREE                                      #
###############################################################################

# Crée les dossiers de DONNÉES des applications sur SHARED, avec des droits qui
# permettent à chaque conteneur (groupe fileshare, ACL par défaut) d'y écrire.
# Appelée à l'installation et par les réparations.
prepare_apps_data_dirs() {

    local d

    # Données d'applications HORS de SHARED (jamais exposées par Samba) :
    #   immich    : écrit en root par le conteneur Immich (VM DOCKER)
    #   nextcloud : propriétaire www-data (uid 33), groupe fileshare
    #   syncin    : groupe fileshare (les conteneurs utilisent group_add GID ${SHARED_GID})
    #   mail      : propriétaire = root du CT MAIL (uid 100000 d'un CT non privilégié)
    #   backups   : sauvegardes (root)
    mkdir -p "$APPS_DIR" "${APPS_DIR}/immich" "${APPS_DIR}/nextcloud" "${APPS_DIR}/syncin" \
        "${APPS_DIR}/mail" "${APPS_DIR}/backups"

    chown root:root "$APPS_DIR" "${APPS_DIR}/immich" "${APPS_DIR}/backups"
    chmod 0755 "$APPS_DIR"
    chmod 0750 "${APPS_DIR}/immich" "${APPS_DIR}/backups"

    for d in "${APPS_DIR}/syncin" "${APPS_DIR}/nextcloud"; do
        chgrp "$SHARED_GROUP" "$d"
        chmod 2770 "$d"
    done

    # Nextcloud (www-data = uid 33 dans l'image) doit être propriétaire de son dossier de données.
    chown 33:"$SHARED_GID" "${APPS_DIR}/nextcloud"

    chown 100000:100000 "${APPS_DIR}/mail"
    chmod 0750 "${APPS_DIR}/mail"
}

# Arborescence SHARED d'un site + groupe Unix + ACL (utilisée pour le site principal et pour chaque site secondaire).
shared_tree_apply() {   # <dossier SHARED> <groupe> <gid>

    local dir="$1" grp="$2" gid="$3"

    mkdir -p \
        "$dir/Users" \
        "$dir/Photo" \
        "$dir/Movies/Series" \
        "$dir/Movies/Concerts" \
        "$dir/Movies/Animated" \
        "$dir/Movies/Docu" \
        "$dir/Movies/Movies" \
        "$dir/Movies/Downloaded" \
        "$dir/Music"

    if getent group "$grp" >/dev/null 2>&1; then

        local EXISTING_GID

        EXISTING_GID="$(
            getent group "$grp" |
                cut -d: -f3
        )"

        [[ "$EXISTING_GID" == "$gid" ]] \
            || die \
                "Le groupe ${grp} existe déjà avec le GID ${EXISTING_GID} (attendu : ${gid})."

    else

        groupadd -g "$gid" "$grp"
    fi

    chown root:"$grp" "$dir"
    chmod 2770 "$dir"

    find "$dir" -type d -exec chmod 2770 {} \;
    find "$dir" -type f -exec chmod 0660 {} \;

    # ACL par défaut : tout nouveau fichier/dossier créé par une application
    # conserve l'accès au groupe du site (fileshare / GID ${SHARED_GID} pour le site principal).
    setfacl -R -m "g:${grp}:rwx" "$dir"
    setfacl -R -d -m "g:${grp}:rwx" "$dir"
    setfacl -R -d -m "m:rwx" "$dir"
}

create_data_tree() {

    info "Création de l'arborescence DATA..."

    mkdir -p "$PROXMOX_DATA_DIR"

    shared_tree_apply "$SHARED_DIR" "$SHARED_GROUP" "$SHARED_GID"

    prepare_apps_data_dirs

    chown root:"$SHARED_GROUP" "$PROXMOX_DATA_DIR"
    chmod 0755 "$PROXMOX_DATA_DIR"
}

###############################################################################
#                              PROXMOX STORAGE                                #
###############################################################################

configure_proxmox_storage() {

    info "Configuration du storage DATA..."

    if pvesh get /storage/DATA --output-format json >/dev/null 2>&1; then

        # IMPORTANT : pvesm set n'autorise pas de modifier --path sur un
        # storage "dir" déjà créé (propriété fixée uniquement à la
        # création, via pvesm add). Sur un re-run, on ne met donc à jour
        # que --content ; si le chemin a dérivé, on avertit au lieu de
        # planter, car le corriger nécessite de supprimer/recréer le
        # storage (pvesm remove DATA && pvesm add dir DATA --path ...).
        # --preallocation off : sinon qemu-img resize --preallocation=metadata expire sur un disque dur
        # et les disques de VM restent à la taille de l'image (3 Go).
        pvesm set DATA \
            --content backup,rootdir,vztmpl,iso,images \
            --preallocation off

    else

        pvesm add dir DATA \
            --path "$PROXMOX_DATA_DIR" \
            --content backup,rootdir,vztmpl,iso,images \
            --preallocation off
    fi

    local FINAL_PATH

    FINAL_PATH="$(
        pvesh get /storage/DATA \
            --output-format json |
            jq -r '.path'
    )"

    if [[ "$FINAL_PATH" != "$PROXMOX_DATA_DIR" ]]; then

        warn \
            "Le storage DATA existant pointe vers ${FINAL_PATH} au lieu de ${PROXMOX_DATA_DIR}."
        warn \
            "pvesm ne permet pas de changer --path sur un storage existant. Corrige manuellement si besoin :"
        warn \
            "  pvesm remove DATA && pvesm add dir DATA --path ${PROXMOX_DATA_DIR} --content backup,rootdir,vztmpl,iso,images"
    fi
}

# Valeurs par défaut dépendantes de GUEST_STORAGE (appelée après le chargement du fichier de réponses,
# aussi en mode --run) : le test de restauration suit le stockage des invités s'il n'est pas précisé.
resolve_guest_storage() {

    [[ -n "${GUEST_STORAGE:-}" ]] || GUEST_STORAGE="local-lvm"
    [[ -n "${RESTORE_TEST_STORAGE:-}" ]] || RESTORE_TEST_STORAGE="$GUEST_STORAGE"

    # Images et templates : « auto » suit GUEST_STORAGE=DATA (petit disque système).
    case "${IMAGES_STORAGE:-auto}" in
        auto) [[ "$GUEST_STORAGE" == "DATA" ]] && TEMPLATE_STORAGE="DATA" || TEMPLATE_STORAGE="local" ;;
        local | DATA) TEMPLATE_STORAGE="$IMAGES_STORAGE" ;;
        *) die "IMAGES_STORAGE='${IMAGES_STORAGE}' invalide (auto | local | DATA)." ;;
    esac

    if [[ "$TEMPLATE_STORAGE" == "DATA" && "${IMAGE_STORE_DIR:-}" == "/var/lib/vz/template/iso" ]]; then
        IMAGE_STORE_DIR="${PROXMOX_DATA_DIR}/template/iso"
    fi
    DEBIAN_IMAGE_DIR="${IMAGE_STORE_DIR}"
    DEBIAN_IMAGE="${DEBIAN_IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2"
    return 0
}

# Vérifie, AVANT toute création de VM/CT, que GUEST_STORAGE existe, est actif et accepte les disques de VM
# (« images ») et de CT (« rootdir »). Appelée après configure_proxmox_storage (le storage DATA y est créé).
check_guest_storage() {

    local kind

    [[ "$GUEST_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || die "GUEST_STORAGE='${GUEST_STORAGE}' invalide (nom de storage Proxmox attendu : local-lvm, DATA...)."

    for kind in images rootdir; do
        pvesm status --content "$kind" 2>/dev/null \
            | awk -v s="$GUEST_STORAGE" 'NR > 1 && $1 == s && $3 == "active" { found = 1 } END { exit !found }' \
            || die "GUEST_STORAGE='${GUEST_STORAGE}' : storage absent, inactif ou n'acceptant pas le contenu « ${kind} » (liste : pvesm status). Pour DATA, lance l'installation complète une fois (le storage est créé avec le disque de données)."
    done

    if [[ "$TEMPLATE_STORAGE" != "local" ]]; then
        for kind in iso vztmpl; do
            pvesm status --content "$kind" 2>/dev/null \
                | awk -v s="$TEMPLATE_STORAGE" 'NR > 1 && $1 == s && $3 == "active" { found = 1 } END { exit !found }' \
                || die "IMAGES_STORAGE : le storage ${TEMPLATE_STORAGE} n'accepte pas le contenu « ${kind} » (pvesm set ${TEMPLATE_STORAGE} --content backup,rootdir,vztmpl,iso,images)."
        done
        mkdir -p "${PROXMOX_DATA_DIR}/template/iso" "${PROXMOX_DATA_DIR}/template/cache"
    fi

    info "Stockage des disques de VM/CT : ${GUEST_STORAGE} ; images et templates : ${TEMPLATE_STORAGE}."
}

###############################################################################
#                              VIRTIOFS                                       #
###############################################################################

# Crée ou met à jour un mapping VirtioFS : ensure_virtiofs_mapping <id> <chemin hôte>
ensure_virtiofs_mapping() {

    local id="$1" path="$2" MAPPING_JSON VERIFY

    MAPPING_JSON="$(
        pvesh get /cluster/mapping/dir \
            --output-format json
    )"

    if jq -e \
        --arg id "$id" \
        '.[] | select(.id == $id)' \
        <<< "$MAPPING_JSON" >/dev/null; then

        pvesh set \
            "/cluster/mapping/dir/${id}" \
            --map "node=${NODE_NAME},path=${path}"

    else

        pvesh create /cluster/mapping/dir \
            --id "$id" \
            --map "node=${NODE_NAME},path=${path}"
    fi

    VERIFY="$(
        pvesh get \
            "/cluster/mapping/dir/${id}" \
            --output-format json
    )"

    grep -q "$path" <<< "$VERIFY" \
        || die \
            "Le mapping VirtioFS ${id} ne pointe pas vers ${path}."
}

configure_virtiofs_mapping() {

    info "Configuration du mapping VirtioFS..."

    ensure_virtiofs_mapping "$VIRTIOFS_DIR_ID" "$SHARED_DIR"
    ensure_virtiofs_mapping "$APPS_VIRTIOFS_DIR_ID" "$APPS_DIR"
}


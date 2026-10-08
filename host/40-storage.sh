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

    for part in "${disk}"*[0-9]; do

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

    info "Préparation du disque DATA ${DATA_DISK}..."

    # Idempotence : si la partition existe déjà, est en ext4 et porte le
    # label DATA, on considère qu'un run précédent l'a déjà préparée et on
    # NE LA REFORMATE PAS. Sans ça, supprimer uniquement les VM/CT pour
    # relancer le script à zéro effacerait aussi SHARED (Family/Photo/
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

        parted -s "$DATA_DISK" mklabel gpt
        parted -s "$DATA_DISK" mkpart primary ext4 1MiB 100%

        partprobe "$DATA_DISK"

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

    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' \
        "$DATA_UUID" \
        "$DATA_MOUNT" >> /etc/fstab

    if ! mountpoint -q "$DATA_MOUNT"; then
        mount "$DATA_MOUNT"
    fi

    mountpoint -q "$DATA_MOUNT" \
        || die "${DATA_MOUNT} n'est pas monté."

    findmnt -rn -T "$DATA_MOUNT" -o SOURCE,FSTYPE,TARGET
}

###############################################################################
#                              DATA TREE                                      #
###############################################################################

# Crée les dossiers de DONNÉES des applications sur SHARED, avec des droits qui
# permettent à chaque conteneur (groupe fileshare, ACL par défaut) d'y écrire.
# Appelée à l'installation et par la migration (repair_apps_data_location).
prepare_apps_data_dirs() {

    local apps="${SHARED_DIR}/${APPS_DATA_SUBDIR}"
    local d

    mkdir -p \
        "${SHARED_DIR}/${IMMICH_UPLOAD_SUBDIR}" \
        "${apps}/syncin" \
        "${apps}/nextcloud"

    for d in "$apps" "${apps}/syncin" "${apps}/nextcloud" "${SHARED_DIR}/${IMMICH_UPLOAD_SUBDIR}"; do
        chgrp "$SHARED_GROUP" "$d"
        chmod 2770 "$d"
    done

    # Nextcloud (www-data = uid 33 dans l'image) doit être propriétaire de son dossier de données.
    chown 33:"$SHARED_GID" "${apps}/nextcloud"
}

create_data_tree() {

    info "Création de l'arborescence DATA..."

    mkdir -p \
        "$SHARED_DIR/Family" \
        "$SHARED_DIR/Photo" \
        "$SHARED_DIR/Movies/Series" \
        "$SHARED_DIR/Movies/Concerts" \
        "$SHARED_DIR/Movies/Animated" \
        "$SHARED_DIR/Movies/Docu" \
        "$SHARED_DIR/Movies/Movies" \
        "$SHARED_DIR/Movies/Downloaded" \
        "$SHARED_DIR/Music" \
        "$PROXMOX_DATA_DIR"

    if getent group "$SHARED_GROUP" >/dev/null 2>&1; then

        local EXISTING_GID

        EXISTING_GID="$(
            getent group "$SHARED_GROUP" |
                cut -d: -f3
        )"

        [[ "$EXISTING_GID" == "$SHARED_GID" ]] \
            || die \
                "Le groupe ${SHARED_GROUP} existe déjà avec le GID ${EXISTING_GID}."

    else

        groupadd -g "$SHARED_GID" "$SHARED_GROUP"
    fi

    chown root:"$SHARED_GROUP" "$SHARED_DIR"
    chmod 2770 "$SHARED_DIR"

    find "$SHARED_DIR" -type d -exec chmod 2770 {} \;
    find "$SHARED_DIR" -type f -exec chmod 0660 {} \;

    # ACL par défaut : tout nouveau fichier/dossier créé par une application
    # conserve l'accès au groupe fileshare (GID ${SHARED_GID}).
    setfacl -R -m "g:${SHARED_GROUP}:rwx" "$SHARED_DIR"
    setfacl -R -d -m "g:${SHARED_GROUP}:rwx" "$SHARED_DIR"
    setfacl -R -d -m "m:rwx" "$SHARED_DIR"

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
        pvesm set DATA \
            --content backup,rootdir,vztmpl,iso,images

    else

        pvesm add dir DATA \
            --path "$PROXMOX_DATA_DIR" \
            --content backup,rootdir,vztmpl,iso,images
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

###############################################################################
#                              VIRTIOFS                                       #
###############################################################################

configure_virtiofs_mapping() {

    info "Configuration du mapping VirtioFS..."

    local MAPPING_JSON

    MAPPING_JSON="$(
        pvesh get /cluster/mapping/dir \
            --output-format json
    )"

    if jq -e \
        --arg id "$VIRTIOFS_DIR_ID" \
        '.[] | select(.id == $id)' \
        <<< "$MAPPING_JSON" >/dev/null; then

        pvesh set \
            "/cluster/mapping/dir/${VIRTIOFS_DIR_ID}" \
            --map "node=${NODE_NAME},path=${SHARED_DIR}"

    else

        pvesh create /cluster/mapping/dir \
            --id "$VIRTIOFS_DIR_ID" \
            --map "node=${NODE_NAME},path=${SHARED_DIR}"
    fi

    local VERIFY

    VERIFY="$(
        pvesh get \
            "/cluster/mapping/dir/${VIRTIOFS_DIR_ID}" \
            --output-format json
    )"

    grep -q "$SHARED_DIR" <<< "$VERIFY" \
        || die \
            "Le mapping VirtioFS ne pointe pas vers ${SHARED_DIR}."
}


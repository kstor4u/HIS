###############################################################################
#                              CONFIGURATION INTERACTIVE                      #
###############################################################################

configure_variables() {

    echo
    echo "============================================================"
    echo " PROXMOX HOMELAB INSTALLER ${SCRIPT_VERSION}"
    echo "============================================================"
    echo

    echo "Modules :"
    echo "  SWAG   = ${ENABLE_SWAG}"
    echo "  DOCKER = ${ENABLE_DOCKER}"
    echo "  FILES  = ${ENABLE_FILES}"
    echo "  XMRIG  = ${ENABLE_XMRIG}"
    echo "  WG     = ${ENABLE_WIREGUARD}"
    echo "  NODE   = ${ENABLE_NODE}"
    echo "  MAIL   = ${ENABLE_MAIL}"
    echo "  DNS    = ${ENABLE_DNS}"
    echo "  MONITOR= ${ENABLE_MONITOR}"
    echo "  AI     = ${ENABLE_AI}"
    echo "  ARR    = ${ENABLE_ARR}"
    echo "  CROWDSEC = ${ENABLE_CROWDSEC}"
    echo "  HA     = ${ENABLE_HOMEASSISTANT}"
    echo "  JELLY  = ${ENABLE_JELLYFIN}"
    echo "  COLLAB = ${ENABLE_COLLABORA}"
    echo "  ONLYOF = ${ENABLE_ONLYOFFICE}"
    echo

    if [[ "$ANSWERS_FILE_LOADED" == "true" ]]; then
        info "Mode fichier de réponses (${ANSWERS_FILE}) : les étapes ci-dessous ne seront pas redemandées, seulement validées."
    fi

    if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

        read -r -p "Domaine [${DOMAIN}] : " input

        if [[ -n "$input" ]]; then
            DOMAIN="$input"
        fi
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then

        if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

            while true; do

                read -r -p "Email Let's Encrypt : " LE_EMAIL

                [[ -n "$LE_EMAIL" ]] \
                    || die "L'email Let's Encrypt est obligatoire avec SWAG."

                if [[ "$LE_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                    break
                fi

                echo "Format d'email invalide, réessaie."
            done
        fi

        [[ -n "$LE_EMAIL" ]] \
            || die "LE_EMAIL est vide (à définir dans ${ANSWERS_FILE})."

        [[ "$LE_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
            || die "LE_EMAIL a un format invalide dans ${ANSWERS_FILE} : ${LE_EMAIL}"
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]]; then

        if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

            while true; do

                read -r -p "Wallet XMRig (adresse Monero) : " XMRIG_WALLET

                [[ -n "$XMRIG_WALLET" ]] \
                    || die "Le wallet XMRig est obligatoire."

                # Une adresse Monero standard/subaddress fait 95 caractères
                # base58 et commence par 4 ou 8. Ce n'est qu'un contrôle de
                # forme (pas une validation cryptographique de l'adresse) :
                # il attrape les fautes de frappe grossières avant qu'elles
                # ne coûtent des paiements de pool perdus.
                if [[ "$XMRIG_WALLET" =~ ^[48][1-9A-HJ-NP-Za-km-z]{94}$ ]]; then
                    break
                fi

                echo "Cette adresse ne ressemble pas à une adresse Monero valide (95 caractères, commence par 4 ou 8)."
                read -r -p "Continuer quand même avec cette valeur ? (oui/non) : " force_confirm

                if [[ "$force_confirm" == "oui" ]]; then
                    break
                fi
            done

        else

            [[ -n "$XMRIG_WALLET" ]] \
                || die "XMRIG_WALLET est vide (à définir dans ${ANSWERS_FILE})."

            if [[ ! "$XMRIG_WALLET" =~ ^[48][1-9A-HJ-NP-Za-km-z]{94}$ ]]; then
                warn "XMRIG_WALLET dans ${ANSWERS_FILE} ne ressemble pas à une adresse Monero valide (95 caractères, préfixe 4/8) — on continue quand même car fourni via fichier, vérifie-la."
            fi
        fi
    fi

    echo
    echo "Disques détectés :"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
    echo

    # Volume existant (RAID mdadm, LVM, ext4/xfs/btrfs) : détecté, jamais formaté, on demande quoi faire.
    case "$DATA_MODE" in
        disk | thin) ;;
        *) die "DATA_MODE='${DATA_MODE}' invalide (disk | thin)." ;;
    esac

    if [[ "$DATA_MODE" != "thin" && -z "$DATA_EXISTING_DEVICE" && "$ANSWERS_FILE_LOADED" != "true" ]]; then
        choose_existing_volume
    fi

    if [[ "$DATA_MODE" == "thin" ]]; then

        [[ -z "$DATA_EXISTING_DEVICE" ]] \
            || die "DATA_MODE=thin est incompatible avec DATA_EXISTING_DEVICE (volume existant) : choisis l'un ou l'autre."

        echo "============================================================"
        echo " DATA = VOLUME MINCE ${DATA_THIN_POOL%%/*}/${DATA_THIN_LV} DANS ${DATA_THIN_POOL} (AUCUN DISQUE FORMATÉ)"
        echo "============================================================"
        echo

    elif [[ -n "$DATA_EXISTING_DEVICE" ]]; then

        assemble_existing_arrays

        [[ -b "$DATA_EXISTING_DEVICE" ]] \
            || die "Volume existant introuvable : ${DATA_EXISTING_DEVICE}"

        echo
        echo "============================================================"
        echo " VOLUME EXISTANT RÉUTILISÉ : ${DATA_EXISTING_DEVICE} (AUCUN FORMATAGE)"
        echo "============================================================"
        echo

    else

        if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

            # Liste des disques et grappes RAID détectés (système exclu) ; sinon saisie libre
            if ! choose_data_disk; then
                read -r -p "Disque DATA [${DATA_DISK}] : " input
                [[ -z "$input" ]] || DATA_DISK="$input"
            fi

        else

            info "Disque DATA (depuis ${ANSWERS_FILE}) : ${DATA_DISK}"
        fi

        DATA_PARTITION="$(data_partition_for "$DATA_DISK")"

        [[ -b "$DATA_DISK" ]] \
            || die "Disque DATA introuvable : ${DATA_DISK}"

        # -------------------------------------------------------------------
        # Garde-fou : interdiction de formater le disque de boot / système.
        # On résout le disque racine et tout disque support d'un LV Proxmox
        # (local-lvm), et on refuse si DATA_DISK correspond à l'un d'eux.
        # -------------------------------------------------------------------

        # Garde-fou : le disque système/boot (ou un disque portant un LV pve) ne peut pas être formaté, ni une
        # grappe RAID dont un membre est dans ce cas.
        local candidate_name
        local -a protected_disks=()

        while read -r candidate_name; do
            [[ -n "$candidate_name" ]] && protected_disks+=("$candidate_name")
        done < <(protected_disk_names)

        local under
        while read -r under; do
            [[ -n "$under" ]] || continue
            for candidate_name in "${protected_disks[@]}"; do
                if [[ "$under" == "$candidate_name" ]]; then
                    die "${DATA_DISK} semble être le disque système/boot de Proxmox, ou en contient un (protection automatique). Abandon."
                fi
            done
        done < <(lsblk -nso NAME "$DATA_DISK" 2>/dev/null | tr -d '└├─│ ')

        echo
        echo "============================================================"
        echo " LE DISQUE ${DATA_DISK} SERA REPARTITIONNÉ ET FORMATÉ EN EXT4"
        echo "============================================================"
        echo

        if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

            read -r -p "Tape exactement FORMAT-YES pour continuer : " FORMAT_CONFIRMATION

        else

            info "Confirmation de formatage lue depuis ${ANSWERS_FILE}."
        fi

        [[ "$FORMAT_CONFIRMATION" == "FORMAT-YES" ]] \
            || die "Confirmation incorrecte (FORMAT_CONFIRMATION doit valoir exactement FORMAT-YES). Abandon."

    fi

    echo

    if [[ "$ANSWERS_FILE_LOADED" != "true" ]]; then

        while true; do

            read -r -s \
                -p "Mot de passe root des nouvelles VM/CT : " \
                ROOT_PASSWORD
            echo

            read -r -s \
                -p "Confirmer le mot de passe root : " \
                root_password_confirm
            echo

            if [[ "$ROOT_PASSWORD" == "$root_password_confirm" ]]; then
                break
            fi

            echo "Les mots de passe ne correspondent pas."
        done

        while true; do

            read -r -s \
                -p "Mot de passe Samba de fileshare : " \
                SAMBA_PASSWORD
            echo

            read -r -s \
                -p "Confirmer le mot de passe Samba : " \
                samba_password_confirm
            echo

            if [[ "$SAMBA_PASSWORD" == "$samba_password_confirm" ]]; then
                break
            fi

            echo "Les mots de passe ne correspondent pas."
        done
    fi

    [[ -n "$ROOT_PASSWORD" ]] \
        || die "ROOT_PASSWORD est vide (à définir dans ${ANSWERS_FILE})."

    [[ -n "$SAMBA_PASSWORD" ]] \
        || die "SAMBA_PASSWORD est vide (à définir dans ${ANSWERS_FILE})."

    ROOT_PASSWORD_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"

    SAMBA_PASSWORD_B64="$(
        printf '%s' "$SAMBA_PASSWORD" |
            base64 -w0
    )"

    unset root_password_confirm
    unset samba_password_confirm

    echo
    info "Configuration validée."
}

###############################################################################
#                              APP SECRETS                                    #
###############################################################################

generate_app_secrets() {

    info "Génération des secrets des applications Docker (Nextcloud/Sync-in/Immich)..."

    # Les valeurs déjà fournies via ANSWERS_FILE sont conservées telles
    # quelles (utile pour garder des identifiants stables entre plusieurs
    # tests) ; seules celles encore vides sont générées aléatoirement.
    [[ -n "$NEXTCLOUD_ADMIN_PASSWORD" ]] || NEXTCLOUD_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
    [[ -n "$NEXTCLOUD_DB_PASSWORD" ]]    || NEXTCLOUD_DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"

    [[ -n "$SYNCIN_ADMIN_PASSWORD" ]]    || SYNCIN_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
    [[ -n "$SYNCIN_DB_PASSWORD" ]]       || SYNCIN_DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
    [[ -n "$SYNCIN_DB_ROOT_PASSWORD" ]]  || SYNCIN_DB_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
    [[ -n "$SYNCIN_SECRET_1" ]]          || SYNCIN_SECRET_1="$(openssl rand -hex 32)"
    [[ -n "$SYNCIN_SECRET_2" ]]          || SYNCIN_SECRET_2="$(openssl rand -hex 32)"
    [[ -n "$SYNCIN_SECRET_3" ]]          || SYNCIN_SECRET_3="$(openssl rand -hex 32)"
    [[ -n "$SYNCIN_SECRET_4" ]]          || SYNCIN_SECRET_4="$(openssl rand -hex 32)"

    [[ -n "$IMMICH_DB_PASSWORD" ]]       || IMMICH_DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"
    [[ -n "$ONLYOFFICE_JWT_SECRET" ]]    || ONLYOFFICE_JWT_SECRET="$(openssl rand -hex 32)"

    local secret_var

    for secret_var in \
        NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD \
        SYNCIN_ADMIN_PASSWORD SYNCIN_DB_PASSWORD SYNCIN_DB_ROOT_PASSWORD \
        SYNCIN_SECRET_1 SYNCIN_SECRET_2 SYNCIN_SECRET_3 SYNCIN_SECRET_4 \
        IMMICH_DB_PASSWORD ONLYOFFICE_JWT_SECRET
    do
        [[ -n "${!secret_var}" ]] \
            || die "Échec de génération du secret ${secret_var}."
    done

    info "Secrets générés (affichés une seule fois dans le résumé final)."
}


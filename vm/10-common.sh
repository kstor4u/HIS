###############################################################################
#                              CLOUD IMAGE                                    #
###############################################################################

download_debian_image() {

    mkdir -p "$DEBIAN_IMAGE_DIR"

    if [[ ! -f "$DEBIAN_IMAGE" ]]; then

        info "Téléchargement de Debian 13 cloud image..."

        wget \
            --https-only \
            -O "$DEBIAN_IMAGE" \
            "$DEBIAN_IMAGE_URL"
    fi

    [[ -s "$DEBIAN_IMAGE" ]] \
        || die "Image Debian absente ou vide."

    command -v qemu-img >/dev/null 2>&1 \
        || die "qemu-img est introuvable."

    qemu-img info "$DEBIAN_IMAGE" >/dev/null \
        || die "L'image Debian n'est pas une image QEMU valide."
}

###############################################################################
#                              LOCAL SNIPPETS                                 #
###############################################################################

configure_local_snippets() {

    info "Activation du contenu snippets sur local..."

    pvesm set local \
        --content iso,vztmpl,backup,snippets

    mkdir -p /var/lib/vz/snippets
}

###############################################################################
#                              GUEST READINESS                                #
###############################################################################

# Attend que le qemu-guest-agent réponde dans le guest. Nécessaire avant
# tout qm guest exec/cmd, et bon indicateur que le boot initial est avancé.
# Verbeux exprès : on logge chaque tentative avec la vraie erreur qm, pour
# pouvoir diagnostiquer sans deviner (agent pas installé ? VM plantée ?
# canal virtio-serial absent ? etc).
wait_for_qemu_agent() {

    local VMID="$1"
    local MAX_ATTEMPTS="${2:-60}"

    local attempt last_error elapsed

    info "Attente de l'agent QEMU sur la VM ${VMID} (jusqu'à ${MAX_ATTEMPTS} tentatives, ~$(( MAX_ATTEMPTS * 5 / 60 )) min)."

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do

        if ! qm status "$VMID" | grep -q "status: running"; then
            warn "VM ${VMID} n'est plus à l'état 'running' (tentative ${attempt}). État actuel : $(qm status "$VMID")."
            return 1
        fi

        if last_error="$(qm guest cmd "$VMID" ping 2>&1)"; then
            info "Agent QEMU opérationnel sur la VM ${VMID} (tentative ${attempt}/${MAX_ATTEMPTS}, $(( attempt * 5 ))s écoulées)."
            return 0
        fi

        elapsed=$(( attempt * 5 ))

        info "[${elapsed}s] Agent QEMU pas encore prêt sur la VM ${VMID} (tentative ${attempt}/${MAX_ATTEMPTS}). Erreur : ${last_error}"

        sleep 5
    done

    warn "Agent QEMU toujours injoignable sur la VM ${VMID} après $(( MAX_ATTEMPTS * 5 ))s."
    warn "Dernière erreur qm guest cmd ping : ${last_error}"
    warn "Diagnostic possible : qm config ${VMID} | grep agent ; puis depuis la console (qm terminal ${VMID} ou noVNC) :"
    warn "  systemctl status qemu-guest-agent ; cloud-init status --long ; cat /var/log/cloud-init.log | tail -50"

    return 1
}

# Attend que cloud-init ait fini tout son travail (paquets + runcmd) dans
# le guest, via l'agent QEMU. C'est ce qui manquait avant les tentatives
# de qm shutdown juste après la création : la VM vient de démarrer, ses
# runcmd (install Samba/Webmin sur FILES, Docker + pull des images sur
# DOCKER) tournent encore, apt/dpkg peut tenir un lock, et l'OS ne traite
# alors pas la requête ACPI de shutdown dans le délai imparti.
wait_for_cloud_init() {

    local VMID="$1"
    local MAX_ATTEMPTS="${2:-90}"

    local attempt raw_output status_line elapsed

    info "Attente de la fin de cloud-init sur la VM ${VMID} (jusqu'à ${MAX_ATTEMPTS} tentatives, ~$(( MAX_ATTEMPTS * 5 / 60 )) min)."

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do

        if ! qm status "$VMID" | grep -q "status: running"; then
            warn "VM ${VMID} n'est plus à l'état 'running' (tentative ${attempt}). État actuel : $(qm status "$VMID")."
            return 1
        fi

        raw_output="$(qm guest exec "$VMID" -- cloud-init status 2>&1 || true)"

        # jq plutôt qu'un grep sur le JSON brut : qm guest exec ne
        # garantit pas un formatage compact (des espaces peuvent apparaître
        # autour des ":"), ce qu'un grep naïf sur '"out-data":"..."' rate
        # silencieusement, faisant tourner cette boucle à vide jusqu'au
        # timeout même quand cloud-init a fini depuis longtemps.
        status_line="$(jq -r '.["out-data"] // empty' <<< "$raw_output" 2>/dev/null || true)"
        cmd_exitcode="$(jq -r '.exitcode // empty' <<< "$raw_output" 2>/dev/null || true)"

        elapsed=$(( attempt * 5 ))

        if grep -q 'status: done' <<< "$status_line"; then

            if [[ -n "$cmd_exitcode" && "$cmd_exitcode" != "0" ]]; then
                warn "cloud-init terminé sur la VM ${VMID}, mais avec des erreurs récupérables (exitcode ${cmd_exitcode} de 'cloud-init status'). Vérifie 'cloud-init status --long' et /var/log/cloud-init.log sur la console."
            fi

            info "cloud-init terminé sur la VM ${VMID} (tentative ${attempt}/${MAX_ATTEMPTS}, ${elapsed}s écoulées)."
            return 0
        fi

        if grep -q 'status: error' <<< "$status_line"; then
            warn "cloud-init signale une erreur sur la VM ${VMID} : ${status_line}"
            warn "Consulte /var/log/cloud-init.log et /var/log/cloud-init-output.log depuis la console de la VM."
            return 1
        fi

        if [[ -z "$status_line" ]]; then
            info "[${elapsed}s] Pas encore de réponse exploitable de cloud-init sur la VM ${VMID} (tentative ${attempt}/${MAX_ATTEMPTS}). Sortie brute qm guest exec : ${raw_output}"
        else
            info "[${elapsed}s] cloud-init en cours sur la VM ${VMID} (tentative ${attempt}/${MAX_ATTEMPTS}) : ${status_line}"
        fi

        # Toutes les ~30s, on affiche la fin du log réel de cloud-init
        # (sortie de "docker compose pull/up" incluse) : utile pour voir
        # si un pull d'image (ex: immich-machine-learning, plusieurs Go)
        # avance réellement plutôt que de deviner à partir d'un compteur.
        if (( attempt % 6 == 0 )); then

            local log_tail

            log_tail="$(
                qm guest exec "$VMID" -- tail -n 5 /var/log/cloud-init-output.log 2>&1 |
                    jq -r '.["out-data"] // empty' 2>/dev/null ||
                    true
            )"

            if [[ -n "$log_tail" ]]; then
                info "[${elapsed}s] Fin de /var/log/cloud-init-output.log sur la VM ${VMID} : ${log_tail}"
            fi
        fi

        sleep 5
    done

    warn "cloud-init ne signale toujours pas 'done' sur la VM ${VMID} après $(( MAX_ATTEMPTS * 5 ))s."
    warn "Dernière sortie qm guest exec : ${raw_output}"
    warn "Diagnostic possible depuis la console (qm terminal ${VMID} ou noVNC) :"
    warn "  cloud-init status --long ; cat /var/log/cloud-init.log | tail -100 ; cat /var/log/cloud-init-output.log | tail -100"

    return 1
}

###############################################################################
#                              VM CREATION                                    #
###############################################################################

create_cloud_vm() {

    local VMID="$1"
    local VMNAME="$2"
    local CORES="$3"
    local MEMORY="$4"
    local DISK_SIZE="$5"
    local IP="$6"
    local GATEWAY="$7"
    local USER_DATA="$8"

    if qm status "$VMID" >/dev/null 2>&1; then

        warn "VM ${VMID} existe déjà. Création ignorée."

        return 0
    fi

    info "Création VM ${VMID} (${VMNAME})..."

    qm create "$VMID" \
        --name "$VMNAME" \
        --machine q35 \
        --bios ovmf \
        --ostype l26 \
        --scsihw virtio-scsi-single \
        --cores "$CORES" \
        --memory "$MEMORY" \
        --cpu x86-64-v2-AES \
        --net0 "virtio,bridge=${PRIVATE_BRIDGE},firewall=1" \
        --agent enabled=1 \
        --rng0 "source=/dev/urandom,max_bytes=1024,period=1000" \
        --onboot 1

    # Les images cloud Debian ne lancent un getty (invite de connexion)
    # que sur le port série (ttyS0), pas sur l'écran VGA virtuel. Sans ça,
    # la console web Proxmox affiche bien les messages du kernel mais
    # n'accepte jamais de frappe clavier. --vga serial0 fait apparaître
    # un vrai terminal (xterm.js, dans le navigateur) sur le bouton
    # "Console" de l'UI web, et rend aussi "qm terminal ${VMID}" utilisable
    # depuis le shell de l'hôte.
    qm set "$VMID" \
        --serial0 socket \
        --vga serial0

    qm set "$VMID" \
        --efidisk0 "local-lvm:4,efitype=4m,pre-enrolled-keys=1"

    qm set "$VMID" \
        --ide2 "local-lvm:cloudinit"

    qm importdisk \
        "$VMID" \
        "$DEBIAN_IMAGE" \
        local-lvm \
        --format qcow2

    local IMPORTED_DISK

    IMPORTED_DISK="$(
        qm config "$VMID" |
            awk -F': ' '/^unused0:/ {print $2}'
    )"

    [[ -n "$IMPORTED_DISK" ]] \
        || die \
            "Impossible de récupérer le disque importé de la VM ${VMID}."

    qm set "$VMID" \
        --scsi0 "${IMPORTED_DISK},discard=on,iothread=1,ssd=1"

    # Le resize échoue si le disque importé est déjà >= à la taille
    # cible (ça peut arriver si l'image cloud Debian grossit un jour).
    # On compare avant d'appeler qm resize pour rester idempotent.
    local CURRENT_SIZE_BYTES TARGET_SIZE_BYTES

    CURRENT_SIZE_BYTES="$(
        qm config "$VMID" |
            awk -F'size=' '/^scsi0:/ {print $2}' |
            awk -F',' '{print $1}'
    )"

    TARGET_SIZE_BYTES="$DISK_SIZE"

    if [[ "$CURRENT_SIZE_BYTES" != "$TARGET_SIZE_BYTES" ]]; then

        qm resize "$VMID" scsi0 "$DISK_SIZE" \
            || warn "Redimensionnement du disque scsi0 ignoré (déjà à la bonne taille ou supérieure)."
    fi

    qm set "$VMID" \
        --boot order=scsi0

    qm set "$VMID" \
        --ipconfig0 "ip=${IP},gw=${GATEWAY}"

    qm set "$VMID" \
        --ciuser root \
        --cipassword "$ROOT_PASSWORD"

    qm set "$VMID" \
        --cicustom "user=local:snippets/${USER_DATA}"

    qm start "$VMID"
}


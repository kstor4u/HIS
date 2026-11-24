###############################################################################
#                       VM DOCKER : TYPE DE PROCESSEUR                        #
###############################################################################

# x86-64-v2 (défaut des VM) n'expose pas AVX/AVX2, dont TensorFlow (Recognize) a besoin. Le changement ne prend effet
# qu'après un ARRÊT COMPLET puis démarrage de la VM : « reboot » le fait (les conteneurs repartent seuls).
docker_vm_cpu_apply() {

    local want="${DOCKER_CPU_TYPE:-host}" cur i

    qm status "$DOCKER_ID" > /dev/null 2>&1 || die "VM ${DOCKER_ID} introuvable."

    cur="$(qm config "$DOCKER_ID" | sed -n 's/^cpu: *//p' | head -n 1)"

    if [[ "${cur%%,*}" == "$want" ]]; then
        info "VM ${DOCKER_ID} : processeur déjà en '${want}'."
        return 0
    fi

    info "VM ${DOCKER_ID} : type de processeur '${cur:-par défaut}' -> '${want}'."
    qm set "$DOCKER_ID" --cpu "$want"

    if [[ "${1:-}" != "reboot" ]]; then
        info "Pris en compte au prochain arrêt complet de la VM. Pour le faire maintenant : ./install.sh --run docker_vm_cpu_apply reboot"
        return 0
    fi

    info "VM ${DOCKER_ID} : arrêt puis démarrage (coupure de quelques minutes pour toutes les applications Docker)..."
    qm shutdown "$DOCKER_ID" --timeout 120 || qm stop "$DOCKER_ID"
    for i in {1..60}; do
        qm status "$DOCKER_ID" | grep -q 'status: stopped' && break
        sleep 2
    done
    qm start "$DOCKER_ID"
    reconfigure_docker
}

###############################################################################
#             VM DOCKER : DISQUE, JOURNAUX, NETTOYAGE (disque plein)           #
###############################################################################

# Rotation des journaux Docker dans une VM existante (les nouvelles VM l'ont dès le cloud-init). Les conteneurs sont
# recréés pour prendre la limite en compte : coupure de quelques minutes des applications Docker.
docker_log_rotation_apply() {

    qm status "$DOCKER_ID" > /dev/null 2>&1 || die "VM ${DOCKER_ID} introuvable."

    vm_write_file "$DOCKER_ID" /etc/docker/daemon.json 0644 '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
'
    info "VM ${DOCKER_ID} : rotation des journaux (10 Mo x 3 par conteneur), redémarrage de Docker..."
    vm_run "$DOCKER_ID" 300 'systemctl restart docker; sleep 10; for d in /opt/apps/*/; do [ -f "${d}docker-compose.yml" ] && (cd "$d" && docker compose up -d --force-recreate >/dev/null 2>&1); done; docker ps --format "{{.Names}} {{.Status}}"'
    info "Terminé."
}

# Libère de l'espace dans la VM Docker : cache de build, images inutilisées, journaux système, cache apt.
docker_prune() {

    qm status "$DOCKER_ID" > /dev/null 2>&1 || die "VM ${DOCKER_ID} introuvable."

    vm_run "$DOCKER_ID" 900 'df -h / | tail -n 1; docker builder prune -af >/dev/null 2>&1; docker image prune -f >/dev/null 2>&1; journalctl --vacuum-size=50M >/dev/null 2>&1; apt-get clean; df -h / | tail -n 1'
}

# Agrandit le disque de la VM Docker (à chaud) : ./install.sh --run docker_disk_grow 32G  (ajoute 32 Go)
docker_disk_grow() {

    local add="${1:-32G}"

    [[ "$add" =~ ^[0-9]+G$ ]] || die "usage : docker_disk_grow <taille à ajouter, ex. 32G>"
    qm status "$DOCKER_ID" > /dev/null 2>&1 || die "VM ${DOCKER_ID} introuvable."

    info "VM ${DOCKER_ID} : agrandissement de scsi0 de +${add}..."
    qm resize "$DOCKER_ID" scsi0 "+${add}" || die "qm resize a échoué (stockage plein ? disque de la VM sur ${GUEST_STORAGE})."
    vm_run "$DOCKER_ID" 120 'growpart /dev/sda 1; resize2fs /dev/sda1; df -h / | tail -n 1'
}

# Déplace les disques des VM/CT du script vers un autre stockage (défaut : GUEST_STORAGE), pour libérer un petit disque
# système. Sans argument « apply » : affiche seulement ce qui serait déplacé.
#   ./install.sh --run guests_move_storage            (simulation)
#   ./install.sh --run guests_move_storage apply      (déplace ; chaque invité est arrêté puis redémarré)
guests_move_storage() {

    local mode="${1:-}" target="${2:-$GUEST_STORAGE}" g kind id disk vol was_running

    info "Stockage cible : ${target} (mode : ${mode:-simulation})."

    for g in $(health_guest_list); do
        kind="${g%%:*}" id="${g#*:}"
        if [[ "$kind" == "vm" ]]; then
            while read -r disk vol; do
                [[ "$vol" == "${target}:"* ]] && continue
                info "VM ${id} : ${disk} sur ${vol%%:*} -> ${target}"
                [[ "$mode" == "apply" ]] || continue
                qm move-disk "$id" "$disk" "$target" --delete 1 || warn "VM ${id} : déplacement de ${disk} échoué."
            done < <(qm config "$id" 2>/dev/null | awk -F'[: ,]+' '/^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:/ && $0 !~ /media=cdrom|cloudinit/ {print $1, $2":"$3}')
        else
            vol="$(pct config "$id" 2>/dev/null | sed -n 's/^rootfs: *\([^,]*\).*/\1/p')"
            [[ -n "$vol" && "$vol" != "${target}:"* ]] || continue
            info "CT ${id} : rootfs sur ${vol%%:*} -> ${target}"
            [[ "$mode" == "apply" ]] || continue
            was_running=false; pct status "$id" | grep -q running && was_running=true
            pct stop "$id" > /dev/null 2>&1 || true
            pct move-volume "$id" rootfs "$target" --delete 1 || warn "CT ${id} : déplacement échoué."
            [[ "$was_running" == "true" ]] && pct start "$id" > /dev/null 2>&1
        fi
    done

    [[ "$mode" == "apply" ]] || info "Simulation : relancez avec « apply » pour déplacer. Les VM sont déplacées à chaud, les CT arrêtés brièvement."
}


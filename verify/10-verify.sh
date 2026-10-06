###############################################################################
#                              FILES VERIFICATION                             #
###############################################################################

verify_files() {

    info "Vérification FILES..."

    qm status "$FILES_ID" |
        grep -q "status: running" \
        || die "La VM FILES n'est pas démarrée."

    local CONFIG
    CONFIG="$(qm config "$FILES_ID")"

    grep -q \
        "virtiofs0: dirid=${VIRTIOFS_DIR_ID}" \
        <<< "$CONFIG" \
        || die "VirtioFS absent de la VM FILES."

    grep -q "net0:" <<< "$CONFIG" \
        || die "Interface réseau absente de FILES."

    info "Configuration VM FILES OK."
}

###############################################################################
#                              GLOBAL VERIFICATION                            #
###############################################################################

verify_docker_apps() {

    [[ "$ENABLE_DOCKER" == "true" ]] || return 0

    info "Vérification des stacks Docker..."

    local -a apps=(nextcloud syncin immich homeassistant jellyfin)
    local app

    for app in "${apps[@]}"; do
        case "$app" in
            nextcloud) [[ "$ENABLE_NEXTCLOUD" == "true" ]] || continue ;;
            syncin) [[ "$ENABLE_SYNCIN" == "true" ]] || continue ;;
            immich) [[ "$ENABLE_IMMICH" == "true" ]] || continue ;;
            homeassistant) [[ "$ENABLE_HOMEASSISTANT" == "true" ]] || continue ;;
            jellyfin) [[ "$ENABLE_JELLYFIN" == "true" ]] || continue ;;
        esac

        if ! qm guest exec "$DOCKER_ID" -- bash -c "cd /opt/apps/${app} && docker compose ps --status running --format '{{.Name}}' | grep -q ." >/dev/null 2>&1; then
            warn "La stack ${app} n'est pas détectée comme démarrée. Diagnostic : qm guest exec ${DOCKER_ID} -- docker compose -f /opt/apps/${app}/docker-compose.yml ps"
        fi
    done
}

verify_installation() {

    echo
    echo "============================================================"
    echo " VÉRIFICATION FINALE"
    echo "============================================================"
    echo

    info "Node : ${NODE_NAME}"
    info "PVE  : $(pveversion --verbose | head -n 1)"

    echo
    info "Réseau :"
    ip -4 addr show "$LAN_BRIDGE"
    ip -4 addr show "$PRIVATE_BRIDGE"

    echo
    info "Routes :"
    ip route

    echo
    info "Forwarding :"
    sysctl net.ipv4.ip_forward

    echo
    info "NAT :"
    iptables -t nat -L POSTROUTING -n -v

    echo
    info "DATA :"
    findmnt "$DATA_MOUNT"
    df -h "$DATA_MOUNT"

    echo
    info "Arborescence SHARED :"
    find "$SHARED_DIR" -maxdepth 2 -type d -print | sort

    echo
    info "Storage DATA :"
    pvesh get /storage/DATA --output-format json

    echo
    info "VirtioFS mapping :"
    pvesh get \
        "/cluster/mapping/dir/${VIRTIOFS_DIR_ID}" \
        --output-format json

    if [[ "$ENABLE_FILES" == "true" ]]; then

        echo
        info "VM FILES :"
        qm config "$FILES_ID"

        echo
        info "Vérification Webmin :"

        qm status "$FILES_ID" |
            grep -q "status: running" \
            || die "FILES n'est pas démarrée."

        local WEBMIN_STATUS

        WEBMIN_STATUS="$(
            qm guest exec "$FILES_ID" \
                -- \
                systemctl is-active webmin \
                2>/dev/null |
                jq -r '.["out-data"] // empty' 2>/dev/null ||
                true
        )"

        if [[ -z "$WEBMIN_STATUS" ]]; then
            warn "Impossible de vérifier Webmin via qm guest exec."
            warn "La vérification détaillée sera effectuée depuis la VM."
        fi
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]]; then

        echo
        info "VM DOCKER :"
        qm config "$DOCKER_ID"
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then

        echo
        info "CT SWAG :"
        pct config "$SWAG_ID"
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]]; then

        echo
        info "CT XMRIG :"
        pct config "$XMRIG_ID"

        echo
        info "HugePages :"
        sysctl vm.nr_hugepages
        mountpoint "$HUGEPAGES_MOUNT"

        echo
        info "Monitor XMRig :"
        systemctl --no-pager --full status xmrig-monitor.service
    fi

    echo
    info "Dépôts Enterprise :"

    if [[ -e /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
        die "pve-enterprise.sources est encore actif."
    fi

    if [[ -e /etc/apt/sources.list.d/ceph.sources ]]; then
        die "ceph.sources Enterprise est encore actif."
    fi

    info "Vérification terminée."
}


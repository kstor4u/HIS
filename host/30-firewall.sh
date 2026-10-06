###############################################################################
#                              FAIL2BAN (HÔTE)                                #
###############################################################################

# Protège le SSH de l'hôte Proxmox lui-même - le service le plus exposé
# de toute l'installation (joignable depuis tout le LAN, et depuis
# Internet si le port 22 est un jour redirigé sur la box). SWAG a son
# propre fail2ban intégré pour nginx (actif par défaut, rien à faire) ;
# celui-ci protège la couche système de l'hôte, indépendante.
configure_fail2ban_host() {

    info "Configuration de fail2ban sur l'hôte (SSH)..."

    cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
EOF

    systemctl enable --now fail2ban \
        || warn "fail2ban ne s'est pas activé correctement sur l'hôte, vérifie : systemctl status fail2ban."
}

configure_forwarding() {

    info "Activation du forwarding IPv4..."

    cat > /etc/sysctl.d/99-proxmox-homelab.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

    sysctl --system

    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] \
        || die "Le forwarding IPv4 n'est pas actif."
}

###############################################################################
#                                   NAT                                       #
###############################################################################

configure_nat() {

    info "Configuration du NAT..."

    if ! iptables -t nat -C POSTROUTING \
        -s "${PRIVATE_NET}" \
        -o "${LAN_BRIDGE}" \
        -j MASQUERADE >/dev/null 2>&1; then

        iptables -t nat -A POSTROUTING \
            -s "${PRIVATE_NET}" \
            -o "${LAN_BRIDGE}" \
            -j MASQUERADE
    fi

    netfilter-persistent save

    systemctl enable netfilter-persistent
    systemctl restart netfilter-persistent

    iptables -t nat -C POSTROUTING \
        -s "${PRIVATE_NET}" \
        -o "${LAN_BRIDGE}" \
        -j MASQUERADE \
        || die "La règle NAT n'est pas présente."
}

###############################################################################
#                              PORT FORWARDS (LAN)                            #
###############################################################################

# Le réseau privé (vmbr1, 10.10.10.0/24) n'est pas routé depuis le LAN :
# une machine du LAN ne sait pas l'atteindre sans route statique configurée
# sur la box ou sur chaque poste, ce qu'un script tournant sur l'hôte ne
# peut pas faire. On redirige donc (DNAT) certains ports de l'IP LAN de
# l'hôte Proxmox vers les services internes, ce qui ne demande aucune route.
#
# Le trafic de retour n'a besoin d'aucune règle supplémentaire : la
# passerelle des VM/CT est l'hôte lui-même, et conntrack réécrit
# automatiquement la source des réponses d'une connexion DNAT.
#
# Usage : add_dnat_forward <port_hôte> <ip_destination> <port_destination>
add_dnat_forward() {

    local host_port="$1"
    local dest_ip="$2"
    local dest_port="$3"

    if ! iptables -t nat -C PREROUTING \
        -d "${LAN_IP}" \
        -p tcp --dport "$host_port" \
        -j DNAT --to-destination "${dest_ip}:${dest_port}" >/dev/null 2>&1; then

        iptables -t nat -A PREROUTING \
            -d "${LAN_IP}" \
            -p tcp --dport "$host_port" \
            -j DNAT --to-destination "${dest_ip}:${dest_port}"
    fi

    info "  ${LAN_IP}:${host_port} -> ${dest_ip}:${dest_port}"
}

# Samba (445, + 139 pour compat élargie) : \\<IP hôte>\SHARED depuis le LAN.
configure_samba_port_forward() {

    info "Configuration de la redirection de ports Samba (${LAN_IP} -> ${FILES_IP%%/*})..."

    add_dnat_forward 445 "${FILES_IP%%/*}" 445
    add_dnat_forward 139 "${FILES_IP%%/*}" 139

    netfilter-persistent save

    iptables -t nat -C PREROUTING \
        -d "${LAN_IP}" \
        -p tcp --dport 445 \
        -j DNAT --to-destination "${FILES_IP%%/*}:445" \
        || die "La règle DNAT Samba (445) n'est pas présente."
}

# Interfaces web : SWAG (80/443, nécessaires à la validation Let's
# Encrypt et à l'accès depuis Internet une fois 80/443 redirigés de la
# box vers l'IP de l'hôte), les 3 applications en accès direct HTTP pour
# les tests, et Webmin.
#
# Les ports des applications (HTTP en clair) et Webmin (10000) ne sont
# joignables que depuis le LAN : ne les redirige PAS depuis ta box vers
# Internet. Seuls 80 et 443 ont vocation à l'être.
#
# Ces redirections priment sur le service local de l'hôte : le port 80
# de l'hôte ne répondra plus, l'interface Proxmox reste sur :8006.
configure_web_port_forwards() {

    info "Configuration des redirections de ports web (${LAN_IP} -> réseau privé)..."

    if [[ "$ENABLE_SWAG" == "true" ]]; then
        add_dnat_forward 80 "${SWAG_IP%%/*}" 80
        add_dnat_forward 443 "${SWAG_IP%%/*}" 443
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]]; then

        if [[ "$ENABLE_NEXTCLOUD" == "true" ]]; then
            add_dnat_forward "$NEXTCLOUD_HTTP_PORT" "${DOCKER_IP%%/*}" "$NEXTCLOUD_HTTP_PORT"
        fi

        if [[ "$ENABLE_SYNCIN" == "true" ]]; then
            add_dnat_forward "$SYNCIN_HTTP_PORT" "${DOCKER_IP%%/*}" "$SYNCIN_HTTP_PORT"
        fi

        if [[ "$ENABLE_IMMICH" == "true" ]]; then
            add_dnat_forward "$IMMICH_HTTP_PORT" "${DOCKER_IP%%/*}" "$IMMICH_HTTP_PORT"
        fi

        if [[ "$ENABLE_HOMEASSISTANT" == "true" ]]; then
            add_dnat_forward "$HOMEASSISTANT_HTTP_PORT" "${DOCKER_IP%%/*}" "$HOMEASSISTANT_HTTP_PORT"
        fi

        if [[ "$ENABLE_JELLYFIN" == "true" ]]; then
            add_dnat_forward "$JELLYFIN_HTTP_PORT" "${DOCKER_IP%%/*}" "$JELLYFIN_HTTP_PORT"
        fi
    fi

    if [[ "$ENABLE_FILES" == "true" ]]; then
        add_dnat_forward 10000 "${FILES_IP%%/*}" 10000
    fi

    netfilter-persistent save
}


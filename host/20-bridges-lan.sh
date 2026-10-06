###############################################################################
#                              PRIVATE NETWORK                                #
###############################################################################

configure_private_bridge() {

    info "Vérification de ${PRIVATE_BRIDGE}..."

    if ! grep -q "^auto ${PRIVATE_BRIDGE}$" /etc/network/interfaces; then

        cat >> /etc/network/interfaces <<EOF

auto ${PRIVATE_BRIDGE}
iface ${PRIVATE_BRIDGE} inet static
    address ${PRIVATE_GW}/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

        ifreload -a
    fi

    ip link show "${PRIVATE_BRIDGE}" >/dev/null 2>&1 \
        || die "${PRIVATE_BRIDGE} n'existe pas."

    ip -4 addr show "${PRIVATE_BRIDGE}" |
        grep -q "${PRIVATE_GW}/24" \
        || die "${PRIVATE_BRIDGE} n'a pas l'adresse ${PRIVATE_GW}/24."
}

###############################################################################
#                              IP FORWARDING                                  #
###############################################################################

###############################################################################
#                              LAN EN DHCP                                    #
###############################################################################

# Bascule LAN_BRIDGE (vmbr0) de statique à DHCP dans /etc/network/interfaces,
# recharge la config (ifreload -a, natif ifupdown2, déjà utilisé ailleurs
# dans ce script pour vmbr1 - pas de coupure brutale type ifdown/ifup),
# puis attend que l'interface obtienne une adresse et met à jour LAN_IP
# en conséquence pour le reste du script.
switch_lan_to_dhcp() {

    local iface_file="/etc/network/interfaces"
    local backup_file="/etc/network/interfaces.bak-$(date +%Y%m%d%H%M%S)"

    if ! grep -q "^iface ${LAN_BRIDGE} inet static" "$iface_file"; then
        warn "${LAN_BRIDGE} ne semble pas configuré en IP statique dans ${iface_file} (ou format non reconnu) : passage en DHCP ignoré."
        return 0
    fi

    info "Sauvegarde de ${iface_file} vers ${backup_file} avant modification..."
    cp "$iface_file" "$backup_file"

    info "Passage de ${LAN_BRIDGE} en DHCP (IP statique actuelle : ${LAN_IP})..."
    info "Si l'IP négociée diffère, toute session SSH/web en cours sur ${LAN_IP} va se couper maintenant."

    awk -v iface="$LAN_BRIDGE" '
        BEGIN { in_block = 0 }
        $0 ~ "^iface " iface " inet static" {
            print "iface " iface " inet dhcp"
            in_block = 1
            next
        }
        in_block && /^[[:space:]]*(address|netmask|gateway|broadcast|network)[[:space:]]/ {
            print "#" $0
            next
        }
        in_block && (/^$/ || /^auto / || /^iface /) {
            in_block = 0
        }
        { print }
    ' "$iface_file" > "${iface_file}.new"

    mv "${iface_file}.new" "$iface_file"

    ifreload -a

    info "Attente de l'obtention d'une adresse DHCP sur ${LAN_BRIDGE}..."

    local attempt new_ip=""

    for ((attempt = 1; attempt <= 20; attempt++)); do

        new_ip="$(detect_lan_ip)"

        [[ -n "$new_ip" ]] && break

        sleep 1
    done

    if [[ -z "$new_ip" ]]; then
        die "Impossible d'obtenir une adresse DHCP sur ${LAN_BRIDGE} après 20s. Config sauvegardée dans ${backup_file} : pour revenir en arrière, cp ${backup_file} ${iface_file} && ifreload -a (depuis la console, pas en SSH si le réseau est down)."
    fi

    LAN_IP="$new_ip"

    info "${LAN_BRIDGE} a obtenu l'adresse ${LAN_IP} via DHCP."
}

# Renvoie "dhcp" ou "static" selon la méthode actuellement configurée
# pour LAN_BRIDGE dans /etc/network/interfaces ("unknown" si ni l'un ni
# l'autre n'est trouvé, format non reconnu).
detect_lan_mode() {

    local method

    method="$(
        awk -v iface="$LAN_BRIDGE" '
            $0 ~ "^iface " iface " inet (static|dhcp)" { print $4; exit }
        ' /etc/network/interfaces
    )"

    echo "${method:-unknown}"
}

# Bascule LAN_BRIDGE vers une IP statique donnée (que l'état actuel soit
# déjà statique avec une autre IP, ou DHCP). Conserve la passerelle
# existante si l'interface était déjà statique, sinon utilise LAN_GW.
# Même mécanique prudente que switch_lan_to_dhcp() : sauvegarde,
# ifreload -a, vérification après coup.
switch_lan_to_static() {

    local new_ip="$1"
    local iface_file="/etc/network/interfaces"
    local backup_file="/etc/network/interfaces.bak-$(date +%Y%m%d%H%M%S)"

    if ! grep -qE "^iface ${LAN_BRIDGE} inet (static|dhcp)" "$iface_file"; then
        warn "${LAN_BRIDGE} non reconnu dans ${iface_file} (format inattendu) : passage en IP statique ignoré."
        return 0
    fi

    info "Sauvegarde de ${iface_file} vers ${backup_file} avant modification..."
    cp "$iface_file" "$backup_file"

    local cidr="${LAN_NET##*/}"
    [[ -n "$cidr" ]] || cidr="24"

    local gateway
    gateway="$(
        awk -v iface="$LAN_BRIDGE" '
            $0 ~ "^iface " iface " inet static" { in_block = 1; next }
            in_block && /^[[:space:]]*gateway[[:space:]]/ { print $2; exit }
            in_block && (/^$/ || /^auto / || /^iface /) { exit }
        ' "$iface_file"
    )"
    [[ -n "$gateway" ]] || gateway="$LAN_GW"

    info "Passage de ${LAN_BRIDGE} en IP statique ${new_ip}/${cidr} (passerelle ${gateway})..."
    info "Si cette IP diffère de l'actuelle (${LAN_IP}), toute session SSH/web en cours va se couper maintenant."

    awk -v iface="$LAN_BRIDGE" -v newip="$new_ip" -v cidr="$cidr" -v gw="$gateway" '
        BEGIN { in_block = 0 }
        $0 ~ "^iface " iface " inet (static|dhcp)" {
            print "iface " iface " inet static"
            print "\taddress " newip "/" cidr
            print "\tgateway " gw
            in_block = 1
            next
        }
        in_block && /^[[:space:]]*(address|netmask|gateway|broadcast|network)[[:space:]]/ {
            next
        }
        in_block && (/^$/ || /^auto / || /^iface /) {
            in_block = 0
        }
        { print }
    ' "$iface_file" > "${iface_file}.new"

    mv "${iface_file}.new" "$iface_file"

    ifreload -a

    sleep 2

    local confirmed_ip
    confirmed_ip="$(detect_lan_ip)"

    if [[ "$confirmed_ip" != "$new_ip" ]]; then
        die "L'IP configurée (${new_ip}) ne correspond pas à l'IP détectée après rechargement (${confirmed_ip:-aucune}). Config sauvegardée dans ${backup_file} : cp ${backup_file} ${iface_file} && ifreload -a pour revenir en arrière."
    fi

    LAN_IP="$new_ip"

    info "${LAN_BRIDGE} configuré en IP statique ${LAN_IP}."
}

# Prompt "au tout début" du script, ou résolution automatique via le
# fichier de réponses (variable HOST_IP : "DHCP" ou une IP fixe).
# N'applique un changement RÉEL (DHCP ou IP statique) que si l'état
# demandé diffère de l'état actuel ; sinon ne touche à rien. Tout
# changement réel arrête volontairement le script ensuite : mieux vaut
# vérifier la nouvelle IP et relancer proprement que de continuer dans
# la foulée sur un réseau tout juste modifié (session SSH coupée, ou
# réservation DHCP pas encore visible).
configure_lan_ip_interactive() {

    local current_ip="$LAN_IP"
    local current_mode
    current_mode="$(detect_lan_mode)"

    local answer

    _apply_and_exit_dhcp() {
        switch_lan_to_dhcp
        echo
        echo "============================================================"
        echo " ${LAN_BRIDGE} est maintenant en DHCP. IP obtenue : ${LAN_IP}"
        echo " Vérifie que c'est la bonne IP, puis RELANCE le script."
        echo "============================================================"
        exit 0
    }

    _apply_and_exit_static() {
        switch_lan_to_static "$1"
        echo
        echo "============================================================"
        echo " ${LAN_BRIDGE} est maintenant en IP statique ${LAN_IP}."
        echo " Vérifie la connectivité, puis RELANCE le script."
        echo "============================================================"
        exit 0
    }

    if [[ "$ANSWERS_FILE_LOADED" == "true" ]]; then

        if [[ -z "$HOST_IP" ]]; then
            return 0
        fi

        if [[ "${HOST_IP^^}" == "DHCP" ]]; then

            if [[ "$current_mode" == "dhcp" ]]; then
                info "${LAN_BRIDGE} est déjà en DHCP, rien à changer."
                return 0
            fi

            _apply_and_exit_dhcp
        fi

        if [[ "$current_mode" == "static" && "$HOST_IP" == "$current_ip" ]]; then
            info "${LAN_BRIDGE} a déjà l'IP statique demandée (${HOST_IP}), rien à changer."
            return 0
        fi

        _apply_and_exit_static "$HOST_IP"
    fi

    echo
    echo "IP actuelle de l'hôte sur ${LAN_BRIDGE} : ${current_ip} (${current_mode})"

    while true; do

        read -r -p "IP fixe à utiliser [${current_ip}] (Entrée = garder, ou tape DHCP) : " answer

        if [[ -z "$answer" ]]; then
            info "Conservation de la configuration actuelle : ${current_ip} (${current_mode})."
            return 0
        fi

        if [[ "${answer^^}" == "DHCP" ]]; then

            if [[ "$current_mode" == "dhcp" ]]; then
                info "${LAN_BRIDGE} est déjà en DHCP, rien à changer."
                return 0
            fi

            _apply_and_exit_dhcp
        fi

        if [[ "$answer" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

            if [[ "$current_mode" == "static" && "$answer" == "$current_ip" ]]; then
                info "C'est déjà l'IP actuelle, rien à changer."
                return 0
            fi

            _apply_and_exit_static "$answer"
        fi

        echo "Format invalide : tape une IP (ex: 192.168.1.10) ou DHCP."
    done
}


###############################################################################
#                              REPOSITORIES                                   #
###############################################################################

configure_repositories() {

    info "Configuration des dépôts Proxmox..."

    if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then

        mv \
            /etc/apt/sources.list.d/pve-enterprise.sources \
            /etc/apt/sources.list.d/pve-enterprise.sources.disabled
    fi

    if [[ -f /etc/apt/sources.list.d/ceph.sources ]]; then

        mv \
            /etc/apt/sources.list.d/ceph.sources \
            /etc/apt/sources.list.d/ceph.sources.disabled
    fi

    cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    cat > /etc/apt/sources.list.d/ceph-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    apt-get update
}

###############################################################################
#                              HOST DEPENDENCIES                              #
###############################################################################

install_host_dependencies() {

    info "Vérification des dépendances hôte..."

    # Préconfiguration debconf pour iptables-persistent, qui pose sinon
    # des questions interactives ("Save current IPv4 rules?") capables
    # de bloquer le script même avec DEBIAN_FRONTEND=noninteractive si
    # le paquet n'a jamais été configuré sur cet hôte.
    if command -v debconf-set-selections >/dev/null 2>&1; then

        printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' \
            | debconf-set-selections

        printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' \
            | debconf-set-selections
    fi

    local missing=()
    local pkg

    for pkg in "${HOST_PACKAGES[@]}"; do

        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
            grep -q '^install ok installed$'; then

            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]} == 0)); then

        info "Toutes les dépendances hôte sont déjà installées."

    else

        log "Paquets manquants : ${missing[*]}"
        log "Simulation APT avant installation..."

        local simulation

        if ! simulation="$(apt-get -s install "${missing[@]}" 2>&1)"; then

            printf '%s\n' "$simulation"

            die "La simulation APT a échoué. Installation annulée."
        fi

        printf '%s\n' "$simulation"

        local critical

        for critical in \
            proxmox-ve \
            pve-manager \
            pve-qemu-kvm \
            qemu-server \
            pve-container \
            pve-ha-manager
        do

            if printf '%s\n' "$simulation" |
                grep -Eq \
                "(^|[[:space:]])(Remv|Purg)[[:space:]]+${critical}([[:space:]]|$)"
            then

                die \
                    "SECURITE APT : la transaction supprimerait ${critical}. Installation annulée."
            fi
        done

        log "Simulation APT acceptable."
        log "Installation réelle des dépendances..."

        apt-get install -y --no-remove "${missing[@]}" \
            || die "Échec de l'installation des dépendances hôte."

        info "Dépendances hôte installées."
    fi

    dpkg -s virtiofsd >/dev/null 2>&1 \
        || die "Le paquet virtiofsd n'est pas installé."

    [[ -x /usr/libexec/virtiofsd ]] \
        || die "/usr/libexec/virtiofsd n'est pas exécutable."

    command -v openssl >/dev/null 2>&1 \
        || die "openssl est introuvable."

    command -v base64 >/dev/null 2>&1 \
        || die "base64 est introuvable."

    info "virtiofsd vérifié : /usr/libexec/virtiofsd"
}


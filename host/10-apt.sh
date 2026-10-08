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

# Neutralise la fenêtre "You do not have a valid subscription for this server"
# de l'interface web (proxmox-widget-toolkit). Le contrôle est modifié pour ne
# jamais conclure à une absence d'abonnement : la fenêtre n'apparaît plus ET la
# commande qu'elle protège s'exécute normalement (contrairement au correctif
# répandu qui remplace Ext.Msg.show par void() et empêche cette commande).
# Un hook APT réapplique le correctif après chaque mise à jour du paquet.
# Si la structure du fichier est inconnue (nouvelle version), rien n'est modifié.
# Annuler : apt reinstall proxmox-widget-toolkit (et supprimer le hook APT).
disable_subscription_nag() {

    if [[ "${DISABLE_SUBSCRIPTION_NAG:-true}" != "true" ]]; then
        info "Fenêtre d'abonnement Proxmox : laissée telle quelle (DISABLE_SUBSCRIPTION_NAG=false)."
        return 0
    fi

    local TOOL="/usr/local/sbin/proxmox-no-nag"
    local HOOK="/etc/apt/apt.conf.d/99-proxmox-no-nag"

    info "Fenêtre d'abonnement Proxmox : neutralisation..."

    cat > "$TOOL" <<'NAGTOOL'
#!/usr/bin/env bash
# Neutralise la fenêtre "No valid subscription" de l'interface web Proxmox.
# Réappliqué après chaque mise à jour de proxmox-widget-toolkit (hook APT).
JS="${PVE_JS:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
MARK="__nag_disabled__"

[[ -f "$JS" ]] || exit 0

# Déjà neutralisé
if grep -q "$MARK" "$JS"; then
    exit 0
fi

PATTERN="(res === null \|\| res === undefined \|\| !res \|\| res\s*\.data\.status\.toLowerCase\(\) )!== 'active'"

if ! grep -Pzq 'res === null \|\| res === undefined \|\| !res \|\| res\s*\.data\.status\.toLowerCase\(\) !== .active.' "$JS"; then
    echo "proxmox-no-nag : structure de proxmoxlib.js inconnue (nouvelle version ?), aucune modification." >&2
    exit 0
fi

[[ -f "${JS}.bak" ]] || cp -a "$JS" "${JS}.bak"

sed -Ezi "s/${PATTERN}/\1=== '${MARK}'/" "$JS"

if grep -q "$MARK" "$JS"; then
    echo "proxmox-no-nag : fenêtre d'abonnement neutralisée."
    systemctl restart pveproxy 2>/dev/null || true
fi

exit 0
NAGTOOL

    chmod 0755 "$TOOL"

    cat > "$HOOK" <<NAGHOOK
// Réapplique la neutralisation de la fenêtre d'abonnement après chaque mise à jour APT.
DPkg::Post-Invoke { "${TOOL} || true"; };
NAGHOOK

    "$TOOL" || true

    info "Fenêtre d'abonnement : actualise le navigateur avec Ctrl+F5 pour recharger l'interface."
}

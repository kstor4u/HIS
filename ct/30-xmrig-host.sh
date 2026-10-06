###############################################################################
#                              HUGE PAGES                                     #
###############################################################################

configure_hugepages() {

    info "Configuration HugePages hôte..."

    cat > /etc/sysctl.d/99-xmrig-hugepages.conf <<EOF
vm.nr_hugepages=${HUGEPAGES_COUNT}
EOF

    sysctl --system

    mkdir -p "$HUGEPAGES_MOUNT"

    if ! mountpoint -q "$HUGEPAGES_MOUNT"; then

        mount -t hugetlbfs \
            -o pagesize=2M,mode=1777 \
            none \
            "$HUGEPAGES_MOUNT"
    fi

    if ! grep -q "$HUGEPAGES_MOUNT" /etc/fstab; then

        printf \
            'none %s hugetlbfs pagesize=2M,mode=1777 0 0\n' \
            "$HUGEPAGES_MOUNT" >> /etc/fstab
    fi

    mountpoint -q "$HUGEPAGES_MOUNT" \
        || die "HugePages non montées."

    local CURRENT_HUGEPAGES

    CURRENT_HUGEPAGES="$(sysctl -n vm.nr_hugepages)"

    [[ "$CURRENT_HUGEPAGES" -ge "$HUGEPAGES_COUNT" ]] \
        || die "Nombre de HugePages insuffisant."
}

###############################################################################
#                              MSR (RandomX)                                  #
###############################################################################

# Applique le réglage MSR recommandé par XMRig pour RandomX (désactive
# les préfetchers matériels Intel via le registre 0x1a4, gain typique
# 10-15% de hashrate). Fait sur l'HÔTE, pas dans le CT XMRig : les MSR
# sont un état du CPU physique partagé par tout l'hôte, pas quelque
# chose qu'un conteneur (même privilégié) peut régler pour lui-même -
# XMRig continuera d'afficher un avertissement MSR dans le CT, ignorable
# une fois que ce service a tourné sur l'hôte.
#
# Le module "msr" est déchargé juste après l'écriture (sauf s'il était
# déjà chargé par autre chose) : le réglage reste actif dans le CPU,
# mais /dev/cpu/*/msr, qui permet d'écrire n'importe quel registre du
# processeur, ne reste pas exposé en permanence.
configure_msr_optimization() {

    info "Configuration de l'optimisation MSR (RandomX) sur l'hôte..."

    if ! dpkg -s msr-tools >/dev/null 2>&1; then

        apt-get install -y --no-remove msr-tools || {
            warn "Échec de l'installation de msr-tools : optimisation MSR ignorée (XMRig fonctionnera quand même, juste avec un hashrate un peu plus faible)."
            return 0
        }
    fi

    cat > /usr/local/sbin/xmrig-msr-tune.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

VENDOR="$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)"

if [[ "$VENDOR" != "GenuineIntel" ]]; then
    echo "CPU non-Intel détecté (${VENDOR:-inconnu}) : réglage MSR 0x1a4 ignoré (spécifique Intel)." >&2
    exit 0
fi

MODULE_WAS_LOADED=false

if lsmod | grep -q '^msr '; then
    MODULE_WAS_LOADED=true
fi

modprobe msr

# Registre 0x1a4 : désactive les 4 préfetchers matériels Intel
# (documenté par Intel, recommandation officielle XMRig pour RandomX).
wrmsr -a 0x1a4 0xf

if [[ "$MODULE_WAS_LOADED" != "true" ]]; then
    rmmod msr
fi
EOF

    chmod 755 /usr/local/sbin/xmrig-msr-tune.sh

    cat > /etc/systemd/system/xmrig-msr-tune.service <<'EOF'
[Unit]
Description=Reglage MSR RandomX pour XMRig (prefetchers desactives)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xmrig-msr-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    # || true : une optimisation de perf ne doit jamais faire échouer
    # toute l'installation. Sans ça, "systemctl enable --now" qui échoue
    # (ex: CPU non-Intel avant l'ajout du contrôle ci-dessus, ou noyau
    # restreignant l'accès aux MSR) tue le script entier via set -e,
    # avant même d'atteindre le "warn" cense gérer cet échec juste après.
    systemctl enable --now xmrig-msr-tune.service || true

    systemctl is-active --quiet xmrig-msr-tune.service \
        || warn "xmrig-msr-tune inactif (CPU non-Intel, ou noyau restreignant l'accès aux MSR) : XMRig fonctionnera, juste avec un hashrate un peu plus faible."
}


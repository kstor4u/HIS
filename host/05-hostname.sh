###############################################################################
#                    NOM D'HÔTE DU SERVEUR PROXMOX (HOST_NAME)                #
###############################################################################

# HOST_NAME vide = on ne touche à rien. Sinon le nom est appliqué AVANT tout le reste
# (stockage, VirtioFS, fichier source du serveur de sauvegarde, export USB utilisent ce nom).
# Proxmox ne prend un nouveau nom qu'au redémarrage : le script s'arrête donc après le
# changement ; relance-le une fois la machine redémarrée.
#
# Sûr uniquement sur un serveur SANS VM/CT et hors cluster : le nom du nœud est inscrit dans
# les configurations des VM/CT (/etc/pve/nodes/<nom>/...). Sinon : refusé, rien n'est modifié.

configure_hostname() {

    [[ -n "${HOST_NAME:-}" ]] || return 0

    [[ "$HOST_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$ ]] \
        || die "HOST_NAME invalide ('${HOST_NAME}') : lettres minuscules, chiffres et tirets, 1 à 30 caractères, ni début ni fin par un tiret."

    local cur old_fqdn suffix new_fqdn n_guests

    cur="$(hostname -s)"

    if [[ "$HOST_NAME" == "$cur" ]]; then
        info "Nom d'hôte : déjà '${cur}'."
        return 0
    fi

    if [[ -f /etc/pve/corosync.conf ]]; then
        die "HOST_NAME : ce serveur fait partie d'un cluster Proxmox, renommer un nœud de cluster n'est pas pris en charge ici."
    fi

    n_guests=$( { qm list 2>/dev/null | tail -n +2; pct list 2>/dev/null | tail -n +2; } | wc -l )

    if (( n_guests > 0 )); then
        die "HOST_NAME : ${n_guests} VM/CT existent déjà sur '${cur}'. Les renommer avec le nœud casserait leurs configurations : le nom d'hôte ne peut être changé que sur un serveur vierge. Laisse HOST_NAME vide, ou change-le toi-même (procédure Proxmox de renommage de nœud)."
    fi

    old_fqdn="$(hostname -f 2>/dev/null || echo "$cur")"
    suffix=""
    [[ "$old_fqdn" == "${cur}."* ]] && suffix="${old_fqdn#"$cur"}"
    new_fqdn="${HOST_NAME}${suffix}"

    cp -a /etc/hosts "/etc/hosts.bak-hostname-$(date +%Y%m%d-%H%M%S)"

    awk -v of="$old_fqdn" -v os="$cur" -v nf="$new_fqdn" -v ns="$HOST_NAME" '
        /^[[:space:]]*#/ { print; next }
        { for (i = 1; i <= NF; i++) { if ($i == of) $i = nf; else if ($i == os) $i = ns }
          print }' /etc/hosts > /etc/hosts.new
    cat /etc/hosts.new > /etc/hosts
    rm -f /etc/hosts.new

    printf '%s\n' "$HOST_NAME" > /etc/hostname
    hostnamectl set-hostname "$HOST_NAME" 2>/dev/null || hostname "$HOST_NAME"

    grep -qw "$HOST_NAME" /etc/hosts \
        || die "Après modification, /etc/hosts ne mentionne pas '${HOST_NAME}' : ajoute une ligne '<IP du serveur> ${new_fqdn} ${HOST_NAME}' (ancienne copie : /etc/hosts.bak-hostname-*)."

    echo
    info "Nom d'hôte changé : ${cur} -> ${HOST_NAME} (/etc/hostname et /etc/hosts mis à jour)."
    echo "ARRÊT : redémarre le serveur (reboot) pour que Proxmox prenne le nouveau nom, puis relance ./install.sh."
    echo "(Après le redémarrage, le dossier vide /etc/pve/nodes/${cur} peut être supprimé : rmdir /etc/pve/nodes/${cur})"
    exit 0
}

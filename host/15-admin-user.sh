###############################################################################
#                     COMPTE ADMINISTRATEUR (sudo) SUR L'HÔTE                  #
###############################################################################

# Crée un utilisateur non-root membre de sudo (réglages ADMIN_* dans
# core/00-config.sh). Sans ADMIN_USER, ne fait rien. Idempotent : peut être
# relancé seul avec ./install.sh --run configure_admin_user
configure_admin_user() {

    local user="${ADMIN_USER:-}" password="${ADMIN_PASSWORD:-}" generated=false
    local sudoers_file home

    [[ -n "$user" ]] || {
        info "Compte administrateur : ADMIN_USER vide, aucun compte créé."
        return 0
    }

    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "ADMIN_USER='${user}' invalide (minuscules, chiffres, - et _ ; pas root)."
    [[ "$user" != "root" ]] || die "ADMIN_USER ne peut pas être root."

    command -v sudo >/dev/null 2>&1 || {
        info "Installation de sudo..."
        apt-get install -y sudo >/dev/null
    }

    if id "$user" >/dev/null 2>&1; then
        info "Compte ${user} : existe déjà (mot de passe conservé sauf si ADMIN_PASSWORD est défini)."
    else
        info "Création du compte ${user}..."
        useradd -m -s /bin/bash "$user"

        if [[ -z "$password" ]]; then
            password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')"
            generated=true
        fi
    fi

    if [[ -n "$password" ]]; then
        printf '%s:%s\n' "$user" "$password" | chpasswd
    fi

    usermod -aG sudo "$user"

    # Règle sudoers dédiée (validée par visudo avant activation).
    sudoers_file="${SUDOERS_DIR:-/etc/sudoers.d}/90-homelab-${user}"
    if [[ "${ADMIN_SUDO_NOPASSWD:-false}" == "true" ]]; then
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > "${sudoers_file}.tmp"
    else
        printf '%s ALL=(ALL:ALL) ALL\n' "$user" > "${sudoers_file}.tmp"
    fi
    chmod 440 "${sudoers_file}.tmp"

    if visudo -cf "${sudoers_file}.tmp" >/dev/null; then
        mv "${sudoers_file}.tmp" "$sudoers_file"
    else
        rm -f "${sudoers_file}.tmp"
        die "Règle sudoers invalide pour ${user} : non appliquée."
    fi

    # Clé SSH publique optionnelle.
    if [[ -n "${ADMIN_SSH_KEY:-}" ]]; then
        home="$(getent passwd "$user" | cut -d: -f6)"
        install -d -m 700 -o "$user" -g "$user" "${home}/.ssh"
        touch "${home}/.ssh/authorized_keys"
        grep -qxF "$ADMIN_SSH_KEY" "${home}/.ssh/authorized_keys" \
            || printf '%s\n' "$ADMIN_SSH_KEY" >> "${home}/.ssh/authorized_keys"
        chown "$user:$user" "${home}/.ssh/authorized_keys"
        chmod 600 "${home}/.ssh/authorized_keys"
        info "Compte ${user} : clé SSH publique installée."
    fi

    # Accès à l'interface web Proxmox (realm "Linux PAM") avec le rôle Administrator.
    if [[ "${ADMIN_PVE_ACCESS:-true}" == "true" ]] && command -v pveum >/dev/null 2>&1; then
        pveum user add "${user}@pam" >/dev/null 2>&1 || true
        pveum acl modify / --users "${user}@pam" --roles Administrator >/dev/null 2>&1 \
            || warn "Compte ${user} : rôle Administrator Proxmox non appliqué (à faire dans Datacenter > Permissions)."
    fi

    info "Compte administrateur ${user} prêt (sudo : $([[ "${ADMIN_SUDO_NOPASSWD:-false}" == "true" ]] && echo "sans mot de passe" || echo "avec mot de passe"))."

    if [[ "$generated" == "true" ]]; then
        warn "Mot de passe généré pour ${user} : ${password}  (notez-le puis changez-le avec 'passwd')."
    fi
}

# Interdit (ou limite aux clés) la connexion SSH directe de root. Garde-fous : le compte administrateur
# doit exister, être dans sudo et pouvoir se connecter ; la configuration est testée (sshd -t) avant
# rechargement, et la session SSH en cours n'est pas coupée. Idempotent.
configure_ssh_root_login() {

    local mode="${SSH_ROOT_LOGIN:-}" user="${ADMIN_USER:-}"
    local dropin="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/90-homelab-root.conf}"
    local sshd_main="${SSHD_MAIN:-/etc/ssh/sshd_config}"

    [[ -n "$mode" ]] || return 0

    case "$mode" in
        no | prohibit-password) ;;
        *) die "SSH_ROOT_LOGIN='${mode}' invalide (no | prohibit-password | vide)." ;;
    esac

    if [[ "$mode" == "no" ]]; then

        [[ -n "$user" ]] \
            || die "SSH_ROOT_LOGIN=no demande ADMIN_USER : sinon plus aucun compte ne pourrait se connecter en SSH."
        id "$user" >/dev/null 2>&1 \
            || die "Compte ${user} introuvable : SSH root non modifié."
        id -nG "$user" | tr ' ' '\n' | grep -qx sudo \
            || die "Compte ${user} absent du groupe sudo : SSH root non modifié."

        local home keyfile has_key=false
        home="$(getent passwd "$user" | cut -d: -f6)"
        keyfile="${home}/.ssh/authorized_keys"
        [[ -s "$keyfile" ]] && has_key=true

        # Sans clé, l'authentification par mot de passe doit être possible pour ce compte
        if [[ "$has_key" != "true" ]] && ! passwd -S "$user" 2>/dev/null | awk '{exit !($2 == "P")}'; then
            die "Compte ${user} sans clé SSH ni mot de passe utilisable : SSH root non modifié (définis ADMIN_SSH_KEY ou ADMIN_PASSWORD)."
        fi
    fi

    install -d -m 755 "$(dirname "$dropin")"

    # Le fichier principal doit inclure le dossier .d (premier réglage rencontré gagne : Include en tête)
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$sshd_main" 2>/dev/null; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$sshd_main"
    fi

    printf '# Généré par l installateur homelab (SSH_ROOT_LOGIN)\nPermitRootLogin %s\n' "$mode" > "${dropin}.tmp"

    if [[ -z "${SSHD_SKIP_TEST:-}" ]]; then
        # Test de la configuration complète avec le nouveau fichier en place
        mv "${dropin}.tmp" "$dropin"
        if ! sshd -t 2>/dev/null; then
            rm -f "$dropin"
            die "Configuration sshd invalide avec ce réglage : annulé."
        fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
        mv "${dropin}.tmp" "$dropin"
    fi

    if [[ "$mode" == "no" ]]; then
        info "SSH : connexion directe de root INTERDITE. Connexion : ssh ${user}@<serveur>, puis sudo -i. (Interface web : root@pam inchangé.)"
        warn "Teste TOUT DE SUITE dans une 2e fenêtre : ssh ${user}@<serveur> puis sudo -i, avant de fermer cette session."
    else
        info "SSH : root ne peut plus se connecter que par clé (PermitRootLogin prohibit-password)."
    fi
}

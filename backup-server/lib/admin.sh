#!/usr/bin/env bash
# Compte administrateur (sudo) et blocage de la connexion SSH directe de root sur le N54L.
# Chargé par install.sh. Réglages dans /etc/homelab-backup/backup.conf :
#   ADMIN_USER, ADMIN_PASSWORD (vide = généré), ADMIN_SSH_KEY (clé publique), SSH_ROOT_LOGIN (no | prohibit-password)

hb_configure_admin() {

    local user="${ADMIN_USER:-}" password="${ADMIN_PASSWORD:-}" generated=false home
    local mode="${SSH_ROOT_LOGIN:-}"
    local dropin="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/90-homelab-root.conf}"
    local sshd_main="${SSHD_MAIN:-/etc/ssh/sshd_config}"

    if [[ -n "$user" ]]; then
        [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] || { echo "ADMIN_USER invalide."; return 1; }
        command -v sudo >/dev/null 2>&1 || apt-get install -y sudo >/dev/null

        if ! id "$user" >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$user"
            if [[ -z "$password" ]]; then
                password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')"; generated=true
            fi
        fi
        [[ -n "$password" ]] && printf '%s:%s\n' "$user" "$password" | chpasswd
        usermod -aG sudo "$user"

        if [[ -n "${ADMIN_SSH_KEY:-}" ]]; then
            home="$(getent passwd "$user" | cut -d: -f6)"
            install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
            touch "$home/.ssh/authorized_keys"
            grep -qxF "$ADMIN_SSH_KEY" "$home/.ssh/authorized_keys" || printf '%s\n' "$ADMIN_SSH_KEY" >> "$home/.ssh/authorized_keys"
            chown "$user:$user" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
        fi
        echo "Compte administrateur $user prêt (sudo avec mot de passe)."
        [[ "$generated" == "true" ]] && echo "⚠ Mot de passe généré pour $user : $password  (note-le puis change-le avec 'passwd')."
        if command -v pveum >/dev/null 2>&1; then
            pveum user add "${user}@pam" >/dev/null 2>&1 || true
            pveum acl modify / --users "${user}@pam" --roles Administrator >/dev/null 2>&1 || true
        fi
    fi

    [[ -n "$mode" ]] || return 0
    case "$mode" in no | prohibit-password) ;; *) echo "SSH_ROOT_LOGIN invalide (no | prohibit-password)."; return 1 ;; esac

    if [[ "$mode" == "no" ]]; then
        [[ -n "$user" ]] && id "$user" >/dev/null 2>&1 || { echo "SSH_ROOT_LOGIN=no demande ADMIN_USER : SSH root non modifié."; return 1; }
        id -nG "$user" | tr ' ' '\n' | grep -qx sudo || { echo "$user n'est pas dans sudo : SSH root non modifié."; return 1; }
        home="$(getent passwd "$user" | cut -d: -f6)"
        if [[ ! -s "$home/.ssh/authorized_keys" ]] && ! passwd -S "$user" 2>/dev/null | awk '{exit !($2 == "P")}'; then
            echo "$user n'a ni clé SSH ni mot de passe utilisable : SSH root non modifié."; return 1
        fi
    fi

    install -d -m 755 "$(dirname "$dropin")"
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$sshd_main" 2>/dev/null \
        || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$sshd_main"
    printf '# Généré par homelab-backup (SSH_ROOT_LOGIN)\nPermitRootLogin %s\n' "$mode" > "$dropin"
    if [[ -z "${SSHD_SKIP_TEST:-}" ]] && ! sshd -t 2>/dev/null; then
        rm -f "$dropin"; echo "Configuration sshd invalide : annulé."; return 1
    fi
    [[ -n "${SSHD_SKIP_TEST:-}" ]] || systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "SSH : PermitRootLogin $mode."
    [[ "$mode" == "no" ]] && echo "⚠ Teste maintenant dans une 2e fenêtre : ssh $user@<n54l> puis sudo -i, avant de fermer cette session."
    return 0
}

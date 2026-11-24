###############################################################################
#          SSH DEPUIS L'EXTÉRIEUR (PHASE DE DÉVELOPPEMENT, TEMPORAIRE)        #
###############################################################################

# Ouvre un SECOND port SSH (SSH_EXTERNAL_PORT, 2244 par défaut) prévu pour être redirigé depuis la box, quand on ne
# peut pas installer WireGuard sur le poste (ex. PC professionnel). Le port 22 et sa configuration ne changent pas.
# Sur ce port seulement :
#   - connexion par CLÉ uniquement (jamais de mot de passe, jamais root), uniquement pour ADMIN_USER ;
#   - 3 essais par connexion, fail2ban (3 échecs en 10 min = bannissement 1 jour) ;
#   - EXPIRATION AUTOMATIQUE après SSH_EXTERNAL_DAYS jours (fermeture du port, retrait de la règle) ; 0 = sans limite
#     (rappel hebdomadaire). Rappel quotidien (notification) pendant les 5 derniers jours ; prolongation :
#     ./install.sh --ssh_external_expand <jours> (ajoute des jours à l'échéance ; 0 = sans limite) ;
#   - notification (catégorie security : ntfy / Telegram) à l'activation, à l'expiration et à CHAQUE connexion SSH.
# Le redirection du port sur la box reste à faire à la main (le script n'a pas accès à la box) et à retirer ensuite.
# Pour un accès aux interfaces web (Proxmox :8006, Open WebUI :8090...) : tunnel SSH, voir le résumé affiché.
# Commandes : ./install.sh --ssh_external_on [jours] | --ssh_external_expand <jours> | --ssh_external_off | --ssh_external_status

SSH_EXT_DROPIN="/etc/ssh/sshd_config.d/91-homelab-external.conf"
SSH_EXT_JAIL="/etc/fail2ban/jail.d/homelab-ssh-external.local"
SSH_EXT_EXPIRES="/etc/homelab/ssh-external.expires"

ssh_external_install_helpers() {

    install -d -m 755 /etc/homelab

    cat > /usr/local/sbin/homelab-ssh-external-off <<'OFF_EOF'
#!/usr/bin/env bash
# Ferme l'accès SSH externe. "expire" (minuterie) : seulement si la date limite est passée ; "now" : tout de suite.
set -u
EXP=/etc/homelab/ssh-external.expires
REM=/etc/homelab/ssh-external.reminded
mode="${1:-expire}"
if [[ "$mode" == "expire" ]]; then
    [[ -f "$EXP" ]] || exit 0
    exp="$(cat "$EXP" 2>/dev/null || echo 0)"; now="$(date +%s)"
    if [[ "$exp" == "0" ]]; then
        # Sans limite : rappel une fois par semaine
        last="$(cat "$REM" 2>/dev/null || echo 0)"
        if (( now - last >= 604800 )); then
            echo "$now" > "$REM"
            command -v homelab-notify >/dev/null 2>&1 && homelab-notify -p default -t warning -c security "SSH externe toujours ouvert" "Accès SSH externe SANS limite de durée. Ferme-le quand tu n'en as plus besoin : ./install.sh --ssh_external_off" || true
        fi
        exit 0
    fi
    if (( now < exp )); then
        # Rappel quotidien pendant les 5 derniers jours
        if (( exp - now <= 432000 )); then
            last="$(cat "$REM" 2>/dev/null || echo 0)"
            if (( now - last >= 86400 )); then
                echo "$now" > "$REM"
                left=$(( (exp - now + 86399) / 86400 ))
                command -v homelab-notify >/dev/null 2>&1 && homelab-notify -p high -t hourglass -c security "SSH externe : expire bientôt" "Fermeture automatique dans ${left} jour(s) ($(date -d "@$exp" '+%F %H:%M')). Pour prolonger : ./install.sh --ssh_external_expand <jours>" || true
            fi
        fi
        exit 0
    fi
fi
rm -f /etc/ssh/sshd_config.d/91-homelab-external.conf /etc/fail2ban/jail.d/homelab-ssh-external.local "$EXP" "$REM"
sed -i '/homelab-ssh-login-notify/d' /etc/pam.d/sshd 2>/dev/null
systemctl disable --now homelab-ssh-external-expire.timer >/dev/null 2>&1
if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; fi
systemctl reload fail2ban >/dev/null 2>&1 || true
command -v homelab-notify >/dev/null 2>&1 && homelab-notify -p high -t lock -c security "SSH externe fermé" "Le port SSH externe est fermé ($mode). Retire aussi la redirection sur la box." || true
echo "SSH externe fermé."
OFF_EOF
    chmod 0755 /usr/local/sbin/homelab-ssh-external-off

    cat > /usr/local/sbin/homelab-ssh-login-notify <<'LOGIN_EOF'
#!/usr/bin/env bash
# Appelé par PAM (pam_exec) à chaque ouverture de session SSH.
[[ "${PAM_TYPE:-}" == "open_session" ]] || exit 0
command -v homelab-notify >/dev/null 2>&1 || exit 0
( homelab-notify -p high -t warning -c security "Connexion SSH" "${PAM_USER:-?} depuis ${PAM_RHOST:-?}" >/dev/null 2>&1 & )
exit 0
LOGIN_EOF
    chmod 0755 /usr/local/sbin/homelab-ssh-login-notify

    cat > /etc/systemd/system/homelab-ssh-external-expire.service <<'UNIT_EOF'
[Unit]
Description=Fermeture automatique du SSH externe à l'expiration

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-ssh-external-off expire
UNIT_EOF

    cat > /etc/systemd/system/homelab-ssh-external-expire.timer <<'TIMER_EOF'
[Unit]
Description=Contrôle de l'expiration du SSH externe

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
TIMER_EOF
    systemctl daemon-reload
}

# Installe / met à jour la clé publique de ADMIN_USER depuis ADMIN_SSH_KEY (fichier de réponses, chargé par --run).
# Sans option : ajoute la clé si elle manque (les autres clés restent). Avec --replace : ne garde QUE cette clé
# (ancien authorized_keys sauvegardé en .bak) : à utiliser pour remplacer une clé perdue ou compromise.
# Crée le compte (configure_admin_user) s'il n'existe pas encore. Usage : ./install.sh --ssh_key_sync [--replace]
ssh_key_sync() {

    local mode="${1:-}" user="${ADMIN_USER:-}" key="${ADMIN_SSH_KEY:-}" home kf

    [[ -n "$user" ]] || die "ADMIN_USER est vide dans le fichier de réponses."
    [[ -n "$key" ]]  || die "ADMIN_SSH_KEY est vide dans le fichier de réponses (colle-y le texte du fichier .pub, sur une ligne)."
    [[ -z "$mode" || "$mode" == "--replace" ]] || die "Usage : ./install.sh --ssh_key_sync [--replace]"

    # Une seule ligne, type de clé reconnu en tête : aucune option authorized_keys (command=...) ne peut être injectée.
    [[ "$key" != *$'\n'* && "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
        || die "ADMIN_SSH_KEY invalide : une seule ligne commençant par ssh-rsa, ssh-ed25519 ou ecdsa-sha2-... (le contenu du fichier .pub, jamais la clé privée)."

    if command -v ssh-keygen >/dev/null 2>&1; then
        printf '%s\n' "$key" | ssh-keygen -lf - >/dev/null 2>&1 \
            || die "ADMIN_SSH_KEY n'est pas une clé publique valide (ssh-keygen -lf a refusé la ligne : copie-la entière)."
    fi

    id "$user" >/dev/null 2>&1 || { info "Compte ${user} absent : création (configure_admin_user)."; configure_admin_user; }

    home="$(getent passwd "$user" | cut -d: -f6)"
    kf="${home}/.ssh/authorized_keys"
    install -d -m 700 -o "$user" -g "$user" "${home}/.ssh"
    touch "$kf"

    if [[ "$mode" == "--replace" ]]; then
        cp -a "$kf" "${kf}.bak.$(date +%s)"
        printf '%s\n' "$key" > "$kf"
        info "Clé SSH de ${user} REMPLACÉE (ancien fichier sauvegardé en ${kf}.bak.*)."
    elif grep -qxF "$key" "$kf"; then
        info "Clé SSH de ${user} : déjà à jour."
    else
        printf '%s\n' "$key" >> "$kf"
        info "Clé SSH ajoutée pour ${user} (les autres clés sont conservées ; --replace pour ne garder que celle-ci)."
    fi

    chown "${user}:${user}" "$kf"
    chmod 600 "$kf"
    info "Clés autorisées pour ${user} : $(grep -c . "$kf")."
}

# Usage : ssh_external_enable [jours] [reset]
#   jours : 0 = sans limite. Sans "reset", une échéance déjà plus lointaine (prolongée avec ssh_external_expand) est conservée.
ssh_external_enable() {

    local days="${1:-${SSH_EXTERNAL_DAYS:-7}}" reset="${2:-}" port="${SSH_EXTERNAL_PORT:-2244}" user="${ADMIN_USER:-}"
    local home keyfile expires old=""

    [[ "$days" =~ ^[0-9]+$ && "$days" -le 365 ]] || die "SSH_EXTERNAL_DAYS doit être compris entre 0 (sans limite) et 365 (reçu : ${days})."
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || die "SSH_EXTERNAL_PORT doit être compris entre 1024 et 65535 (reçu : ${port})."
    [[ "$port" != "22" ]] || die "SSH_EXTERNAL_PORT ne peut pas être 22."
    [[ -n "$user" ]] || die "SSH externe : ADMIN_USER est vide. Il faut un compte non-root avec une clé SSH."
    id "$user" >/dev/null 2>&1 || die "SSH externe : le compte ${user} n'existe pas (configure_admin_user)."

    # Clé du fichier de réponses installée automatiquement si elle est renseignée
    [[ -z "${ADMIN_SSH_KEY:-}" ]] || ssh_key_sync

    home="$(getent passwd "$user" | cut -d: -f6)"
    keyfile="${home}/.ssh/authorized_keys"
    [[ -s "$keyfile" ]] \
        || die "SSH externe : aucune clé dans ${keyfile}. Renseigne ADMIN_SSH_KEY (le texte du fichier .pub) : le mot de passe n'est JAMAIS accepté depuis l'extérieur."

    command -v fail2ban-client >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null

    ssh_external_install_helpers

    install -d -m 755 /etc/ssh/sshd_config.d
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${SSHD_MAIN:-/etc/ssh/sshd_config}" 2>/dev/null; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${SSHD_MAIN:-/etc/ssh/sshd_config}"
    fi

    cat > "$SSH_EXT_DROPIN" <<EOF
# Généré par l'installateur homelab (SSH_EXTERNAL) : accès temporaire, expire automatiquement.
Port 22
Port ${port}
Match LocalPort ${port}
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AllowUsers ${user}
    MaxAuthTries 3
    AllowAgentForwarding no
    X11Forwarding no
Match all
EOF

    local sshd_err
    if ! sshd_err="$(sshd -t 2>&1)"; then
        rm -f "$SSH_EXT_DROPIN"
        die "Configuration sshd invalide avec l'accès externe : annulé. Erreur de sshd -t : ${sshd_err}"
    fi

    cat > "$SSH_EXT_JAIL" <<EOF
[sshd-external]
enabled  = true
filter   = sshd
port     = ${port}
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 1d
EOF

    # Notification de chaque connexion SSH (PAM)
    if ! grep -q homelab-ssh-login-notify /etc/pam.d/sshd 2>/dev/null; then
        echo 'session optional pam_exec.so quiet /usr/local/sbin/homelab-ssh-login-notify' >> /etc/pam.d/sshd
    fi

    [[ -f "$SSH_EXT_EXPIRES" ]] && old="$(cat "$SSH_EXT_EXPIRES" 2>/dev/null)"
    if (( days == 0 )); then
        expires=0
    else
        expires=$(( $(date +%s) + days * 86400 ))
        # Relance du script : on ne raccourcit pas une échéance déjà plus lointaine ou illimitée
        if [[ -z "$reset" && -n "$old" ]] && { [[ "$old" == "0" ]] || (( old > expires )); }; then
            expires="$old"
        fi
    fi
    printf '%s\n' "$expires" > "$SSH_EXT_EXPIRES"
    rm -f /etc/homelab/ssh-external.reminded

    systemctl enable --now homelab-ssh-external-expire.timer >/dev/null 2>&1 || warn "SSH externe : minuterie d'expiration non activée."
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "SSH externe : rechargement de sshd échoué."
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true

    command -v homelab-notify >/dev/null 2>&1 \
        && homelab-notify -p high -t unlock -c security "SSH externe ouvert" "Port ${port} ouvert ($(ssh_external_deadline "$expires")). Redirection de la box à faire à la main." || true

    ssh_external_status
    return 0
}

ssh_external_off() {
    [[ -x /usr/local/sbin/homelab-ssh-external-off ]] || { info "SSH externe : rien à fermer."; return 0; }
    /usr/local/sbin/homelab-ssh-external-off now
}

ssh_external_on() { ssh_external_enable "${1:-${SSH_EXTERNAL_DAYS:-7}}" reset; }

# Texte de l'échéance (0 = sans limite)
ssh_external_deadline() {
    if [[ "$1" == "0" ]]; then printf 'sans limite de durée'; else printf "jusqu'au %s" "$(date -d "@$1" '+%F %H:%M')"; fi
}

# Prolonge l'accès de <jours> jours à partir de l'échéance actuelle (ou de maintenant si elle est passée) ; 0 = sans limite.
# Usage : ./install.sh --ssh_external_expand 7
ssh_external_expand() {

    local add="${1:-}" cur now new

    [[ "$add" =~ ^[0-9]+$ && "$add" -le 365 ]] || die "Usage : ./install.sh --ssh_external_expand <jours>  (1 à 365 ; 0 = sans limite)"
    [[ -f "$SSH_EXT_EXPIRES" && -f "$SSH_EXT_DROPIN" ]] || die "SSH externe fermé : rien à prolonger. Ouvre-le avec ./install.sh --ssh_external_on [jours]"

    cur="$(cat "$SSH_EXT_EXPIRES")"
    now="$(date +%s)"

    if (( add == 0 )); then
        new=0
    elif [[ "$cur" == "0" ]]; then
        info "SSH externe : déjà sans limite de durée (ssh_external_on <jours> pour remettre une échéance)."
        return 0
    else
        (( cur > now )) || cur="$now"
        new=$(( cur + add * 86400 ))
    fi

    printf '%s\n' "$new" > "$SSH_EXT_EXPIRES"
    rm -f /etc/homelab/ssh-external.reminded
    info "SSH externe : échéance mise à jour (${add} jour(s) ajouté(s))."
    command -v homelab-notify >/dev/null 2>&1 \
        && homelab-notify -p default -t hourglass -c security "SSH externe prolongé" "$(ssh_external_deadline "$new")" || true
    ssh_external_status
}

ssh_external_status() {

    local port="${SSH_EXTERNAL_PORT:-2244}" user="${ADMIN_USER:-<ADMIN_USER>}" fp

    if [[ ! -f "$SSH_EXT_EXPIRES" || ! -f "$SSH_EXT_DROPIN" ]]; then
        info "SSH externe : FERMÉ."
        return 0
    fi

    port="$(awk '$1=="Port" && $2!=22 {print $2; exit}' "$SSH_EXT_DROPIN")"
    fp="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"

    echo
    echo "SSH EXTERNE OUVERT (développement, temporaire)"
    echo "  Port        : ${port}  (clé SSH uniquement, utilisateur ${user}, pas de root)"
    if [[ "$(cat "$SSH_EXT_EXPIRES")" == "0" ]]; then
        echo "  Durée       : SANS LIMITE (rappel hebdomadaire) ; fermer : ./install.sh --ssh_external_off"
    else
        echo "  Expire le   : $(date -d "@$(cat "$SSH_EXT_EXPIRES")" '+%F %H:%M')  (fermeture automatique ; rappel quotidien les 5 derniers jours ; prolonger : ./install.sh --ssh_external_expand <jours> ; fermer avant : --ssh_external_off)"
    fi
    echo "  À FAIRE     : sur la box, rediriger TCP ${port} (extérieur) vers ${LAN_IP:-<IP LAN hôte>}:${port}. À retirer après usage."
    echo "  Connexion   : ssh -p ${port} ${user}@${DOMAIN:-<ton domaine>}"
    echo "  1re connexion : vérifie l'empreinte du serveur : ${fp:-?}"
    echo "  Tunnels web : ssh -p ${port} -L 8006:127.0.0.1:8006 ${user}@${DOMAIN:-<ton domaine>}   puis https://localhost:8006 (Proxmox)"
    [[ "${ENABLE_AI:-false}" == "true" ]] && echo "                ssh -p ${port} -L 8090:${AI_IP%%/*}:${AI_WEB_PORT} ${user}@${DOMAIN:-<ton domaine>}   puis http://localhost:8090 (IA)"
    echo "  Côté poste  : Windows 10/11 : « ssh » est déjà dans PowerShell (aucune installation) ; génération de la clé : ssh-keygen -t ed25519"
    echo
}

# Diagnostic : où ça bloque (serveur, pare-feu, fail2ban ou box) ?
# Usage : ./install.sh --ssh_external_diag
ssh_external_diag() {

    local port="${SSH_EXTERNAL_PORT:-2244}" user="${ADMIN_USER:-}" ip="${LAN_IP:-}" b home n

    [[ -f "$SSH_EXT_DROPIN" ]] && port="$(awk '$1=="Port" && $2!=22 {print $2; exit}' "$SSH_EXT_DROPIN")"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    echo
    echo "DIAGNOSTIC SSH EXTERNE (port ${port})"
    echo "------------------------------------------------------------"

    # 1. Configuration
    if [[ -f "$SSH_EXT_DROPIN" && -f "$SSH_EXT_EXPIRES" ]]; then
        echo "[OK]  1. Accès externe activé (drop-in + échéance présents)."
    else
        echo "[KO]  1. Accès externe NON activé -> ./install.sh --ssh_external_on"
    fi

    # 2. sshd écoute
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        echo "[OK]  2. sshd écoute sur le port ${port}."
    else
        echo "[KO]  2. Rien n'écoute sur ${port} -> systemctl restart ssh ; puis revérifier (sshd -T | grep -i '^port')."
    fi

    # 3. Bannière locale (127.0.0.1 puis IP LAN) : prouve que sshd répond
    for b in 127.0.0.1 "$ip"; do
        [[ -n "$b" ]] || continue
        n="$(timeout 5 bash -c "exec 3<>/dev/tcp/${b}/${port}; head -c 40 <&3" 2>/dev/null | head -1 | tr -d '\r')"
        if [[ "$n" == SSH-* ]]; then
            echo "[OK]  3. Bannière reçue sur ${b}:${port} (${n})."
        else
            echo "[KO]  3. Aucune bannière SSH sur ${b}:${port} (connexion refusée ou coupée)."
        fi
    done

    # 4. Pare-feu de l'hôte
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE "dport[^;]*${port}"; then
        echo "[??]  4. Règle(s) nftables mentionnant ${port} :"
        nft list ruleset 2>/dev/null | grep -nE "dport[^;]*${port}" | sed 's/^/        /'
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -qE "dport ${port}"; then
        echo "[??]  4. Règle(s) iptables mentionnant ${port} :"
        iptables -S 2>/dev/null | grep -E "dport ${port}" | sed 's/^/        /'
    fi
    if command -v pve-firewall >/dev/null 2>&1 && pve-firewall status 2>/dev/null | grep -qi "enabled"; then
        echo "[??]  4. Pare-feu Proxmox ACTIF : autoriser TCP ${port} entrant (Datacenter/Hôte > Pare-feu) sinon il coupe la connexion."
    else
        echo "[OK]  4. Pas de pare-feu Proxmox actif qui bloquerait ${port}."
    fi

    # 5. fail2ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        if fail2ban-client status sshd-external >/dev/null 2>&1; then
            echo "      5. fail2ban sshd-external :"
            fail2ban-client status sshd-external 2>/dev/null | grep -E "Currently banned|Banned IP" | sed 's/^/        /'
            echo "        (débannir : fail2ban-client set sshd-external unbanip <IP>)"
        else
            echo "[??]  5. Jail sshd-external absente (fail2ban)."
        fi
    fi

    # 6. Clé de l'utilisateur
    if [[ -n "$user" ]] && id "$user" >/dev/null 2>&1; then
        home="$(getent passwd "$user" | cut -d: -f6)"
        n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null)" || true
        n="${n:-0}"
        if [[ "$n" -gt 0 ]]; then
            echo "[OK]  6. ${n} clé(s) publique(s) pour ${user}."
        else
            echo "[KO]  6. Aucune clé pour ${user} -> ./install.sh --ssh_key_sync"
        fi
    fi

    # 7. Derniers messages sshd
    echo "      7. Derniers messages sshd (cherche ton IP / les refus) :"
    journalctl -u ssh -u sshd -n 15 --no-pager 2>/dev/null | sed 's/^/        /'

    cat <<EOF

COMMENT LIRE LE RÉSULTAT
  - 2 et 3 OK en local mais échec depuis Internet (téléphone) : le serveur est bon,
    le problème est la BOX. Vérifie la redirection : TCP ${port} externe -> ${ip:-<IP LAN>}:${port}
    (même numéro des deux côtés, protocole TCP, bonne IP, pas de pare-feu de box
    qui filtre, une seule règle par port). Si ta box est derrière un autre routeur
    (double NAT / modem opérateur + routeur perso), redirige sur les deux.
  - 2 ou 3 KO : sshd ne répond pas -> systemctl status ssh ; sshd -t ; relance
    ./install.sh --ssh_external_on
  - 4 signale une règle ou le pare-feu Proxmox : autorise TCP ${port}.
  - Test depuis Internet : https://www.yougetsignal.com/tools/open-ports/ (port ${port},
    à faire depuis chez toi) doit répondre « open ».
EOF
    echo
}

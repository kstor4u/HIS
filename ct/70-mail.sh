###############################################################################
#                  SERVEUR MAIL AUTONOME (CT LXC + docker-mailserver)         #
###############################################################################

# Architecture
# ------------
#  - Un CT LXC (MAIL_ID) sur le bridge privé fait tourner Docker avec
#    docker-mailserver (Postfix + Dovecot + Rspamd pour spam/DKIM/DMARC).
#  - Les mails (Maildir) sont stockés sur le disque DATA, HORS de SHARED :
#    ${APPS_DIR}/mail, monté dans le CT sur /mnt/mail-data (point de montage LXC).
#    Les états/journaux/config du serveur restent dans le CT (/opt/mail).
#  - Certificat TLS : celui de SWAG (Let's Encrypt, sous-domaine mail.<domaine>),
#    copié dans le CT puis rafraîchi chaque nuit par l'hôte (cron
#    /etc/cron.d/homelab-mail-certs). Sans certificat Let's Encrypt, c'est le
#    certificat auto-signé de SWAG qui est utilisé en attendant.
#  - Ports redirigés depuis l'IP LAN de l'hôte : 25 (SMTP), 465 et 587
#    (soumission), 993 (IMAP). La box doit rediriger les mêmes ports vers l'hôte.
#  - Envoi : direct (MAIL_RELAY_HOST vide) ou via un relais SMTP externe
#    (MAIL_RELAY_HOST / MAIL_RELAY_USER / MAIL_RELAY_PASSWORD), utile si le FAI
#    bloque le port 25 sortant ou si la réputation de l'IP est mauvaise.
#  - Applications (ex. site Node) : SMTP sur MAIL_IP:587 (STARTTLS), identifiants
#    d'un compte ; le certificat est au nom de mail.<domaine> (donc, côté client :
#    "servername: mail.<domaine>" ou vérification du nom désactivée sur le réseau privé).

mail_fqdn() { printf '%s.%s' "${MAIL_SUBDOMAIN}" "${DOMAIN}"; }

# Résultat de create_mail_ct : lignes "adresse mot de passe" (affichées dans le résumé).
MAIL_ACCOUNTS_INFO=""

# Teste ce qui conditionne la délivrabilité depuis cette connexion Internet.
# Ne bloque jamais l'installation (simple information / avertissement).
mail_check_network() {

    local pub_ip ptr fqdn
    fqdn="$(mail_fqdn)"

    pub_ip="$(curl -s4 --max-time 10 https://api.ipify.org || true)"
    info "Mail : IP publique vue depuis l'hôte : ${pub_ip:-inconnue}"

    if timeout 8 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
        info "Mail : port 25 SORTANT ouvert (envoi direct possible)."
    else
        warn "Mail : port 25 SORTANT bloqué (ou injoignable) : le FAI le bloque probablement. Renseigne MAIL_RELAY_HOST (relais SMTP) pour envoyer ; la réception reste possible."
    fi

    if [[ -n "$pub_ip" ]]; then
        ptr="$(getent hosts "$pub_ip" 2>/dev/null | awk '{print $2; exit}' || true)"

        if [[ "${ptr%.}" == "$fqdn" ]]; then
            info "Mail : DNS inverse (PTR) de ${pub_ip} = ${fqdn} : OK."
        else
            warn "Mail : DNS inverse (PTR) de ${pub_ip} = '${ptr:-aucun}' au lieu de ${fqdn}. Beaucoup de serveurs rejettent ou classent en spam sans PTR cohérent : à demander/configurer chez le FAI (SFR)."
        fi
    fi
}

# Copie le certificat de SWAG dans le CT MAIL (Let's Encrypt si présent, sinon
# l'auto-signé de SWAG) et redémarre le serveur mail si le certificat a changé.
# Utilisée aussi par la tâche cron nocturne (script autonome généré par
# install_mail_cert_cron).
mail_sync_certs() {

    local base=/opt/swag/config/etc/letsencrypt/live/${DOMAIN}
    local cert key tmpc tmpk new old

    if pct exec "$SWAG_ID" -- test -f "${base}/fullchain.pem" 2>/dev/null; then
        cert="${base}/fullchain.pem"; key="${base}/privkey.pem"
    else
        warn "Mail : pas encore de certificat Let's Encrypt dans SWAG, certificat auto-signé utilisé en attendant."
        cert=/opt/swag/config/keys/cert.crt; key=/opt/swag/config/keys/cert.key
    fi

    tmpc="$(mktemp)"; tmpk="$(mktemp)"
    chmod 600 "$tmpc" "$tmpk"

    if ! pct exec "$SWAG_ID" -- cat "$cert" > "$tmpc" 2>/dev/null \
        || ! pct exec "$SWAG_ID" -- cat "$key" > "$tmpk" 2>/dev/null \
        || [[ ! -s "$tmpc" || ! -s "$tmpk" ]]; then
        rm -f "$tmpc" "$tmpk"
        warn "Mail : certificat SWAG illisible (SWAG démarré ?), rien copié."
        return 1
    fi

    new="$(sha256sum "$tmpc" | cut -d' ' -f1)"
    old="$(pct exec "$MAIL_ID" -- sha256sum /opt/mail/certs/fullchain.pem 2>/dev/null | cut -d' ' -f1 || true)"

    if [[ "$new" == "$old" ]]; then
        rm -f "$tmpc" "$tmpk"
        info "Mail : certificat déjà à jour."
        return 0
    fi

    pct push "$MAIL_ID" "$tmpc" /opt/mail/certs/fullchain.pem --perms 0644
    pct push "$MAIL_ID" "$tmpk" /opt/mail/certs/privkey.pem --perms 0600
    rm -f "$tmpc" "$tmpk"

    pct exec "$MAIL_ID" -- bash -c 'docker ps -q -f name=^mailserver$ | grep -q . && docker restart mailserver >/dev/null' || true

    info "Mail : certificat mis à jour dans le CT ${MAIL_ID}."
}

# Tâche nocturne sur l'hôte : script autonome (IDs et domaine figés) + cron.
install_mail_cert_cron() {

    cat > /usr/local/sbin/homelab-mail-certs.sh <<SCRIPT_EOF
#!/usr/bin/env bash
# Généré par l'installateur homelab : recopie le certificat de SWAG vers le CT MAIL.
set -Eeuo pipefail
SWAG_ID="${SWAG_ID}"
MAIL_ID="${MAIL_ID}"
DOMAIN="${DOMAIN}"
info() { logger -t homelab-mail-certs -- "\$*"; }
warn() { logger -t homelab-mail-certs -p user.warning -- "\$*"; }
$(declare -f mail_sync_certs)
mail_sync_certs
SCRIPT_EOF
    chmod 700 /usr/local/sbin/homelab-mail-certs.sh

    printf '30 4 * * * root /usr/local/sbin/homelab-mail-certs.sh\n' > /etc/cron.d/homelab-mail-certs
    chmod 644 /etc/cron.d/homelab-mail-certs
}

# Crée un compte mail : mail_add_account <nom>[:mot_de_passe]  (adresse nom@domaine).
# Sans mot de passe, il est généré et affiché.
mail_add_account() {

    local spec="${1:-}" name pass addr

    [[ -n "$spec" ]] || die "Usage : mail_add_account <nom>[:mot_de_passe]"

    name="${spec%%:*}"
    pass=""
    [[ "$spec" == *:* ]] && pass="${spec#*:}"

    [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "Nom de compte invalide : '${name}' (minuscules, chiffres, . _ -)."

    [[ -n "$pass" ]] || pass="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')"
    addr="${name}@${DOMAIN}"

    if pct exec "$MAIL_ID" -- docker exec mailserver setup email list 2>/dev/null | grep -q "^\* ${addr}\b"; then
        info "Mail : ${addr} existe déjà (mot de passe inchangé)."
        return 0
    fi

    pct exec "$MAIL_ID" -- docker exec mailserver setup email add "$addr" "$pass" >/dev/null \
        || die "Création de ${addr} impossible (serveur mail démarré ? ./install.sh --run mail_logs)."

    MAIL_ACCOUNTS_INFO+="${addr}  ${pass}"$'\n'
    info "Mail : compte ${addr} créé. Mot de passe : ${pass}"
}

mail_list_accounts() { pct exec "$MAIL_ID" -- docker exec mailserver setup email list; }
mail_logs()          { pct exec "$MAIL_ID" -- bash -c "cd /opt/mail && docker compose logs --tail 80 mailserver"; }
mail_restart()       { pct exec "$MAIL_ID" -- bash -c "cd /opt/mail && docker compose restart mailserver"; }
mail_queue()         { pct exec "$MAIL_ID" -- docker exec mailserver postqueue -p; }

# Génère la clé DKIM du domaine (si absente) et affiche l'enregistrement DNS à publier.
mail_dkim() {

    timeout 120 pct exec "$MAIL_ID" -- docker exec mailserver setup config dkim domain "$DOMAIN" >/dev/null 2>&1 || true

    local out
    out="$(timeout 60 pct exec "$MAIL_ID" -- bash -c 'find /opt/mail/dms-config -path "*dkim*" -name "*.txt" -exec cat {} + 2>/dev/null' </dev/null || true)"

    if [[ -z "$out" ]]; then
        warn "Mail : enregistrement DKIM introuvable (voir : ./install.sh --run mail_logs)."
        return 1
    fi

    printf '%s\n' "$out"
}

# Affiche les enregistrements DNS à créer dans la zone OVH (et le PTR à demander au FAI).
mail_dns() {

    local fqdn pub_ip spf
    fqdn="$(mail_fqdn)"
    pub_ip="$(curl -s4 --max-time 10 https://api.ipify.org || true)"
    spf='"v=spf1 mx ~all"'

    [[ -z "$MAIL_RELAY_HOST" ]] || spf='"v=spf1 mx include:<SPF-DU-RELAIS> ~all"   (remplace <SPF-DU-RELAIS> : voir la doc du relais, ex. spf.brevo.com)'

    cat <<DNS_EOF

Enregistrements DNS à créer dans la zone ${DOMAIN} :

  A      ${SUBDOMAIN_ALL[MAIL_SUBDOMAIN]// /, }   ${pub_ip:-<IP publique>}   (un enregistrement par nom ; MX sur ${MAIL_SUBDOMAIN})
  MX     @                         10  ${fqdn}.
  TXT    @                         ${spf}
  TXT    _dmarc                    "v=DMARC1; p=none; rua=mailto:postmaster@${DOMAIN}"
  TXT    mail._domainkey           (clé DKIM ci-dessous : ./install.sh --run mail_dkim)

  PTR (DNS inverse) de ${pub_ip:-<IP publique>} -> ${fqdn} : à demander/configurer chez le FAI.

Conseil DMARC : commence en p=none, vérifie quelques jours, puis passe à p=quarantine.
Ports à rediriger sur la box vers ${LAN_IP} : TCP 25, 465, 587, 993.
DNS_EOF
}

# Contrôle complet : réseau, certificat, DNS à publier, clé DKIM.
mail_check() {

    mail_check_network
    mail_dns
    echo
    info "Clé DKIM (enregistrement TXT mail._domainkey) :"
    mail_dkim || true
}

# Libère le port 25 dans le CT mail avant de lancer docker-mailserver : un MTA système
# (exim4/postfix/sendmail) ou un conteneur resté d'un essai précédent l'occupe
# ("failed to bind host port 0.0.0.0:25/tcp: address already in use").
# Usage : ./install.sh --run mail_free_port25
mail_free_port25() {
    pct exec "$MAIL_ID" -- bash -c '
        for u in exim4 postfix sendmail; do
            if systemctl cat "${u}.service" >/dev/null 2>&1; then
                echo "Mail : arrêt du service système ${u} (il occupe le port 25)."
                systemctl disable --now "${u}.service" >/dev/null 2>&1 || true
                systemctl mask "${u}.service" >/dev/null 2>&1 || true
            fi
        done
        if [[ -f /opt/mail/docker-compose.yml ]]; then
            (cd /opt/mail && docker compose down --remove-orphans >/dev/null 2>&1) || true
        fi
        sleep 2
        if ss -H -tlnp "sport = :25" | grep -q .; then
            echo "Le port 25 est encore occupé par :"
            ss -H -tlnp "sport = :25"
            exit 1
        fi
        exit 0'
}

create_mail_ct() {

    if pct status "$MAIL_ID" >/dev/null 2>&1; then

        warn "CT ${MAIL_ID} existe déjà. Création MAIL ignorée."

        return 0
    fi

    [[ -n "$DOMAIN" ]] || die "DOMAIN est vide : impossible de créer le serveur mail."

    mail_check_network

    mkdir -p "${APPS_DIR}/mail"
    chown 100000:100000 "${APPS_DIR}/mail"

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE" fqdn
    fqdn="$(mail_fqdn)"

    info "Création du CT MAIL ${MAIL_ID}..."

    pct create "$MAIL_ID" \
        "$TEMPLATE" \
        --hostname "$MAIL_HOSTNAME" \
        --cores "$MAIL_CORES" \
        --memory "$MAIL_MEMORY" \
        --swap 512 \
        --rootfs "${GUEST_STORAGE}:${MAIL_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${MAIL_GATEWAY},ip=${MAIL_IP}" \
        --mp0 "${APPS_DIR}/mail,mp=/mnt/mail-data,backup=0" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$MAIL_ID"

    pct_wait_for_network "$MAIL_ID"

    local WORK
    WORK="$(mktemp -d)"

    {
        printf 'MAIL_FQDN=%s\n' "$fqdn"
        printf 'POSTMASTER_ADDRESS=postmaster@%s\n' "$DOMAIN"
        printf 'DEFAULT_RELAY_HOST=%s\n' "$MAIL_RELAY_HOST"
        printf 'RELAY_USER=%s\n' "$MAIL_RELAY_USER"
        printf 'RELAY_PASSWORD=%s\n' "$MAIL_RELAY_PASSWORD"
    } > "${WORK}/env"

    cat > "${WORK}/docker-compose.yml" <<'COMPOSE_EOF'
services:
  mailserver:
    image: ghcr.io/docker-mailserver/docker-mailserver:latest
    container_name: mailserver
    hostname: ${MAIL_FQDN}
    restart: unless-stopped
    stop_grace_period: 1m
    ports:
      - "25:25"
      - "465:465"
      - "587:587"
      - "993:993"
    volumes:
      - /mnt/mail-data:/var/mail
      - /opt/mail/dms-state:/var/mail-state
      - /opt/mail/dms-logs:/var/log/mail
      - /opt/mail/dms-config:/tmp/docker-mailserver
      - /opt/mail/certs:/certs:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - SSL_TYPE=manual
      - SSL_CERT_PATH=/certs/fullchain.pem
      - SSL_KEY_PATH=/certs/privkey.pem
      - ENABLE_RSPAMD=1
      - ENABLE_OPENDKIM=0
      - ENABLE_OPENDMARC=0
      - ENABLE_POLICYD_SPF=0
      - ENABLE_AMAVIS=0
      - ENABLE_SPAMASSASSIN=0
      - ENABLE_CLAMAV=0
      - ENABLE_FAIL2BAN=0
      - ENABLE_POP3=0
      - POSTMASTER_ADDRESS=${POSTMASTER_ADDRESS}
      - DEFAULT_RELAY_HOST=${DEFAULT_RELAY_HOST:-}
      - RELAY_USER=${RELAY_USER:-}
      - RELAY_PASSWORD=${RELAY_PASSWORD:-}
      - TZ=Europe/Paris
COMPOSE_EOF

    cat > "${WORK}/install-mail.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<'DOCKER_EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

mkdir -p /opt/mail/certs /opt/mail/dms-state /opt/mail/dms-logs /opt/mail/dms-config
mv /root/mail-env /opt/mail/.env
mv /root/mail-compose.yml /opt/mail/docker-compose.yml
chmod 600 /opt/mail/.env

mountpoint -q /mnt/mail-data || { echo "ERREUR: /mnt/mail-data n'est pas monté."; exit 1; }

cd /opt/mail
docker compose pull
EOF_INSTALL

    pct push "$MAIL_ID" "${WORK}/env"                /root/mail-env --perms 0600
    pct push "$MAIL_ID" "${WORK}/docker-compose.yml" /root/mail-compose.yml

    pct_push_script "$MAIL_ID" "${WORK}/install-mail.sh" /root/install-mail.sh

    rm -rf "$WORK"

    pct exec "$MAIL_ID" -- bash /root/install-mail.sh

    # Le certificat doit être en place AVANT le démarrage du serveur.
    mail_sync_certs || warn "Mail : certificat non copié (SWAG pas prêt ?). Il sera copié par la tâche nocturne ; en attendant : ./install.sh --run mail_sync_certs puis mail_restart."
    install_mail_cert_cron

    mail_free_port25 || die "Mail : le port 25 est occupé dans le CT ${MAIL_ID} (voir ci-dessus). Libère-le puis : ./install.sh --run create_mail_ct"

    pct exec "$MAIL_ID" -- bash -c "cd /opt/mail && docker compose up -d"

    local attempt
    info "Mail : attente du démarrage de docker-mailserver (jusqu'à 3 min)..."

    for attempt in $(seq 1 36); do

        if pct exec "$MAIL_ID" -- docker exec mailserver setup email list >/dev/null 2>&1; then
            break
        fi

        sleep 5
    done

    local spec
    for spec in $MAIL_ACCOUNTS; do
        mail_add_account "$spec" || warn "Mail : compte '${spec%%:*}' non créé."
    done

    mail_dkim >/dev/null 2>&1 || warn "Mail : clé DKIM non générée (./install.sh --run mail_dkim plus tard)."

    info "Serveur mail installé dans le CT ${MAIL_ID} (${fqdn})."
    info "Étape suivante : publier les enregistrements DNS -> ./install.sh --run mail_check"
}

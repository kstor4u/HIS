###############################################################################
#             DNS FILTRANT / ANTI-PUBLICITÉS (CT LXC + AdGuard Home)          #
###############################################################################

# Architecture
# ------------
#  - Un CT LXC (DNS_ID) sur le bridge privé fait tourner AdGuard Home (binaire
#    officiel, service systemd). Choisi plutôt que Pi-hole : libre (GPLv3), un
#    seul binaire, DNS chiffré (DoH/DoT) vers l'amont intégré, réécritures DNS
#    internes, règles par client, et tout se configure par API (donc ici,
#    automatiquement et de façon répétable).
#  - Le port 53 (UDP+TCP) de l'IP LAN de l'hôte est redirigé vers le CT : il
#    suffit de mettre l'IP LAN de l'hôte comme serveur DNS dans la box (DHCP).
#    Ce port n'est JAMAIS à rediriger depuis la box vers Internet (résolveur
#    ouvert). En plus, AdGuard Home n'accepte que les clients de la liste
#    "allowed_clients" (LAN, réseau privé, réseau VPN).
#  - DNS interne ("split DNS") : les noms du homelab (cloud.<domaine>, etc.)
#    sont réécrits vers l'IP LAN de l'hôte pour les clients du LAN/VPN : plus
#    de détour par la box ni de problème de "hairpin NAT".
#  - Interface d'administration : http://<IP LAN hôte>:DNS_UI_PORT (LAN) ou
#    http://<IP du CT> (réseau privé / VPN). Pas de sous-domaine public : une
#    interface d'admin n'a pas à être sur Internet.
#  - Le mot de passe admin est écrit dans le CT (/root/adguard-admin.pass, 0600).
#  - Sauvegarde : le CT est inclus dans la tâche vzdump ; la configuration est
#    dans /opt/AdGuardHome/AdGuardHome.yaml.

# Mot de passe admin : variable, sinon fichier du CT.
dns_admin_password() {

    if [[ -n "${DNS_ADMIN_PASSWORD:-}" ]]; then
        printf '%s' "$DNS_ADMIN_PASSWORD"
        return 0
    fi

    pct exec "$DNS_ID" -- cat /root/adguard-admin.pass 2>/dev/null || true
}

# Échappe une chaîne pour l'insérer dans du JSON.
dns_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# dns_json_array a b c -> ["a","b","c"]
dns_json_array() {
    local out="" item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        out+="${out:+,}$(dns_json_str "$item")"
    done
    printf '[%s]' "$out"
}

# Appel de l'API AdGuard Home depuis l'hôte (réseau privé).
# Usage : dns_api METHOD /control/... ['{"json":1}']
# Identifiants passés par un fichier temporaire 0600 (jamais sur la ligne de commande).
dns_api() {

    local method="$1" path="$2" body="${3:-}" cfg pw rc=0
    local -a args=()

    pw="$(dns_admin_password)"
    [[ -n "$pw" ]] || die "Mot de passe AdGuard Home introuvable (DNS_ADMIN_PASSWORD ou /root/adguard-admin.pass dans le CT ${DNS_ID})."

    cfg="$(mktemp)"
    chmod 600 "$cfg"
    printf 'user = %s\n' "$(dns_json_str "${DNS_ADMIN_USER}:${pw}")" > "$cfg"

    args=(-sS --connect-timeout 5 --max-time 30 -K "$cfg" -X "$method" -w '\n%{http_code}')
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' -d "$body")
    fi

    curl "${args[@]}" "http://${DNS_IP%%/*}${path}" || rc=$?
    rm -f "$cfg"

    return "$rc"
}

# Comme dns_api, mais échoue (avertissement) si le code HTTP n'est pas 2xx.
dns_api_ok() {

    local what="$1" out code
    shift

    out="$(dns_api "$@" 2>&1)" || { warn "DNS : ${what} : appel API impossible (${out})."; return 1; }
    code="${out##*$'\n'}"

    if [[ "$code" =~ ^2 ]]; then
        return 0
    fi

    warn "DNS : ${what} : HTTP ${code} (${out%$'\n'*})."
    return 1
}

# Noms du homelab réécrits vers l'IP LAN de l'hôte (même liste que le certificat SWAG).
dns_local_names() {

    local -a names=("${DOMAIN}")
    local n

    # Mêmes noms que le certificat SWAG (core/35-subdomains.sh), tous sous-domaines choisis inclus
    while IFS= read -r n; do
        [[ -n "$n" ]] && names+=("${n}.${DOMAIN}")
    done < <(subdomain_hosts cert | awk '!s[$0]++')

    for n in ${DNS_REWRITE_EXTRA:-}; do
        names+=("$n")
    done

    printf '%s\n' "${names[@]}"
}

# Clients autorisés à interroger le DNS (le reste est refusé).
dns_allowed_clients() {

    local c
    for c in "127.0.0.1" "$LAN_NET" "$PRIVATE_NET" "$WG_NET" ${DNS_EXTRA_CLIENTS:-}; do
        printf '%s\n' "$c"
    done
}

# Valeur à donner aux clients VPN comme serveur DNS (IP du CT si le DNS est installé
# et DNS_FOR_WG=true, sinon WG_DNS).
wg_dns_value() {

    if [[ "${ENABLE_DNS:-false}" == "true" && "${DNS_FOR_WG:-true}" == "true" ]]; then
        printf '%s' "${DNS_IP%%/*}"
    else
        printf '%s' "$WG_DNS"
    fi
}

# (Ré)applique toute la configuration par API : DNS amont, accès, réécritures,
# listes de blocage supplémentaires. Idempotent. Usage : ./install.sh --run dns_configure
dns_configure() {

    local name url entry existing
    local -a ups=() boots=() allowed=()

    # shellcheck disable=SC2206
    ups=(${DNS_UPSTREAMS})
    # shellcheck disable=SC2206
    boots=(${DNS_BOOTSTRAP})

    info "DNS : configuration d'AdGuard Home par API..."

    # AdGuard injoignable (CT arrêté, IP erronée) : on s'arrête tout de suite au lieu d'attendre chaque appel
    if ! curl -s -o /dev/null --connect-timeout 5 --max-time 10 "http://${DNS_IP%%/*}/"; then
        warn "DNS : AdGuard Home ne répond pas sur ${DNS_IP%%/*} (CT ${DNS_ID} arrêté ? pct start ${DNS_ID}). Configuration ignorée."
        return 1
    fi

    dns_api_ok "DNS amont" POST /control/dns_config \
        "{\"upstream_dns\":$(dns_json_array "${ups[@]}"),\"bootstrap_dns\":$(dns_json_array "${boots[@]}")}" \
        && info "DNS : amont = ${ups[*]}"

    mapfile -t allowed < <(dns_allowed_clients)

    dns_api_ok "contrôle d'accès" POST /control/access/set \
        "{\"allowed_clients\":$(dns_json_array "${allowed[@]}"),\"disallowed_clients\":[],\"blocked_hosts\":[\"version.bind\",\"id.server\",\"hostname.bind\"]}" \
        && info "DNS : clients autorisés = ${allowed[*]}"

    if [[ "$DNS_LOCAL_REWRITE" == "true" ]]; then

        existing="$(dns_api GET /control/rewrite/list 2>/dev/null || true)"

        while read -r name; do
            [[ -n "$name" ]] || continue

            if grep -q "\"domain\" *: *\"${name}\"" <<< "$existing"; then
                continue
            fi

            dns_api_ok "réécriture ${name}" POST /control/rewrite/add \
                "{\"domain\":$(dns_json_str "$name"),\"answer\":$(dns_json_str "$LAN_IP")}" \
                && info "DNS : ${name} -> ${LAN_IP} (réseau local)"
        done < <(dns_local_names)
    fi

    # Listes de blocage supplémentaires : "Nom|URL;Nom|URL" (la liste AdGuard par défaut est déjà active).
    if [[ -n "${DNS_BLOCKLISTS:-}" ]]; then

        existing="$(dns_api GET /control/filtering/status 2>/dev/null || true)"

        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            name="${entry%%|*}"
            url="${entry#*|}"

            if [[ -z "$url" || "$url" == "$entry" ]]; then
                warn "DNS : DNS_BLOCKLISTS : entrée '${entry}' ignorée (format attendu : Nom|URL)."
                continue
            fi

            if grep -qF "\"${url}\"" <<< "$existing"; then
                continue
            fi

            dns_api_ok "liste ${name}" POST /control/filtering/add_url \
                "{\"name\":$(dns_json_str "$name"),\"url\":$(dns_json_str "$url"),\"whitelist\":false}" \
                && info "DNS : liste de blocage ajoutée : ${name}"
        done < <(tr ';' '\n' <<< "$DNS_BLOCKLISTS")
    fi

    return 0
}

create_dns_ct() {

    if pct status "$DNS_ID" >/dev/null 2>&1; then

        warn "CT ${DNS_ID} existe déjà. Création DNS ignorée (./install.sh --run dns_configure pour réappliquer la configuration)."

        return 0
    fi

    [[ -n "$DNS_ADMIN_PASSWORD" ]] \
        || DNS_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"

    [[ -n "$DNS_ADMIN_PASSWORD" ]] || die "Échec de génération de DNS_ADMIN_PASSWORD."

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT DNS ${DNS_ID}..."

    pct create "$DNS_ID" \
        "$TEMPLATE" \
        --hostname "$DNS_HOSTNAME" \
        --cores "$DNS_CORES" \
        --memory "$DNS_MEMORY" \
        --swap 256 \
        --rootfs "${GUEST_STORAGE}:${DNS_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${DNS_GATEWAY},ip=${DNS_IP}" \
        --unprivileged 1 \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$DNS_ID"

    pct_wait_for_network "$DNS_ID"

    local WORK url_base
    WORK="$(mktemp -d)"

    if [[ "$DNS_VERSION" == "latest" ]]; then
        url_base="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download"
    else
        url_base="https://github.com/AdguardTeam/AdGuardHome/releases/download/${DNS_VERSION}"
    fi

    # Mot de passe (fichier 0600) et paramètres de l'assistant de première configuration.
    printf '%s\n' "$DNS_ADMIN_PASSWORD" > "${WORK}/pass"
    printf '{"web":{"ip":"0.0.0.0","port":80},"dns":{"ip":"0.0.0.0","port":53},"username":%s,"password":%s}' \
        "$(dns_json_str "$DNS_ADMIN_USER")" "$(dns_json_str "$DNS_ADMIN_PASSWORD")" > "${WORK}/wizard.json"

    cat > "${WORK}/install-dns.sh" <<EOF_INSTALL
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

URL_BASE="${url_base}"

apt-get update
apt-get install -y ca-certificates curl dnsutils

# Libère le port 53 si un résolveur local l'occupe.
systemctl disable --now systemd-resolved >/dev/null 2>&1 || true

case "\$(dpkg --print-architecture)" in
    amd64) ARCH=amd64 ;;
    arm64) ARCH=arm64 ;;
    armhf) ARCH=armv7 ;;
    *) echo "Architecture non gérée : \$(dpkg --print-architecture)" >&2; exit 1 ;;
esac

curl -fsSL --retry 3 -o /tmp/AdGuardHome.tar.gz "\${URL_BASE}/AdGuardHome_linux_\${ARCH}.tar.gz"
tar -xzf /tmp/AdGuardHome.tar.gz -C /opt
rm -f /tmp/AdGuardHome.tar.gz

mv /root/dns-pass /root/adguard-admin.pass
chmod 600 /root/adguard-admin.pass

/opt/AdGuardHome/AdGuardHome -s install

# Assistant de première configuration (port 3000) : compte admin, interface sur 80, DNS sur 53.
for i in \$(seq 1 30); do
    if curl -fsS -o /dev/null http://127.0.0.1:3000/control/install/get_addresses; then
        break
    fi
    sleep 2
done

curl -fsS -X POST -H 'Content-Type: application/json' -d @/root/dns-wizard.json \
    http://127.0.0.1:3000/control/install/configure
rm -f /root/dns-wizard.json

systemctl enable AdGuardHome >/dev/null 2>&1 || true
EOF_INSTALL

    pct push "$DNS_ID" "${WORK}/pass"        /root/dns-pass   --perms 0600
    pct push "$DNS_ID" "${WORK}/wizard.json" /root/dns-wizard.json --perms 0600

    pct_push_script "$DNS_ID" "${WORK}/install-dns.sh" /root/install-dns.sh

    rm -rf "$WORK"

    pct exec "$DNS_ID" -- bash /root/install-dns.sh

    # L'interface passe de 3000 à 80 après l'assistant : attendre qu'elle réponde.
    dns_wait_ready || warn "DNS : l'interface ne répond pas encore sur ${DNS_IP%%/*}:80."

    dns_configure

    info "DNS installé dans le CT ${DNS_ID} : http://${DNS_IP%%/*} (utilisateur ${DNS_ADMIN_USER})"

    verify_dns
}

# Attend que l'API réponde (HTTP 200 sur /control/status).
dns_wait_ready() {

    local attempt out

    for attempt in $(seq 1 30); do

        out="$(dns_api GET /control/status 2>/dev/null || true)"

        if [[ "${out##*$'\n'}" == "200" ]]; then
            return 0
        fi

        sleep 3
    done

    return 1
}

# Contrôle : service actif, résolution normale, blocage d'une régie publicitaire,
# réécriture interne.
verify_dns() {

    local ans want

    if ! dns_wait_ready; then
        warn "DNS : l'API ne répond pas. Diagnostic : ./install.sh --run dns_logs"
        return 0
    fi

    info "DNS : AdGuard Home répond (API OK)."

    ans="$(pct exec "$DNS_ID" -- dig +short +time=3 +tries=1 @127.0.0.1 example.com 2>/dev/null | head -n1 || true)"
    if [[ -n "$ans" ]]; then
        info "DNS : résolution OK (example.com -> ${ans})."
    else
        warn "DNS : example.com ne se résout pas (accès Internet du CT / DNS amont ? voir DNS_UPSTREAMS)."
    fi

    ans="$(pct exec "$DNS_ID" -- dig +short +time=3 +tries=1 @127.0.0.1 doubleclick.net 2>/dev/null | head -n1 || true)"
    if [[ -z "$ans" || "$ans" == "0.0.0.0" || "$ans" == "::" ]]; then
        info "DNS : blocage OK (doubleclick.net bloqué)."
    else
        warn "DNS : doubleclick.net n'est pas bloqué (${ans}) : les listes se téléchargent peut-être encore, relance ./install.sh --run dns_check dans une minute."
    fi

    if [[ "$DNS_LOCAL_REWRITE" == "true" ]]; then
        want="$LAN_IP"
        ans="$(pct exec "$DNS_ID" -- dig +short +time=3 +tries=1 @127.0.0.1 "${NEXTCLOUD_SUBDOMAIN}.${DOMAIN}" 2>/dev/null | head -n1 || true)"
        if [[ "$ans" == "$want" ]]; then
            info "DNS : réécriture interne OK (${NEXTCLOUD_SUBDOMAIN}.${DOMAIN} -> ${ans})."
        else
            warn "DNS : ${NEXTCLOUD_SUBDOMAIN}.${DOMAIN} -> '${ans:-aucune réponse}' au lieu de ${want}."
        fi
    fi

    return 0
}

# Lecture seule : mêmes contrôles + redirections de ports. ./install.sh --run dns_check
dns_check() {

    verify_dns

    iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--to-destination ${DNS_IP%%/*}:" || warn "DNS : aucune redirection de port vers le CT (DNS_FORWARD_LAN=${DNS_FORWARD_LAN} ?)."
}

# Statistiques (requêtes, bloquées). ./install.sh --run dns_stats
dns_stats() {

    local out
    out="$(dns_api GET /control/stats)" || return 1
    printf '%s\n' "${out%$'\n'*}"
}

# Journaux du service. ./install.sh --run dns_logs
dns_logs() {
    pct exec "$DNS_ID" -- journalctl -u AdGuardHome --no-pager -n 50
}

# Met AdGuard Home à jour (nouveau binaire, configuration conservée).
# ./install.sh --run dns_update
dns_update() {

    local url_base

    if [[ "$DNS_VERSION" == "latest" ]]; then
        url_base="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download"
    else
        url_base="https://github.com/AdguardTeam/AdGuardHome/releases/download/${DNS_VERSION}"
    fi

    info "DNS : mise à jour d'AdGuard Home (${DNS_VERSION})..."

    pct exec "$DNS_ID" -- bash -c "
        set -e
        case \"\$(dpkg --print-architecture)\" in amd64) A=amd64;; arm64) A=arm64;; armhf) A=armv7;; *) exit 1;; esac
        curl -fsSL --retry 3 -o /tmp/agh.tgz '${url_base}/AdGuardHome_linux_'\"\$A\"'.tar.gz'
        mkdir -p /tmp/agh && tar -xzf /tmp/agh.tgz -C /tmp/agh
        systemctl stop AdGuardHome
        cp /tmp/agh/AdGuardHome/AdGuardHome /opt/AdGuardHome/AdGuardHome
        systemctl start AdGuardHome
        rm -rf /tmp/agh /tmp/agh.tgz
    "

    dns_wait_ready && info "DNS : AdGuard Home redémarré." || warn "DNS : l'API ne répond pas après la mise à jour (./install.sh --run dns_logs)."
}

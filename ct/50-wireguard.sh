###############################################################################
#                       WIREGUARD (CT VPN + SORTIES VPN)                      #
###############################################################################

# Architecture
# ------------
#  - Un CT LXC (WG_ID) sur le bridge privé fait tourner le serveur WireGuard
#    (interface wg0, réseau VPN WG_NET). L'hôte redirige UDP WG_PORT vers lui ;
#    la box doit rediriger UDP WG_PORT vers l'IP LAN de l'hôte.
#  - Chaque appareil = un "pair" avec un PROFIL qui fixe ses droits :
#        lan       : le réseau privé des VM + l'hôte (Samba, SSH, Proxmox...)
#        backup    : uniquement la VM FILES, ports WG_BACKUP_PORTS (sauvegardes)
#        internet  : Internet uniquement, AUCUN accès au LAN ni aux VM
#    Les droits sont appliqués par le pare-feu du CT (chaîne WG_FWD), pas par
#    la confiance accordée au client. Les pairs ne se voient pas entre eux.
#  - SORTIES VPN : des configurations WireGuard d'un fournisseur (une par pays)
#    sont importées comme interfaces wx-<nom>. Un pair "internet" peut être
#    rattaché à une sortie (routage par IP source). Si la sortie tombe, le
#    trafic du pair est BLOQUÉ (jamais de repli sur l'IP du homelab).
#
# Gestion courante (depuis l'hôte) : ./install.sh --run wg_<commande> ...
#   wg_add_peer <nom> <lan|backup|internet> [--exit <sortie>] [--pubkey <clé>]
#   wg_add_device <appareil> [sortie...]   (un pair internet par sortie)
#   wg_show_peer <nom>      wg_remove_peer <nom>     wg_list_peers
#   wg_add_exit <nom> <fichier.conf>       wg_list_exits    wg_test_exits
#   wg_set_exit <pair> <sortie|direct>     wg_status        wg_update_cli

# Valeurs par défaut calculées à l'exécution (LAN_IP / DOMAIN peuvent changer
# pendant la configuration interactive).
wg_endpoint()     { printf '%s' "${WG_ENDPOINT:-$DOMAIN}"; }
wg_lan_routes()   { printf '%s' "${WG_LAN_ROUTES:-${PRIVATE_NET},${LAN_IP}/32}"; }
wg_backup_dests() { printf '%s' "${WG_BACKUP_DESTS:-${FILES_IP%%/*}}"; }

# ----------------------------------------------------------------------------
# Hôte : module noyau + redirection UDP
# ----------------------------------------------------------------------------

configure_wireguard_host() {

    info "WireGuard : préparation de l'hôte..."

    modprobe wireguard 2>/dev/null \
        || die "Module noyau 'wireguard' indisponible sur l'hôte Proxmox (uname -r : $(uname -r))."

    echo wireguard > /etc/modules-load.d/wireguard.conf

    info "WireGuard : redirection UDP ${WG_PORT} de l'hôte vers le CT :"

    add_dnat_forward "$WG_PORT" "${WG_IP%%/*}" "$WG_PORT" udp

    netfilter-persistent save

    iptables -t nat -C PREROUTING \
        -d "${LAN_IP}" \
        -p udp --dport "$WG_PORT" \
        -j DNAT --to-destination "${WG_IP%%/*}:${WG_PORT}" \
        || die "La règle DNAT WireGuard (UDP ${WG_PORT}) n'est pas présente."
}

# ----------------------------------------------------------------------------
# Script de gestion exécuté DANS le CT : /usr/local/sbin/wg-homelab
# (quoted heredoc : rien n'est interprété par l'hôte)
# ----------------------------------------------------------------------------

wireguard_cli_script() {
    cat <<'WGCLI'
#!/usr/bin/env bash
# wg-homelab : gestion du serveur WireGuard du homelab (exécuté dans le CT).
set -Eeuo pipefail

WGDIR="${WGDIR:-/etc/wireguard}"
CONF="${WGDIR}/wg0.conf"
PEERS="${WGDIR}/peers.list"      # nom profil ip clé_publique sortie
EXITS="${WGDIR}/exits.list"      # nom id_table
CLIENTS="${WGDIR}/clients"
PSKDIR="${WGDIR}/psk"
IFACE="wg0"
EXT_IF="${EXT_IF:-eth0}"
PRIV_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"
PRIO_EXIT_MIN=11000              # règles "oif wx-*"   : 11000-11099
PRIO_PEER_MIN=11100              # règles par pair     : 11100-11999
PRIO_MAX=11999

# shellcheck disable=SC1091
source "${WGDIR}/homelab.env"

umask 077
touch "$PEERS" "$EXITS"

die() { echo "ERREUR : $*" >&2; exit 1; }

in_list() { awk -v n="$2" '$1==n{f=1} END{exit !f}' "$1"; }

# ----------------------------------------------------------------- pare-feu
clear_rules() {
    local p
    for p in $(ip rule show | awk -F: -v a="$PRIO_EXIT_MIN" -v b="$PRIO_MAX" '$1+0>=a && $1+0<=b {print $1+0}'); do
        ip rule del priority "$p" 2>/dev/null || true
    done
}

exit_is_up() { ip link show "wx-$1" >/dev/null 2>&1; }

fw_up() {
    local c name profile ip pub xit tid dest net prio

    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
    sysctl -qw net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 2>/dev/null || true

    for c in WG_FWD WG_IN WG_EXIN; do
        iptables -N "$c" 2>/dev/null || true
        iptables -F "$c"
    done

    iptables -C FORWARD -i "$IFACE" -j WG_FWD 2>/dev/null \
        || iptables -I FORWARD 1 -i "$IFACE" -j WG_FWD
    iptables -C FORWARD -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 2 -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -C INPUT -i "$IFACE" -j WG_IN 2>/dev/null \
        || iptables -I INPUT 1 -i "$IFACE" -j WG_IN
    iptables -C INPUT -i 'wx-+' -j WG_EXIN 2>/dev/null \
        || iptables -I INPUT 1 -i 'wx-+' -j WG_EXIN
    iptables -t nat -C POSTROUTING -s "$WG_NET" -o "$EXT_IF" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$WG_NET" -o "$EXT_IF" -j MASQUERADE

    # Le CT lui-même : les pairs ne peuvent que le pinguer ; rien n'entre par les sorties VPN.
    iptables -A WG_IN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A WG_IN -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A WG_IN -j DROP
    iptables -A WG_EXIN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A WG_EXIN -j DROP

    clear_rules

    # Sorties VPN : une table de routage par sortie. Sortie tombée => "unreachable"
    # (le trafic des pairs rattachés est coupé, il ne repart jamais en direct).
    while read -r name tid; do
        [[ -n "${name:-}" ]] || continue
        iptables -t nat -C POSTROUTING -s "$WG_NET" -o "wx-${name}" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$WG_NET" -o "wx-${name}" -j MASQUERADE
        if exit_is_up "$name"; then
            ip route replace default dev "wx-${name}" table "$tid"
            sysctl -qw "net.ipv4.conf.wx-${name}.rp_filter=2" 2>/dev/null || true
        else
            ip route replace unreachable default table "$tid"
        fi
        ip rule add oif "wx-${name}" table "$tid" priority $((PRIO_EXIT_MIN + tid - 100)) 2>/dev/null || true
    done < "$EXITS"

    prio="$PRIO_PEER_MIN"

    while read -r name profile ip pub xit; do
        [[ -n "${name:-}" ]] || continue
        xit="${xit:-direct}"
        case "$profile" in
            lan)
                for dest in ${WG_LAN_ROUTES//,/ }; do
                    iptables -A WG_FWD -s "${ip}/32" -d "$dest" -j ACCEPT
                done
                ;;
            backup)
                for dest in ${WG_BACKUP_DESTS//,/ }; do
                    iptables -A WG_FWD -s "${ip}/32" -d "$dest" -p tcp -m multiport --dports "$WG_BACKUP_PORTS" -j ACCEPT
                done
                ;;
            internet)
                for net in $PRIV_NETS; do
                    iptables -A WG_FWD -s "${ip}/32" -d "$net" -j DROP
                done
                if [[ "$xit" == "direct" ]]; then
                    iptables -A WG_FWD -s "${ip}/32" -o "$EXT_IF" -j ACCEPT
                else
                    tid="$(awk -v n="$xit" '$1==n{print $2}' "$EXITS")"
                    if [[ -n "$tid" ]]; then
                        iptables -A WG_FWD -s "${ip}/32" -o "wx-${xit}" -j ACCEPT
                        ip rule add from "${ip}/32" table "$tid" priority "$prio"
                        prio=$((prio + 1))
                    fi
                fi
                ;;
        esac
    done < "$PEERS"

    iptables -A WG_FWD -j DROP
    iptables -P FORWARD DROP
}

fw_down() {
    local name tid
    iptables -D FORWARD -i "$IFACE" -j WG_FWD 2>/dev/null || true
    iptables -D FORWARD -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -j WG_IN 2>/dev/null || true
    iptables -D INPUT -i 'wx-+' -j WG_EXIN 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$WG_NET" -o "$EXT_IF" -j MASQUERADE 2>/dev/null || true
    while read -r name tid; do
        [[ -n "${name:-}" ]] || continue
        iptables -t nat -D POSTROUTING -s "$WG_NET" -o "wx-${name}" -j MASQUERADE 2>/dev/null || true
        ip route flush table "$tid" 2>/dev/null || true
    done < "$EXITS"
    clear_rules
    for c in WG_FWD WG_IN WG_EXIN; do
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
    done
}

apply() {
    if wg show "$IFACE" >/dev/null 2>&1; then
        wg syncconf "$IFACE" <(wg-quick strip "$IFACE")
        fw_up
    fi
}

# ------------------------------------------------------------------- pairs
next_ip() {
    local base="${WG_SERVER_IP%.*}" n
    for n in $(seq 2 254); do
        if ! awk -v ip="${base}.${n}" '$3==ip{f=1} END{exit !f}' "$PEERS"; then
            echo "${base}.${n}"
            return
        fi
    done
    die "plus d'adresse libre dans ${WG_NET}"
}

cmd_add() {
    local name="${1:-}" profile="${2:-}" xit="direct" client_pub="" priv pub psk ip srv_pub routes="" dns_line="" d

    [[ $# -ge 2 ]] || die "usage : add <nom> <lan|backup|internet> [--exit <sortie>] [--pubkey <clé>]"
    shift 2

    while (($#)); do
        case "$1" in
            --exit)   xit="${2:-}";        shift 2 ;;
            --pubkey) client_pub="${2:-}"; shift 2 ;;
            *) die "option inconnue : $1" ;;
        esac
    done

    [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "nom invalide (a-z, 0-9, - et _ ; 32 caractères max)"
    case "$profile" in lan | backup | internet) ;; *) die "profil inconnu : '${profile}' (lan | backup | internet)" ;; esac
    in_list "$PEERS" "$name" && die "le pair '${name}' existe déjà"

    if [[ "$xit" != "direct" ]]; then
        [[ "$profile" == "internet" ]] || die "--exit ne s'applique qu'au profil internet"
        in_list "$EXITS" "$xit" || die "sortie inconnue : '${xit}' (voir : wg-homelab exit-list)"
    fi

    ip="$(next_ip)"
    srv_pub="$(cat "${WGDIR}/server.pub")"

    if [[ -n "$client_pub" ]]; then
        pub="$client_pub"
        priv=""
    else
        priv="$(wg genkey)"
        pub="$(wg pubkey <<< "$priv")"
    fi
    psk="$(wg genpsk)"

    printf '%s\n' "$psk" > "${PSKDIR}/${name}"

    {
        echo "# BEGIN peer:${name}"
        echo "[Peer]"
        echo "PublicKey = ${pub}"
        echo "PresharedKey = ${psk}"
        echo "AllowedIPs = ${ip}/32"
        echo "# END peer:${name}"
    } >> "$CONF"

    echo "${name} ${profile} ${ip} ${pub} ${xit}" >> "$PEERS"

    case "$profile" in
        lan)
            routes="${WG_SERVER_IP}/32"
            for d in ${WG_LAN_ROUTES//,/ }; do routes+=", ${d}"; done
            ;;
        backup)
            routes="${WG_SERVER_IP}/32"
            for d in ${WG_BACKUP_DESTS//,/ }; do routes+=", ${d}/32"; done
            ;;
        internet)
            routes="0.0.0.0/0, ::/0"
            dns_line="DNS = ${WG_DNS}"
            ;;
    esac

    {
        echo "[Interface]"
        echo "PrivateKey = ${priv:-<CLE_PRIVEE_DU_CLIENT>}"
        echo "Address = ${ip}/32"
        echo "MTU = ${WG_MTU}"
        [[ -n "$dns_line" ]] && echo "$dns_line"
        echo
        echo "[Peer]"
        echo "PublicKey = ${srv_pub}"
        echo "PresharedKey = ${psk}"
        echo "Endpoint = ${WG_ENDPOINT}:${WG_PORT}"
        echo "AllowedIPs = ${routes}"
        echo "PersistentKeepalive = 25"
    } > "${CLIENTS}/${name}.conf"

    apply

    echo "Pair '${name}' créé : profil ${profile}, IP VPN ${ip}, sortie ${xit}."
    echo "Configuration client : wg-homelab show ${name}"
}

cmd_add_device() {
    local dev="${1:-}" t en
    local -a targets=()

    [[ -n "$dev" ]] || die "usage : add-device <appareil> [sortie...]"
    shift

    if (($# > 0)); then
        targets=("$@")
    else
        targets=(direct)
        while read -r en _; do
            [[ -n "${en:-}" ]] && targets+=("$en")
        done < "$EXITS"
    fi

    for t in "${targets[@]}"; do
        cmd_add "${dev}-${t}" internet --exit "$t"
    done
}

cmd_remove() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage : remove <nom>"
    in_list "$PEERS" "$name" || die "pair inconnu : ${name}"

    sed -i "/^# BEGIN peer:${name}\$/,/^# END peer:${name}\$/d" "$CONF"
    awk -v n="$name" '$1!=n' "$PEERS" > "${PEERS}.tmp"
    cat "${PEERS}.tmp" > "$PEERS"
    rm -f "${PEERS}.tmp" "${CLIENTS}/${name}.conf" "${PSKDIR}/${name}"

    apply
    echo "Pair '${name}' supprimé (accès révoqué)."
}

cmd_show() {
    local f="${CLIENTS}/${1:-}.conf"
    [[ -n "${1:-}" && -f "$f" ]] || die "configuration introuvable pour '${1:-}'"
    cat "$f"
    if command -v qrencode >/dev/null 2>&1; then
        echo
        qrencode -t ansiutf8 < "$f"
    fi
}

cmd_set_exit() {
    local name="${1:-}" xit="${2:-}"
    [[ -n "$name" && -n "$xit" ]] || die "usage : set-exit <pair> <sortie|direct>"
    in_list "$PEERS" "$name" || die "pair inconnu : ${name}"
    [[ "$(awk -v n="$name" '$1==n{print $2}' "$PEERS")" == "internet" ]] || die "seuls les pairs du profil internet ont une sortie"
    if [[ "$xit" != "direct" ]]; then
        in_list "$EXITS" "$xit" || die "sortie inconnue : ${xit}"
    fi

    awk -v n="$name" -v x="$xit" '$1==n{$5=x} {print}' "$PEERS" > "${PEERS}.tmp"
    cat "${PEERS}.tmp" > "$PEERS"
    rm -f "${PEERS}.tmp"

    apply
    echo "Le pair '${name}' sort maintenant par : ${xit} (aucun changement côté client)."
}

cmd_list() {
    local name profile ip pub xit hs
    printf '%-22s %-9s %-14s %-10s %s\n' PAIR PROFIL IP_VPN SORTIE HANDSHAKE
    while read -r name profile ip pub xit; do
        [[ -n "${name:-}" ]] || continue
        hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k{print $2}')"
        if [[ -z "$hs" || "$hs" == "0" ]]; then
            hs="jamais"
        else
            hs="$(date -d "@${hs}" '+%F %T')"
        fi
        printf '%-22s %-9s %-14s %-10s %s\n' "$name" "$profile" "$ip" "${xit:-direct}" "$hs"
    done < "$PEERS"
}

# ----------------------------------------------------------- sorties VPN
cmd_exit_add() {
    local name="${1:-}" file="${2:-}" tid out

    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,9}$ ]] || die "nom de sortie invalide (a-z, 0-9, - ; 10 caractères max)"
    [[ -f "$file" ]] || die "fichier introuvable : ${file}"
    in_list "$EXITS" "$name" && die "la sortie '${name}' existe déjà"
    grep -q '^\[Peer\]' "$file" && grep -qi '^PrivateKey' "$file" || die "ce n'est pas une configuration WireGuard complète"

    tid=101
    while awk -v t="$tid" '$2==t{f=1} END{exit !f}' "$EXITS"; do tid=$((tid + 1)); done
    ((tid <= 199)) || die "trop de sorties (99 maximum)"

    out="${WGDIR}/wx-${name}.conf"

    # Neutralise la config du fournisseur : pas de route automatique (Table = off),
    # pas de DNS, pas de PostUp/Down, pas d'adresse IPv6 ; routage géré par fw-up.
    awk -v mtu="$WG_MTU" '
        /^\[Interface\]/ {
            print
            print "Table = off"
            print "MTU = " mtu
            print "PostUp = /usr/local/sbin/wg-homelab fw-up"
            print "PostDown = /usr/local/sbin/wg-homelab fw-up"
            ini = 1; next
        }
        /^\[Peer\]/ { ini = 0 }
        ini && tolower($0) ~ /^[[:space:]]*(dns|table|postup|postdown|preup|predown|saveconfig|mtu)[[:space:]]*=/ { next }
        ini && tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            n = split($0, a, /[[:space:]]*,[[:space:]]*/)
            keep = ""
            for (i = 1; i <= n; i++) if (a[i] !~ /:/ && a[i] != "") keep = keep (keep == "" ? "" : ", ") a[i]
            if (keep != "") print "Address = " keep
            next
        }
        { print }
    ' "$file" > "$out"

    grep -q '^Address' "$out" || { rm -f "$out"; die "aucune adresse IPv4 dans ce fichier"; }

    echo "${name} ${tid}" >> "$EXITS"

    systemctl enable "wg-quick@wx-${name}" >/dev/null 2>&1 || true
    systemctl restart "wg-quick@wx-${name}" \
        || { echo "Échec du démarrage : journalctl -u wg-quick@wx-${name}" >&2; fw_up; exit 1; }

    fw_up
    sleep 3
    echo "Sortie '${name}' ajoutée (table ${tid})."
    wg show "wx-${name}" latest-handshakes 2>/dev/null || true
    echo "Test : wg-homelab exit-test"
}

cmd_exit_remove() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage : exit-remove <sortie>"
    in_list "$EXITS" "$name" || die "sortie inconnue : ${name}"
    if awk -v n="$name" '$5==n{f=1} END{exit !f}' "$PEERS"; then
        die "des pairs utilisent encore cette sortie : réassigne-les d'abord (set-exit <pair> direct)"
    fi

    systemctl disable --now "wg-quick@wx-${name}" >/dev/null 2>&1 || true
    awk -v n="$name" '$1!=n' "$EXITS" > "${EXITS}.tmp"
    cat "${EXITS}.tmp" > "$EXITS"
    rm -f "${EXITS}.tmp" "${WGDIR}/wx-${name}.conf"
    fw_up
    echo "Sortie '${name}' supprimée."
}

cmd_exit_list() {
    local name tid state hs
    printf '%-12s %-7s %-8s %s\n' SORTIE TABLE ETAT HANDSHAKE
    while read -r name tid; do
        [[ -n "${name:-}" ]] || continue
        if exit_is_up "$name"; then state="active"; else state="ARRETEE"; fi
        hs="$(wg show "wx-${name}" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n 1)"
        if [[ -z "$hs" || "$hs" == "0" ]]; then hs="jamais"; else hs="$(date -d "@${hs}" '+%F %T')"; fi
        printf '%-12s %-7s %-8s %s\n' "$name" "$tid" "$state" "$hs"
    done < "$EXITS"
}

cmd_exit_test() {
    local name tid ip
    ip="$(curl -s --max-time 10 https://api.ipify.org || true)"
    printf '%-12s %s\n' "direct" "${ip:-échec}"
    while read -r name tid; do
        [[ -n "${name:-}" ]] || continue
        ip="$(curl -s --interface "wx-${name}" --max-time 10 https://api.ipify.org || true)"
        printf '%-12s %s\n' "$name" "${ip:-échec (sortie arrêtée ou fournisseur injoignable)}"
    done < "$EXITS"
}

cmd_status() {
    wg show
    echo
    cmd_list
    echo
    cmd_exit_list
}

usage() {
    cat <<'EOF'
wg-homelab <commande>
  add <nom> <lan|backup|internet> [--exit <sortie>] [--pubkey <clé>]
  add-device <appareil> [sortie...]    un pair internet par sortie (+ direct)
  remove <nom>      show <nom>      list      set-exit <pair> <sortie|direct>
  exit-add <nom> <fichier.conf>   exit-remove <nom>   exit-list   exit-test
  status            fw-up           fw-down
EOF
}

case "${1:-}" in
    add)         shift; cmd_add "$@" ;;
    add-device)  shift; cmd_add_device "$@" ;;
    remove)      shift; cmd_remove "$@" ;;
    show)        shift; cmd_show "$@" ;;
    list)        cmd_list ;;
    set-exit)    shift; cmd_set_exit "$@" ;;
    exit-add)    shift; cmd_exit_add "$@" ;;
    exit-remove) shift; cmd_exit_remove "$@" ;;
    exit-list)   cmd_exit_list ;;
    exit-test)   cmd_exit_test ;;
    status)      cmd_status ;;
    fw-up)       fw_up ;;
    fw-down)     fw_down ;;
    *)           usage ;;
esac
WGCLI
}

# ----------------------------------------------------------------------------
# Script d'installation exécuté DANS le CT
# ----------------------------------------------------------------------------

wireguard_install_script() {
    cat <<'WGINSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# shellcheck disable=SC1091
source /etc/wireguard/homelab.env

apt-get update
apt-get install -y --no-install-recommends wireguard-tools iproute2 iptables qrencode curl ca-certificates

# Test explicite : l'interface WireGuard noyau doit pouvoir être créée dans le CT.
if ! ip link add wgtest type wireguard 2>/dev/null; then
    echo "ERREUR : impossible de créer une interface WireGuard dans ce CT." >&2
    echo "  - sur l'hôte : modprobe wireguard ; lsmod | grep wireguard" >&2
    echo "  - sinon relancer avec WG_UNPRIVILEGED=0 (CT privilégié)" >&2
    exit 42
fi
ip link del wgtest

umask 077
install -d -m 700 /etc/wireguard/clients /etc/wireguard/psk

if [[ ! -f /etc/wireguard/server.key ]]; then
    wg genkey > /etc/wireguard/server.key
    wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
fi

touch /etc/wireguard/peers.list /etc/wireguard/exits.list

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    cat > /etc/wireguard/wg0.conf <<WGCONF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat /etc/wireguard/server.key)
MTU = ${WG_MTU}
PostUp = /usr/local/sbin/wg-homelab fw-up
PostDown = /usr/local/sbin/wg-homelab fw-down

WGCONF
fi

# Redémarre automatiquement un tunnel (serveur ou sortie VPN) qui échoue au démarrage.
install -d /etc/systemd/system/wg-quick@.service.d
cat > /etc/systemd/system/wg-quick@.service.d/restart.conf <<'DROPIN'
[Service]
Restart=on-failure
RestartSec=30
DROPIN
systemctl daemon-reload

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
systemctl is-active --quiet wg-quick@wg0

wg show wg0
WGINSTALL
}

# Fichier d'environnement du CT (valeurs de l'hôte, sans aucun secret).
wireguard_env_file() {
    cat <<EOF
WG_ENDPOINT="$(wg_endpoint)"
WG_PORT="${WG_PORT}"
WG_NET="${WG_NET}"
WG_SERVER_IP="${WG_SERVER_IP}"
WG_MTU="${WG_MTU}"
WG_DNS="${WG_DNS}"
WG_LAN_ROUTES="$(wg_lan_routes)"
WG_BACKUP_DESTS="$(wg_backup_dests)"
WG_BACKUP_PORTS="${WG_BACKUP_PORTS}"
EOF
}

# Pousse (ou met à jour) le CLI et l'environnement dans le CT.
wg_push_files() {

    local tmp

    tmp="$(mktemp)"
    wireguard_env_file > "$tmp"
    pct exec "$WG_ID" -- mkdir -p /etc/wireguard
    pct push "$WG_ID" "$tmp" /etc/wireguard/homelab.env --perms 0600
    rm -f "$tmp"

    tmp="$(mktemp)"
    wireguard_cli_script > "$tmp"
    pct push "$WG_ID" "$tmp" /usr/local/sbin/wg-homelab --perms 0700
    rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# Création du CT
# ----------------------------------------------------------------------------

create_wireguard_ct() {

    if pct status "$WG_ID" >/dev/null 2>&1; then

        warn "CT ${WG_ID} existe déjà. Création WireGuard ignorée (mise à jour du CLI : ./install.sh --run wg_update_cli)."

        return 0
    fi

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT WireGuard ${WG_ID}..."

    # Pas de mot de passe root : accès par "pct enter ${WG_ID}" depuis l'hôte.
    pct create "$WG_ID" \
        "$TEMPLATE" \
        --hostname "$WG_HOSTNAME" \
        --cores "$WG_CORES" \
        --memory "$WG_MEMORY" \
        --swap 128 \
        --rootfs "local-lvm:${WG_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${WG_GATEWAY},ip=${WG_IP}" \
        --unprivileged "$WG_UNPRIVILEGED" \
        --onboot 1

    pct start "$WG_ID"

    pct_wait_for_network "$WG_ID"

    wg_push_files

    local SCRIPT
    SCRIPT="$(mktemp)"
    wireguard_install_script > "$SCRIPT"

    pct_push_script "$WG_ID" "$SCRIPT" "/root/install-wireguard.sh"

    pct exec "$WG_ID" -- bash /root/install-wireguard.sh \
        || die "Échec de l'installation de WireGuard dans le CT ${WG_ID} (voir les messages ci-dessus)."

    pct exec "$WG_ID" -- rm -f /root/install-wireguard.sh
    rm -f "$SCRIPT"

    info "WireGuard installé dans le CT ${WG_ID}."

    local entry name profile

    for entry in $WG_PEERS; do

        name="${entry%%:*}"
        profile="${entry#*:}"

        if pct exec "$WG_ID" -- grep -q "^${name} " /etc/wireguard/peers.list; then
            info "WireGuard : pair '${name}' déjà présent."
            continue
        fi

        pct exec "$WG_ID" -- wg-homelab add "$name" "$profile"
    done
}

verify_wireguard() {

    info "WireGuard : vérification..."

    pct exec "$WG_ID" -- wg show wg0 \
        || warn "WireGuard : l'interface wg0 n'est pas active dans le CT ${WG_ID}."

    iptables -t nat -C PREROUTING \
        -d "${LAN_IP}" -p udp --dport "$WG_PORT" \
        -j DNAT --to-destination "${WG_IP%%/*}:${WG_PORT}" >/dev/null 2>&1 \
        || warn "WireGuard : redirection UDP ${WG_PORT} de l'hôte absente."

    info "WireGuard : n'oublie pas la redirection UDP ${WG_PORT} -> ${LAN_IP} sur ta box."
}

deploy_wireguard() {

    configure_wireguard_host
    create_wireguard_ct
    verify_wireguard
}

# ----------------------------------------------------------------------------
# Commandes de gestion depuis l'hôte : ./install.sh --run wg_<commande>
# ----------------------------------------------------------------------------

wg_add_peer()    { pct exec "$WG_ID" -- wg-homelab add "$@"; }
wg_add_device()  { pct exec "$WG_ID" -- wg-homelab add-device "$@"; }
wg_show_peer()   { pct exec "$WG_ID" -- wg-homelab show "$@"; }
wg_remove_peer() { pct exec "$WG_ID" -- wg-homelab remove "$@"; }
wg_list_peers()  { pct exec "$WG_ID" -- wg-homelab list; }
wg_set_exit()    { pct exec "$WG_ID" -- wg-homelab set-exit "$@"; }
wg_list_exits()  { pct exec "$WG_ID" -- wg-homelab exit-list; }
wg_test_exits()  { pct exec "$WG_ID" -- wg-homelab exit-test; }
wg_status()      { pct exec "$WG_ID" -- wg-homelab status; }

# Importe une configuration WireGuard de fournisseur VPN comme sortie.
# Usage : wg_add_exit <nom> </chemin/fichier.conf>
wg_add_exit() {

    local name="${1:-}" file="${2:-}"

    [[ -n "$name" && -f "$file" ]] || die "Usage : wg_add_exit <nom> </chemin/fichier.conf>"

    pct push "$WG_ID" "$file" "/root/exit-${name}.conf" --perms 0600
    pct exec "$WG_ID" -- wg-homelab exit-add "$name" "/root/exit-${name}.conf" || {
        pct exec "$WG_ID" -- rm -f "/root/exit-${name}.conf"
        die "Import de la sortie '${name}' échoué."
    }
    pct exec "$WG_ID" -- rm -f "/root/exit-${name}.conf"

    info "Sortie '${name}' importée. Tu peux supprimer ${file} de l'hôte : ./install.sh --run wg_test_exits pour vérifier."
}

# Met à jour le CLI et l'environnement d'un CT existant (sans toucher aux clés).
wg_update_cli() {

    wg_push_files
    pct exec "$WG_ID" -- wg-homelab fw-up
    info "WireGuard : CLI et environnement mis à jour dans le CT ${WG_ID}."
}

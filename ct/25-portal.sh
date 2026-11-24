###############################################################################
#                PORTAIL : UNE PAGE D'ACCUEIL POUR TOUS LES SERVICES           #
###############################################################################

# Page unique https://home.<domaine> (PORTAL_SUBDOMAIN) servie par SWAG, avec un lien vers chaque service
# INSTALLÉ (cloud, sync, photos, media...). C'est une page statique générée par le script : aucun service
# supplémentaire, aucun script côté serveur, aucune ressource externe.
#
# Deux vues, choisies par nginx selon l'adresse source (geo) :
#   - réseau local / VPN (10.x, 172.16-31.x, 192.168.x) : services publics + liens d'administration
#     (Proxmox, Uptime Kuma, AdGuard, Sonarr...) qui n'existent que sur le LAN ;
#   - Internet : seulement les services déjà exposés par SWAG, jamais les liens d'administration.
# Le même nom marche partout (DNS interne AdGuard -> SWAG en local, DNS public en externe) ; en secours,
# http://<IP LAN hôte>:PORTAL_LOCAL_PORT sert la vue locale sans aucun DNS.
# Mot de passe (PORTAL_AUTH) : "public" = demandé seulement depuis Internet, "all" = partout, "none" = jamais.

portal_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# Services du portail, un par ligne : vue|icône|nom|description|URL   (vue = pub : toutes les vues ; lan : vue locale)
portal_entries() {

    local n d="${DOMAIN}" lan="${LAN_IP}"

    n="$(sd_all NEXTCLOUD_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_NEXTCLOUD:-false}" == "true" && -n "$n" ]] && echo "pub|☁️|Nextcloud|Fichiers, agenda, contacts|https://${n}.${d}"
    n="$(sd_all SYNCIN_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_SYNCIN:-false}" == "true" && -n "$n" ]] && echo "pub|🔄|Sync-in|Synchronisation de fichiers|https://${n}.${d}"
    n="$(sd_all IMMICH_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_IMMICH:-false}" == "true" && -n "$n" ]] && echo "pub|📷|Immich|Photos et vidéos|https://${n}.${d}"
    n="$(sd_all JELLYFIN_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_JELLYFIN:-false}" == "true" && -n "$n" ]] && echo "pub|🎬|Jellyfin|Films et séries|https://${n}.${d}"
    n="$(sd_all NODE_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_NODE:-false}" == "true" && -n "$n" ]] && echo "pub|🌐|Application web|Application Node|https://${n}.${d}"
    n="$(sd_all NTFY_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_MONITOR:-false}" == "true" && "${MONITOR_NTFY:-false}" == "true" && -n "$n" ]] && echo "pub|🔔|ntfy|Notifications|https://${n}.${d}"
    n="$(sd_all HOMEPAGE_SUBDOMAIN | head -n1)"
    [[ "${ENABLE_MONITOR:-false}" == "true" && "${MONITOR_HOMEPAGE:-false}" == "true" && -n "$n" ]] && echo "pub|🏠|Homepage|Tableau de bord|https://${n}.${d}"

    # Réseau local / VPN uniquement
    echo "lan|🖥️|Proxmox|Hyperviseur|https://${lan}:8006"
    [[ "${ENABLE_HOMEASSISTANT:-false}" == "true" ]] && echo "lan|🏡|Home Assistant|Domotique|http://${lan}:${HOMEASSISTANT_HTTP_PORT}"
    [[ "${ENABLE_FILES:-false}" == "true" ]] && echo "lan|🗂️|Webmin|Administration des partages (Samba)|https://${lan}:10000"
    if [[ "${ENABLE_MONITOR:-false}" == "true" ]]; then
        [[ "${MONITOR_KUMA:-false}" == "true" ]] && echo "lan|📈|Uptime Kuma|Surveillance des services|http://${lan}:${KUMA_PORT}"
        [[ "${MONITOR_HOMEPAGE:-false}" == "true" ]] && echo "lan|🏠|Homepage|Tableau de bord interne|http://${lan}:${HOMEPAGE_PORT}"
    fi
    [[ "${ENABLE_AI:-false}" == "true" ]] && echo "lan|🤖|Assistant IA|Open WebUI (discussion, normes)|http://${lan}:${AI_WEB_PORT}"
    [[ "${ENABLE_DNS:-false}" == "true" && -n "${DNS_UI_PORT:-}" ]] && echo "lan|🛡️|AdGuard Home|DNS et blocage de publicités|http://${lan}:${DNS_UI_PORT}"
    if [[ "${ENABLE_ARR:-false}" == "true" && "${ENABLE_DOCKER:-false}" == "true" ]]; then
        echo "lan|📺|Sonarr|Séries|http://${lan}:${SONARR_PORT}"
        echo "lan|🎞️|Radarr|Films|http://${lan}:${RADARR_PORT}"
        echo "lan|🔎|Prowlarr|Indexeurs|http://${lan}:${PROWLARR_PORT}"
        echo "lan|⬇️|qBittorrent|Téléchargements|http://${lan}:${QBIT_PORT}"
    fi
    return 0
}

# HTML d'une vue ($1 = public | lan), sur stdout.
portal_html() {

    local view="$1" title sub line kind icon name desc url count=0 cards="" section_lan=""
    title="$(portal_html_escape "${PORTAL_TITLE:-Mon serveur}")"
    sub="Services disponibles"
    [[ "$view" == "lan" ]] && sub="Services et administration (réseau local / VPN)"

    while IFS='|' read -r kind icon name desc url; do
        [[ -n "$kind" ]] || continue
        [[ "$view" == "public" && "$kind" == "lan" ]] && continue
        local card
        card="<a class=\"card\" href=\"$(portal_html_escape "$url")\"><span class=\"ic\">${icon}</span><span class=\"tx\"><b>$(portal_html_escape "$name")</b><small>$(portal_html_escape "$desc")</small></span></a>"
        if [[ "$kind" == "lan" ]]; then section_lan+="$card"$'\n'; else cards+="$card"$'\n'; fi
        count=$((count + 1))
    done < <(portal_entries)

    [[ -n "$cards" ]] || cards="<p class=\"empty\">Aucun service exposé.</p>"

    cat <<HTML
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${title}</title>
<style>
:root{--bg:#f4f5f7;--fg:#1c2230;--mut:#667085;--card:#fff;--bd:#e3e6ec;--ac:#2f6fed}
@media (prefers-color-scheme:dark){:root{--bg:#12151c;--fg:#e8ebf2;--mut:#9aa3b5;--card:#1b2030;--bd:#2a3145;--ac:#6f9bff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:920px;margin:0 auto;padding:40px 16px 56px}
h1{margin:0;font-size:1.8rem}
.sub{color:var(--mut);margin:.3rem 0 1.6rem}
h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);margin:2rem 0 .7rem}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px}
.card{display:flex;gap:12px;align-items:center;padding:14px;background:var(--card);border:1px solid var(--bd);border-radius:12px;color:inherit;text-decoration:none}
.card:hover,.card:focus-visible{border-color:var(--ac);outline:none}
.ic{font-size:1.7rem;line-height:1}
.tx{display:flex;flex-direction:column;min-width:0}
.tx small{color:var(--mut)}
.empty{color:var(--mut)}
</style>
</head>
<body>
<main>
<h1>${title}</h1>
<p class="sub">${sub}</p>
<div class="grid">
${cards}</div>
HTML
    if [[ -n "$section_lan" ]]; then
        printf '<h2>Administration</h2>\n<div class="grid">\n%s</div>\n' "$section_lan"
    fi
    printf '</main>\n</body>\n</html>\n'
}

# Conf nginx du portail (stdout). Variables : $1 = 1 si mot de passe.
portal_conf() {

    local fq realm_pub="off" realm_lan="off"
    fq="$(sd_fqdns PORTAL_SUBDOMAIN)"

    case "${PORTAL_AUTH:-public}" in
        public) realm_pub="Portail" ;;
        all)    realm_pub="Portail"; realm_lan="Portail" ;;
    esac

    cat <<CONF
# Vue selon l'origine : réseau local / VPN ou Internet
geo \$portal_view {
    default         public;
    10.0.0.0/8      lan;
    172.16.0.0/12   lan;
    192.168.0.0/16  lan;
    127.0.0.1       lan;
}
map \$portal_view \$portal_realm {
    public  "${realm_pub}";
    lan     "${realm_lan}";
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen ${PORTAL_LOCAL_PORT};

    server_name ${fq} _portal_local;

    include /config/nginx/ssl.conf;

    root /config/www/portal;
    auth_basic \$portal_realm;
    auth_basic_user_file /config/nginx/.htpasswd-portal;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header Cache-Control "no-store" always;

    location = / {
        try_files /portal-\$portal_view.html =404;
    }
    location / {
        return 404;
    }
}
CONF
}

# Génère l'utilisateur/mot de passe du portail si besoin (valeurs de l'ANSWERS_FILE conservées).
portal_secrets() {
    [[ "${PORTAL_AUTH:-public}" != "none" ]] || return 0
    [[ -n "${PORTAL_USER:-}" ]] || PORTAL_USER="admin"
    [[ -n "${PORTAL_PASSWORD:-}" ]] || PORTAL_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    [[ -n "$PORTAL_PASSWORD" ]] || die "Échec de génération du mot de passe du portail."
}

# Installe (ou met à jour) le portail dans SWAG : pages, conf nginx, mot de passe, port local, DNS, redirection LAN.
# Usage : ./install.sh --run portal_apply   (à relancer après l'ajout ou le retrait d'un service)
portal_apply() {

    [[ "${ENABLE_PORTAL:-true}" == "true" ]] || { info "Portail désactivé (ENABLE_PORTAL=false)."; return 0; }
    pct status "$SWAG_ID" >/dev/null 2>&1 || { warn "Portail : CT SWAG ${SWAG_ID} introuvable, ignoré."; return 0; }

    [[ -n "${SUBDOMAIN_ALL[PORTAL_SUBDOMAIN]:-}" ]] || { warn "Portail : PORTAL_SUBDOMAIN vide, ignoré."; return 0; }
    [[ "$PORTAL_LOCAL_PORT" =~ ^[0-9]+$ ]] || die "PORTAL_LOCAL_PORT invalide : ${PORTAL_LOCAL_PORT}"
    case "${PORTAL_AUTH:-public}" in public|all|none) ;; *) die "PORTAL_AUTH doit valoir public, all ou none." ;; esac

    info "Portail : mise en place (pages, nginx, port local, DNS)..."
    info "Portail : génération de la page d'accueil ($(sd_fqdns PORTAL_SUBDOMAIN))..."
    local pw_was_empty=false
    [[ -n "${PORTAL_PASSWORD:-}" ]] || pw_was_empty=true
    portal_secrets
    if [[ "$pw_was_empty" == "true" && "$PORTAL_AUTH" != "none" ]]; then
        info "Portail : mot de passe généré pour ${PORTAL_USER} : ${PORTAL_PASSWORD}  (à noter ; PORTAL_PASSWORD dans le fichier de réponses pour le garder lors d'un prochain lancement)"
    fi

    local tmp script compose new_compose hash=""
    tmp="$(mktemp -d)"

    portal_html public > "${tmp}/portal-public.html"
    portal_html lan    > "${tmp}/portal-lan.html"
    portal_conf        > "${tmp}/portal.conf"

    if [[ "$PORTAL_AUTH" != "none" ]]; then
        hash="$(openssl passwd -apr1 "$PORTAL_PASSWORD")"
        printf '%s:%s\n' "$PORTAL_USER" "$hash" > "${tmp}/htpasswd"
    else
        : > "${tmp}/htpasswd"
    fi

    pct exec "$SWAG_ID" -- mkdir -p /opt/swag/config/www/portal /opt/swag/config/nginx/site-confs
    pct push "$SWAG_ID" "${tmp}/portal-public.html" /opt/swag/config/www/portal/portal-public.html
    pct push "$SWAG_ID" "${tmp}/portal-lan.html"    /opt/swag/config/www/portal/portal-lan.html
    pct push "$SWAG_ID" "${tmp}/portal.conf"        /opt/swag/config/nginx/site-confs/portal.conf
    pct push "$SWAG_ID" "${tmp}/htpasswd"           /opt/swag/config/nginx/.htpasswd-portal
    pct exec "$SWAG_ID" -- chmod 0644 /opt/swag/config/nginx/.htpasswd-portal
    rm -rf "$tmp"

    # Port d'accès local (secours sans DNS) dans le compose de SWAG
    compose="$(pct exec "$SWAG_ID" -- cat /opt/swag/docker-compose.yml 2>/dev/null || true)"
    if [[ -n "$compose" ]] && ! grep -q "\"${PORTAL_LOCAL_PORT}:${PORTAL_LOCAL_PORT}\"" <<< "$compose"; then
        new_compose="$(sed -E "s#^([[:space:]]*)- \"443:443\"#&\n\\1- \"${PORTAL_LOCAL_PORT}:${PORTAL_LOCAL_PORT}\"#" <<< "$compose")"
        if grep -q "\"${PORTAL_LOCAL_PORT}:${PORTAL_LOCAL_PORT}\"" <<< "$new_compose"; then
            tmp="$(mktemp)"
            printf '%s\n' "$new_compose" > "$tmp"
            pct exec "$SWAG_ID" -- cp -a /opt/swag/docker-compose.yml "/opt/swag/docker-compose.yml.bak.$(date +%s)"
            pct push "$SWAG_ID" "$tmp" /opt/swag/docker-compose.yml
            rm -f "$tmp"
            timeout 300 pct exec "$SWAG_ID" -- bash -c 'cd /opt/swag && docker compose up -d --force-recreate' \
                || warn "Portail : recréation de SWAG échouée (cd /opt/swag && docker compose up -d)."
        else
            warn "Portail : ligne \"443:443\" introuvable dans le compose de SWAG ; port local ${PORTAL_LOCAL_PORT} non ajouté."
        fi
    else
        pct exec "$SWAG_ID" -- bash -c 'docker exec swag nginx -t && docker exec swag nginx -s reload' \
            || warn "Portail : rechargement de nginx échoué (docker logs swag)."
    fi

    # Redirection de l'IP LAN de l'hôte vers le port local (LAN uniquement)
    add_dnat_forward "$PORTAL_LOCAL_PORT" "${SWAG_IP%%/*}" "$PORTAL_LOCAL_PORT"
    netfilter-persistent save >/dev/null 2>&1 || true

    # DNS : zone publique (home.<domaine>) et réécriture interne
    dns_zone_generate 2>/dev/null || true
    if [[ "${ENABLE_DNS:-false}" == "true" ]] && pct status "$DNS_ID" 2>/dev/null | grep -q running; then
        dns_configure || warn "Portail : réécritures DNS non mises à jour (./install.sh --run dns_configure)."
    fi

    info "Portail : https://$(sd_fqdns PORTAL_SUBDOMAIN | awk '{print $1}')  |  secours LAN : http://${LAN_IP}:${PORTAL_LOCAL_PORT}"
    return 0
}

portal_summary() {

    [[ "${ENABLE_PORTAL:-true}" == "true" && "${ENABLE_SWAG:-false}" == "true" ]] || return 0

    echo "PORTAIL (page d'accueil des services):"
    echo "  Adresse   : $(sd_fqdns PORTAL_SUBDOMAIN | sed 's#\([^ ]*\)#https://\1#g')  (enregistrement DNS A requis)"
    echo "  Secours   : http://${LAN_IP}:${PORTAL_LOCAL_PORT}  (réseau local, sans DNS)"
    case "${PORTAL_AUTH:-public}" in
        none)   echo "  Accès     : libre (PORTAL_AUTH=none)" ;;
        all)    echo "  Accès     : mot de passe partout : ${PORTAL_USER} / ${PORTAL_PASSWORD}" ;;
        *)      echo "  Accès     : libre en local, mot de passe depuis Internet : ${PORTAL_USER} / ${PORTAL_PASSWORD}" ;;
    esac
    echo "  Mise à jour : ./install.sh --run portal_apply  (après ajout/retrait d'un service)"
    echo
}

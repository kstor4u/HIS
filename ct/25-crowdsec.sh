###############################################################################
#                    CROWDSEC DEVANT SWAG (anti brute-force/scan)             #
###############################################################################

# Architecture
# ------------
#  - Dans le CT SWAG, un conteneur "crowdsec" (moteur + API locale) lit les journaux nginx de
#    SWAG (/opt/swag/config/log/nginx), détecte scans, brute-force, exploits web connus
#    (collections nginx, base-http-scenarios, http-cve) et décide des bannissements.
#  - SWAG charge le "bouncer" nginx (mod linuxserver swag-crowdsec) : les IP bannies reçoivent
#    un refus avant d'atteindre Nextcloud, Immich, etc. La liste communautaire de CrowdSec
#    (adresses malveillantes déjà vues ailleurs) est appliquée aussi.
#  - Tout est ajouté par un fichier docker-compose.override.yml à côté du compose de SWAG :
#    le compose d'origine et les fonctions de réparation de SWAG ne sont pas modifiés.
#  - Les réseaux LAN, privé et VPN sont en liste blanche (on ne se bannit pas soi-même).
#  - Outils : ./install.sh --run crowdsec_status | crowdsec_unban <ip> | crowdsec_ban <ip> [durée]

crowdsec_exec() {
    pct exec "$SWAG_ID" -- "$@"
}

configure_crowdsec() {

    [[ "$ENABLE_CROWDSEC" == "true" ]] || { info "CrowdSec : ENABLE_CROWDSEC=false, ignoré."; return 0; }
    [[ "$ENABLE_SWAG" == "true" ]] || die "CrowdSec protège SWAG : ENABLE_SWAG doit être actif."
    pct status "$SWAG_ID" >/dev/null 2>&1 || die "CT SWAG ${SWAG_ID} introuvable."

    info "CrowdSec : installation dans le CT SWAG ${SWAG_ID}..."

    local WORK
    WORK="$(mktemp -d)"

    cat > "${WORK}/acquis.yaml" <<'EOF'
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
EOF

    {
        echo 'name: homelab/whitelist'
        echo 'description: "Réseaux du homelab : jamais bannis"'
        echo 'whitelist:'
        echo '  reason: "réseaux du homelab"'
        echo '  cidr:'
        local c
        for c in 127.0.0.0/8 "$LAN_NET" "$PRIVATE_NET" "$WG_NET" ${CROWDSEC_WHITELIST:-}; do
            echo "    - \"${c}\""
        done
    } > "${WORK}/whitelist.yaml"

    # Étape 1 : le moteur seul (sans clé de bouncer) pour pouvoir en créer une.
    cat > "${WORK}/override-engine.yml" <<EOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/nginx crowdsecurity/base-http-scenarios crowdsecurity/http-cve
      - TZ=Europe/Paris
    volumes:
      - /opt/swag/crowdsec/acquis.yaml:/etc/crowdsec/acquis.yaml:ro
      - /opt/swag/crowdsec/whitelist.yaml:/etc/crowdsec/parsers/s02-enrich/homelab-whitelist.yaml:ro
      - crowdsec_config:/etc/crowdsec
      - crowdsec_data:/var/lib/crowdsec/data
      - /opt/swag/config/log/nginx:/var/log/nginx:ro

volumes:
  crowdsec_config:
  crowdsec_data:
EOF

    crowdsec_exec mkdir -p /opt/swag/crowdsec
    pct push "$SWAG_ID" "${WORK}/acquis.yaml"        /opt/swag/crowdsec/acquis.yaml
    pct push "$SWAG_ID" "${WORK}/whitelist.yaml"     /opt/swag/crowdsec/whitelist.yaml
    pct push "$SWAG_ID" "${WORK}/override-engine.yml" /opt/swag/docker-compose.override.yml

    info "CrowdSec : démarrage du moteur (téléchargement de l'image et des collections)..."
    crowdsec_exec bash -c "cd /opt/swag && docker compose up -d crowdsec" >/dev/null \
        || die "CrowdSec : démarrage du moteur impossible (pct exec ${SWAG_ID} -- docker logs crowdsec)."

    local attempt ready=false
    for attempt in $(seq 1 40); do
        if crowdsec_exec docker exec crowdsec cscli lapi status >/dev/null 2>&1; then ready=true; break; fi
        sleep 4
    done
    [[ "$ready" == "true" ]] || die "CrowdSec : l'API locale ne répond pas (pct exec ${SWAG_ID} -- docker logs crowdsec)."

    # Étape 2 : clé du bouncer (recréée à chaque exécution : elle n'est affichée qu'à la création).
    local key
    crowdsec_exec docker exec crowdsec cscli bouncers delete swag-bouncer >/dev/null 2>&1 || true
    key="$(crowdsec_exec docker exec crowdsec cscli bouncers add swag-bouncer -o raw 2>/dev/null | tail -n 1 | tr -d '\r\n ')"
    [[ -n "$key" ]] || die "CrowdSec : clé de bouncer non obtenue (cscli bouncers add)."

    # Étape 3 : fichier override complet (moteur + bouncer dans SWAG).
    {
        cat "${WORK}/override-engine.yml" | sed '/^volumes:/,$d'
        cat <<EOF
  swag:
    environment:
      - DOCKER_MODS=linuxserver/mods:swag-crowdsec
      - CROWDSEC_API_KEY=${key}
      - CROWDSEC_LAPI_URL=http://crowdsec:8080
    depends_on:
      - crowdsec

volumes:
  crowdsec_config:
  crowdsec_data:
EOF
    } > "${WORK}/override.yml"

    pct push "$SWAG_ID" "${WORK}/override.yml" /opt/swag/docker-compose.override.yml --perms 0600
    rm -rf "$WORK"

    info "CrowdSec : (re)démarrage de SWAG avec le bouncer..."
    crowdsec_exec bash -c "cd /opt/swag && docker compose up -d" >/dev/null || die "CrowdSec : redémarrage de SWAG impossible."

    sleep 25
    crowdsec_wire_nginx
    verify_crowdsec
}

# Vérifie que nginx charge bien le bouncer ; ajoute l'include s'il manque et que la conf existe.
crowdsec_wire_nginx() {

    local have_conf have_inc

    have_conf="$(crowdsec_exec bash -c "[ -f /opt/swag/config/nginx/crowdsec_nginx.conf ] && echo yes" 2>/dev/null || true)"
    have_inc="$(crowdsec_exec bash -c "grep -rl crowdsec /opt/swag/config/nginx/nginx.conf /opt/swag/config/nginx/site-confs 2>/dev/null | head -n 1" || true)"

    if [[ "$have_conf" != "yes" ]]; then
        warn "CrowdSec : /config/nginx/crowdsec_nginx.conf absent : le mod SWAG n'a pas (encore) installé le bouncer. Voir : pct exec ${SWAG_ID} -- docker logs swag | grep -i crowdsec"
        return 0
    fi

    if [[ -n "$have_inc" ]]; then
        info "CrowdSec : le bouncer est inclus dans la configuration nginx."
        return 0
    fi

    info "CrowdSec : include du bouncer absent de nginx.conf, ajout..."
    crowdsec_exec bash -c '
        cd /opt/swag/config/nginx
        cp -a nginx.conf nginx.conf.bak.crowdsec
        sed -i "0,/^http {/s//http {\n    include \/config\/nginx\/crowdsec_nginx.conf;/" nginx.conf
        if docker exec swag nginx -t >/dev/null 2>&1; then
            docker exec swag nginx -s reload
            echo ok
        else
            mv nginx.conf.bak.crowdsec nginx.conf
            echo revert
        fi' | grep -q ok \
        && info "CrowdSec : include ajouté, nginx rechargé." \
        || warn "CrowdSec : nginx -t a refusé l'include : nginx.conf restauré. Consulte la documentation du mod swag-crowdsec."
}

verify_crowdsec() {

    local out attempt

    for attempt in $(seq 1 12); do
        out="$(crowdsec_exec docker exec crowdsec cscli bouncers list -o raw 2>/dev/null | grep swag-bouncer || true)"
        # Colonnes : name, ip, valid, last_pull, type, version, auth_type
        if [[ -n "$out" && "$(cut -d, -f4 <<< "$out")" != "" ]]; then
            info "CrowdSec : le bouncer de SWAG interroge l'API (${out%%,*})."
            return 0
        fi
        sleep 5
    done

    warn "CrowdSec : le bouncer de SWAG ne s'est pas encore connecté. Diagnostic : ./install.sh --run crowdsec_status ; pct exec ${SWAG_ID} -- docker logs swag | grep -i crowdsec"
    return 0
}

# ./install.sh --run crowdsec_status
crowdsec_status() {

    echo "--- Bouncers"
    crowdsec_exec docker exec crowdsec cscli bouncers list || true
    echo "--- Décisions actives (bannissements)"
    crowdsec_exec docker exec crowdsec cscli decisions list || true
    echo "--- Alertes récentes"
    crowdsec_exec docker exec crowdsec cscli alerts list --limit 10 || true
    echo "--- Sources de journaux lues"
    crowdsec_exec docker exec crowdsec cscli metrics show acquisition || true
}

# ./install.sh --run crowdsec_unban <ip>
crowdsec_unban() {
    [[ -n "${1:-}" ]] || die "usage : crowdsec_unban <ip>"
    crowdsec_exec docker exec crowdsec cscli decisions delete --ip "$1"
}

# ./install.sh --run crowdsec_ban <ip> [durée, ex. 24h]
crowdsec_ban() {
    [[ -n "${1:-}" ]] || die "usage : crowdsec_ban <ip> [durée]"
    crowdsec_exec docker exec crowdsec cscli decisions add --ip "$1" --duration "${2:-24h}" --reason "manuel"
}

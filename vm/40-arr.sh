###############################################################################
#     SONARR / RADARR / PROWLARR + QBITTORRENT (derrière un VPN) — VM DOCKER  #
###############################################################################

# Architecture
# ------------
#  - Projet Docker Compose séparé (/opt/apps/arr dans la VM DOCKER), déployé par
#    deploy_arr_stack : fonctionne aussi sur une VM déjà installée (le cloud-init n'est
#    jamais rejoué), et ne touche à aucune autre application.
#  - Prowlarr gère les indexeurs et les pousse vers Sonarr (séries) et Radarr (films) ;
#    ceux-ci envoient les téléchargements à qBittorrent, puis importent (lien physique,
#    donc sans doublon) dans la bibliothèque que Jellyfin lit déjà :
#        ${SHARED}/Movies/Series      <- Sonarr   (dossier racine /data/Movies/Series)
#        ${SHARED}/Movies/Movies      <- Radarr   (dossier racine /data/Movies/Movies)
#        ${SHARED}/Movies/Downloaded  <- téléchargements (torrents/, incomplete/)
#    Tout est sur le même système de fichiers (SHARED) : les liens physiques fonctionnent.
#  - qBittorrent n'a AUCUN accès à Internet hors VPN : il partage le réseau d'un conteneur
#    gluetun (client WireGuard avec coupe-circuit). Fournis le fichier .conf WireGuard de
#    ton fournisseur (ARR_VPN_WG_CONF). Sans fichier, qBittorrent n'est PAS démarré
#    (sauf si tu choisis explicitement ARR_VPN=false : ton IP réelle serait alors visible).
#  - Interfaces réservées au LAN (ports redirigés depuis l'IP LAN de l'hôte, jamais depuis la
#    box) : à la première visite, Sonarr/Radarr/Prowlarr demandent de créer un compte.
#  - Prowlarr ne contient aucun indexeur : à toi d'ajouter ceux que tu es en droit d'utiliser.
#  - Configurations : /opt/apps/arr/<service> dans la VM (cible "arr" du dump avant sauvegarde).

arr_vm_dir="/opt/apps/arr"

arr_gluetun_enabled() { [[ "$ARR_VPN" == "true" ]]; }

# Mot de passe de qBittorrent : variable, sinon .env existant de la VM, sinon généré.
arr_qbit_password() {

    local pw="$ARR_QBIT_PASSWORD"

    if [[ -z "$pw" ]]; then
        pw="$(vm_read_file "$DOCKER_ID" "${arr_vm_dir}/.env" 2>/dev/null | sed -n 's/^QBIT_PASSWORD=//p' | head -n 1)"
    fi
    if [[ -z "$pw" ]]; then
        pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')"
    fi

    ARR_QBIT_PASSWORD="$pw"
}

# "@ByteArray(sel:hash)" attendu par qBittorrent (PBKDF2-HMAC-SHA512, 100000 itérations).
arr_qbit_hash() {

    python3 - "$1" <<'PY'
import base64, hashlib, os, sys
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha512", sys.argv[1].encode(), salt, 100000, dklen=64)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
PY
}

arr_compose_text() {

    local qb_on="$1"   # true = inclure qBittorrent (et gluetun)
    local shared="$DOCKER_SHARED_MOUNT"

    echo "name: arr"
    echo "services:"

    if [[ "$qb_on" == "true" ]]; then

        if arr_gluetun_enabled; then
            cat <<EOF
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - TZ=Europe/Paris
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - FIREWALL_OUTBOUND_SUBNETS=${LAN_NET},${PRIVATE_NET}
    volumes:
      - ${arr_vm_dir}/gluetun:/gluetun
    ports:
      - "${QBIT_PORT}:${QBIT_PORT}"

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    environment:
      - PUID=${ARR_PUID}
      - PGID=${ARR_PGID}
      - UMASK=002
      - TZ=Europe/Paris
      - WEBUI_PORT=${QBIT_PORT}
    volumes:
      - ${arr_vm_dir}/qbittorrent:/config
      - ${shared}:/data

EOF
        else
            cat <<EOF
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      - PUID=${ARR_PUID}
      - PGID=${ARR_PGID}
      - UMASK=002
      - TZ=Europe/Paris
      - WEBUI_PORT=${QBIT_PORT}
    volumes:
      - ${arr_vm_dir}/qbittorrent:/config
      - ${shared}:/data
    ports:
      - "${QBIT_PORT}:${QBIT_PORT}"
      - "6881:6881"
      - "6881:6881/udp"

EOF
        fi
    fi

    local svc port
    for entry in "prowlarr:${PROWLARR_PORT}:9696" "sonarr:${SONARR_PORT}:8989" "radarr:${RADARR_PORT}:7878"; do
        IFS=: read -r svc port inner <<< "$entry"
        cat <<EOF
  ${svc}:
    image: lscr.io/linuxserver/${svc}:latest
    container_name: ${svc}
    restart: unless-stopped
    environment:
      - PUID=${ARR_PUID}
      - PGID=${ARR_PGID}
      - UMASK=002
      - TZ=Europe/Paris
    volumes:
      - ${arr_vm_dir}/${svc}:/config
EOF
        [[ "$svc" != "prowlarr" ]] && echo "      - ${shared}:/data"
        cat <<EOF
    ports:
      - "${port}:${inner}"

EOF
    done
}

# Prépare les dossiers de l'hôte (même système de fichiers : liens physiques).
arr_prepare_host_dirs() {

    local d
    for d in "Movies/Series" "Movies/Movies" "Movies/Downloaded/torrents" "Movies/Downloaded/incomplete"; do
        mkdir -p "${SHARED_DIR}/${d}"
    done

    if getent group "$SHARED_GROUP" >/dev/null 2>&1; then
        chgrp -R "$SHARED_GROUP" "${SHARED_DIR}/Movies/Downloaded" 2>/dev/null || true
        chmod -R g+rwX "${SHARED_DIR}/Movies/Downloaded" 2>/dev/null || true
        find "${SHARED_DIR}/Movies/Downloaded" -type d -exec chmod g+s {} + 2>/dev/null || true
    fi
}

deploy_arr_stack() {

    [[ "$ENABLE_ARR" == "true" ]] || { info "ARR : ENABLE_ARR=false, ignoré."; return 0; }
    [[ "$ENABLE_DOCKER" == "true" ]] || die "ARR tourne dans la VM DOCKER : ENABLE_DOCKER doit être actif."
    qm status "$DOCKER_ID" 2>/dev/null | grep -q running || die "La VM DOCKER ${DOCKER_ID} n'est pas démarrée."
    wait_for_qemu_agent "$DOCKER_ID" 30 || die "Agent QEMU de la VM ${DOCKER_ID} injoignable."

    vm_run "$DOCKER_ID" 30 "mountpoint -q '${DOCKER_SHARED_MOUNT}' && echo ok" | grep -q ok \
        || die "${DOCKER_SHARED_MOUNT} n'est pas monté dans la VM ${DOCKER_ID} (SHARED indisponible)."

    info "ARR : préparation des dossiers dans SHARED (Movies/Series, Movies/Movies, Movies/Downloaded)..."
    arr_prepare_host_dirs

    local qb_on=true
    if arr_gluetun_enabled && { [[ -z "$ARR_VPN_WG_CONF" ]] || [[ ! -f "$ARR_VPN_WG_CONF" ]]; }; then
        warn "ARR : ARR_VPN=true mais ARR_VPN_WG_CONF ('${ARR_VPN_WG_CONF}') n'est pas un fichier : qBittorrent N'EST PAS installé."
        warn "ARR : fournis le .conf WireGuard de ton VPN (ex. UnlimitedVPN) puis relance  ./install.sh --run deploy_arr_stack  (ou ARR_VPN=false pour assumer l'absence de VPN)."
        qb_on=false
    fi

    arr_qbit_password

    info "ARR : écriture de la configuration dans la VM ${DOCKER_ID} (${arr_vm_dir})..."

    vm_run "$DOCKER_ID" 30 "mkdir -p '${arr_vm_dir}'/{prowlarr,sonarr,radarr,qbittorrent/qBittorrent,gluetun/wireguard}; chmod 700 '${arr_vm_dir}'" >/dev/null

    vm_write_file "$DOCKER_ID" "${arr_vm_dir}/docker-compose.yml" 0600 "$(arr_compose_text "$qb_on")"
    vm_write_file "$DOCKER_ID" "${arr_vm_dir}/.env" 0600 "$(printf 'QBIT_USER=%s\nQBIT_PASSWORD=%s\n' "$ARR_QBIT_USER" "$ARR_QBIT_PASSWORD")"

    if [[ "$qb_on" == "true" ]]; then

        # Configuration initiale de qBittorrent (jamais écrasée : tes réglages priment).
        if [[ -z "$(vm_read_file "$DOCKER_ID" "${arr_vm_dir}/qbittorrent/qBittorrent/qBittorrent.conf")" ]]; then
            vm_write_file "$DOCKER_ID" "${arr_vm_dir}/qbittorrent/qBittorrent/qBittorrent.conf" 0600 "$(cat <<EOF
[LegalNotice]
Accepted=true

[Preferences]
Downloads\\SavePath=/data/Movies/Downloaded/torrents/
Downloads\\TempPath=/data/Movies/Downloaded/incomplete/
Downloads\\TempPathEnabled=true
WebUI\\Address=*
WebUI\\Port=${QBIT_PORT}
WebUI\\Username=${ARR_QBIT_USER}
WebUI\\Password_PBKDF2="$(arr_qbit_hash "$ARR_QBIT_PASSWORD")"
WebUI\\LocalHostAuth=false
WebUI\\HostHeaderValidation=false
WebUI\\CSRFProtection=false
EOF
)"
        fi

        if arr_gluetun_enabled; then
            vm_write_file "$DOCKER_ID" "${arr_vm_dir}/gluetun/wireguard/wg0.conf" 0600 "$(cat "$ARR_VPN_WG_CONF")"
        fi
    fi

    info "ARR : démarrage (téléchargement des images)..."
    if ! timeout 1800 qm guest exec "$DOCKER_ID" --timeout 1800 -- bash -c "cd '${arr_vm_dir}' && docker compose up -d" >/dev/null; then
        warn "ARR : échec du démarrage. Diagnostic : qm guest exec ${DOCKER_ID} -- bash -c 'cd ${arr_vm_dir} && docker compose ps && docker compose logs --tail 30'"
        return 0
    fi

    arr_wire_services "$qb_on"
    verify_arr "$qb_on"
}

# Relie Prowlarr -> Sonarr/Radarr et Sonarr/Radarr -> qBittorrent, par les API (schémas lus
# auprès des applications : robuste aux changements de champs). Idempotent.
arr_wire_services() {

    local qb_on="$1" ip="${DOCKER_IP%%/*}" svc key
    local sk rk pk

    info "ARR : attente des API (premier démarrage : quelques minutes)..."

    local -A keys=()
    for svc in sonarr radarr prowlarr; do
        local attempt
        for attempt in $(seq 1 40); do
            key="$(vm_read_file "$DOCKER_ID" "${arr_vm_dir}/${svc}/config.xml" | sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' | head -n 1)"
            [[ -n "$key" ]] && break
            sleep 5
        done
        [[ -n "$key" ]] || { warn "ARR : clé API de ${svc} introuvable : câblage automatique ignoré (à faire dans l'interface)."; return 0; }
        keys[$svc]="$key"
    done

    ARR_HOST="$ip" ARR_SONARR_PORT="$SONARR_PORT" ARR_RADARR_PORT="$RADARR_PORT" ARR_PROWLARR_PORT="$PROWLARR_PORT" \
    ARR_SONARR_KEY="${keys[sonarr]}" ARR_RADARR_KEY="${keys[radarr]}" ARR_PROWLARR_KEY="${keys[prowlarr]}" \
    ARR_QB_ON="$qb_on" ARR_QB_HOST="$(arr_gluetun_enabled && echo gluetun || echo qbittorrent)" ARR_QB_PORT="$QBIT_PORT" \
    ARR_QB_USER="$ARR_QBIT_USER" ARR_QB_PASS="$ARR_QBIT_PASSWORD" \
    ARR_TV_ROOT="/data/Movies/Series" ARR_MOVIE_ROOT="/data/Movies/Movies" \
    ARR_SONARR_PORT_INT=8989 ARR_RADARR_PORT_INT=7878 ARR_PROWLARR_PORT_INT=9696 \
        python3 - <<'PY' || warn "ARR : le câblage automatique a échoué en partie : termine dans les interfaces (Prowlarr > Paramètres > Applications ; Sonarr/Radarr > Clients de téléchargement)."
import json, os, sys, time, urllib.error, urllib.request

E = os.environ
ok_all = True

def call(method, base, path, key, body=None, retries=1):
    url = "http://%s:%s%s" % (E["ARR_HOST"], base, path)
    data = json.dumps(body).encode() if body is not None else None
    for i in range(retries):
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"X-Api-Key": key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if i == retries - 1:
                raise RuntimeError("%s %s -> HTTP %s %s" % (method, path, e.code, detail))
        except Exception as e:
            if i == retries - 1:
                raise RuntimeError("%s %s -> %s" % (method, path, e))
        time.sleep(5)

def wait_api(port, ver, key):
    for _ in range(60):
        try:
            call("GET", port, "/api/%s/system/status" % ver, key)
            return True
        except Exception:
            time.sleep(5)
    return False

def fill(item, values):
    for f in item.get("fields", []):
        if f["name"] in values:
            f["value"] = values[f["name"]]

def say(msg):
    print("ARR : " + msg)

apps = {
    "sonarr":   (E["ARR_SONARR_PORT"],   "v3", E["ARR_SONARR_KEY"],   "tvCategory",    E["ARR_TV_ROOT"],    "sonarr"),
    "radarr":   (E["ARR_RADARR_PORT"],   "v3", E["ARR_RADARR_KEY"],   "movieCategory", E["ARR_MOVIE_ROOT"], "radarr"),
}
prowlarr = (E["ARR_PROWLARR_PORT"], "v1", E["ARR_PROWLARR_KEY"])

for name, (port, ver, key, catfield, root, cat) in apps.items():
    try:
        if not wait_api(port, ver, key):
            raise RuntimeError("API injoignable")

        roots = call("GET", port, "/api/v3/rootfolder", key)
        if not any(r.get("path", "").rstrip("/") == root.rstrip("/") for r in roots):
            call("POST", port, "/api/v3/rootfolder", key, {"path": root})
            say("%s : dossier racine %s ajouté" % (name, root))

        if E["ARR_QB_ON"] == "true":
            clients = call("GET", port, "/api/v3/downloadclient", key)
            if any(c.get("implementation") == "QBittorrent" for c in clients):
                say("%s : client qBittorrent déjà présent" % name)
            else:
                schema = call("GET", port, "/api/v3/downloadclient/schema", key)
                tpl = next(s for s in schema if s.get("implementation") == "QBittorrent")
                tpl["name"] = "qBittorrent"
                tpl["enable"] = True
                fill(tpl, {"host": E["ARR_QB_HOST"], "port": int(E["ARR_QB_PORT"]), "useSsl": False,
                           "username": E["ARR_QB_USER"], "password": E["ARR_QB_PASS"], catfield: cat})
                try:
                    call("POST", port, "/api/v3/downloadclient", key, tpl)
                except RuntimeError:
                    call("POST", port, "/api/v3/downloadclient?forceSave=true", key, tpl)
                say("%s : client qBittorrent ajouté (%s:%s)" % (name, E["ARR_QB_HOST"], E["ARR_QB_PORT"]))
    except Exception as e:
        ok_all = False
        say("%s : %s" % (name, e))

try:
    port, ver, key = prowlarr
    if not wait_api(port, ver, key):
        raise RuntimeError("API Prowlarr injoignable")
    existing = {a.get("implementation") for a in call("GET", port, "/api/v1/applications", key)}
    schema = call("GET", port, "/api/v1/applications/schema", key)
    for impl, base_port, apikey in (("Sonarr", E["ARR_SONARR_PORT_INT"], E["ARR_SONARR_KEY"]),
                                    ("Radarr", E["ARR_RADARR_PORT_INT"], E["ARR_RADARR_KEY"])):
        if impl in existing:
            say("Prowlarr : application %s déjà présente" % impl)
            continue
        tpl = next(s for s in schema if s.get("implementation") == impl)
        tpl["name"] = impl
        tpl["syncLevel"] = "fullSync"
        fill(tpl, {"prowlarrUrl": "http://prowlarr:%s" % E["ARR_PROWLARR_PORT_INT"],
                   "baseUrl": "http://%s:%s" % (impl.lower(), base_port), "apiKey": apikey})
        try:
            call("POST", port, "/api/v1/applications", key, tpl)
        except RuntimeError:
            call("POST", port, "/api/v1/applications?forceSave=true", key, tpl)
        say("Prowlarr : application %s ajoutée" % impl)
except Exception as e:
    ok_all = False
    say("Prowlarr : %s" % e)

sys.exit(0 if ok_all else 1)
PY
}

verify_arr() {

    local qb_on="$1" ip="${DOCKER_IP%%/*}" attempt code name port path

    for entry in "Sonarr:${SONARR_PORT}:/ping" "Radarr:${RADARR_PORT}:/ping" "Prowlarr:${PROWLARR_PORT}:/ping"; do
        IFS=: read -r name port path <<< "$entry"
        code=""
        for attempt in $(seq 1 12); do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${port}${path}" || true)"
            [[ "$code" == "200" ]] && break
            sleep 5
        done
        [[ "$code" == "200" ]] && info "ARR : ${name} répond." || warn "ARR : ${name} ne répond pas (dernier code : ${code:-aucun})."
    done

    if [[ "$qb_on" == "true" ]]; then
        code=""
        for attempt in $(seq 1 18); do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${QBIT_PORT}/" || true)"
            [[ "$code" =~ ^(200|401|403)$ ]] && break
            sleep 5
        done
        [[ "$code" =~ ^(200|401|403)$ ]] && info "ARR : qBittorrent répond." || warn "ARR : qBittorrent ne répond pas (VPN non établi ? ./install.sh --run arr_vpn_check)."

        if arr_gluetun_enabled; then
            arr_vpn_check || true
        fi
    fi
}

# Affiche l'IP publique vue par qBittorrent : doit être celle du VPN, PAS ta ligne.
arr_vpn_check() {

    local vpn_ip home_ip

    vpn_ip="$(vm_run "$DOCKER_ID" 60 "docker exec gluetun wget -qO- --timeout=15 https://api.ipify.org 2>/dev/null" | tr -d '\r\n ')"
    home_ip="$(curl -s4 --max-time 10 https://api.ipify.org || true)"

    if [[ -z "$vpn_ip" ]]; then
        warn "ARR : le VPN n'est pas établi (gluetun sans adresse publique) : qBittorrent n'a pas d'accès Internet (coupe-circuit). Journaux : ./install.sh --run arr_logs gluetun"
        return 1
    fi

    if [[ -n "$home_ip" && "$vpn_ip" == "$home_ip" ]]; then
        warn "ARR : ATTENTION, l'IP vue par le conteneur VPN (${vpn_ip}) est celle de ta ligne : le tunnel ne protège pas."
        return 1
    fi

    info "ARR : VPN actif, IP publique de qBittorrent = ${vpn_ip} (ta ligne : ${home_ip:-inconnue})."
}

arr_status() {
    vm_run "$DOCKER_ID" 60 "cd '${arr_vm_dir}' && docker compose ps"
}

# ./install.sh --run arr_logs [service]
arr_logs() {
    vm_run "$DOCKER_ID" 60 "cd '${arr_vm_dir}' && docker compose logs --tail 40 ${1:-}"
}

# Réaffiche l'identifiant qBittorrent.
arr_credentials() {
    arr_qbit_password
    echo "qBittorrent : http://${LAN_IP}:${QBIT_PORT}   utilisateur ${ARR_QBIT_USER}   mot de passe ${ARR_QBIT_PASSWORD}"
}

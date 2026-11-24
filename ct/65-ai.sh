###############################################################################
#        IA LOCALE : Ollama + Open WebUI (GPU NVIDIA) + OCR + normes (RAG)      #
###############################################################################

# CT LXC « ia » (par défaut 111) :
#   - Ollama (modèles de discussion, de code, d'embedding) sur le GPU de l'hôte : le pilote NVIDIA est installé
#     sur l'hôte Proxmox, les périphériques /dev/nvidia* sont passés au CT (le GPU reste donc partageable, pas de
#     passthrough VFIO ni de VM dédiée) ;
#   - Open WebUI (interface web, bases de connaissances = documents interrogeables avec citations) ;
#   - OCR (ocrmypdf, français) des PDF déposés dans AI_DOCS_DIR (ex. normes scannées), puis envoi automatique dans la
#     base de connaissances « Normes » d'Open WebUI ;
#   - un fichier de configuration pour l'extension VS Code « Continue » (SHARED/IA/continue-config.yaml).
#
# Activation « intelligente » : ai_preflight (appelée avant toute création) compare la RAM prévue de tous les
# modules activés à celle de l'hôte, réduit la RAM de l'IA si besoin (ou refuse), limite XMRig, bride le
# machine-learning d'Immich (CPU) et choisit les modèles selon la VRAM réelle.

AI_GPU_ON=false
AI_NEEDS_REBOOT=false

ai_host_mem_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

# RAM (Mo) prévue pour les autres modules activés.
ai_planned_ram() {
    local t=0
    [[ "${ENABLE_FILES:-false}"      == "true" ]] && t=$((t + FILES_MEMORY))
    [[ "${ENABLE_DOCKER:-false}"     == "true" ]] && t=$((t + DOCKER_MEMORY))
    [[ "${ENABLE_SWAG:-false}"       == "true" ]] && t=$((t + SWAG_MEMORY))
    [[ "${ENABLE_WIREGUARD:-false}"  == "true" ]] && t=$((t + WG_MEMORY))
    [[ "${ENABLE_NODE:-false}"       == "true" ]] && t=$((t + NODE_MEMORY))
    [[ "${ENABLE_MAIL:-false}"       == "true" ]] && t=$((t + MAIL_MEMORY))
    [[ "${ENABLE_DNS:-false}"        == "true" ]] && t=$((t + DNS_MEMORY))
    [[ "${ENABLE_MONITOR:-false}"    == "true" ]] && t=$((t + MONITOR_MEMORY))
    [[ "${ENABLE_XMRIG:-false}"      == "true" ]] && t=$((t + XMRIG_MEMORY))
    printf '%d' "$t"
}

ai_gpu_present() { lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -qi nvidia; }

# VRAM de la première carte (Mo), vide si le pilote n'est pas chargé.
ai_vram_mb() { nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9'; }

# Contrôles et ajustements AVANT toute création (voir l'en-tête). Appelée par main si ENABLE_AI=true.
ai_preflight() {

    info "IA : contrôle de compatibilité avec les autres modules..."

    [[ "$AI_NVIDIA_SOURCE" == "debian" || "$AI_NVIDIA_SOURCE" == "run" ]] || die "AI_NVIDIA_SOURCE doit valoir debian ou run."
    [[ "$AI_NVIDIA_SOURCE" != "run" || -n "$AI_NVIDIA_VERSION" ]] || die "AI_NVIDIA_SOURCE=run demande AI_NVIDIA_VERSION (ex. 580.95.05)."
    [[ "$AI_WEB_PORT" =~ ^[0-9]+$ && "$AI_API_PORT" =~ ^[0-9]+$ ]] || die "AI_WEB_PORT / AI_API_PORT invalides."
    [[ "$AI_MEMORY" =~ ^[0-9]+$ && "$AI_CORES" =~ ^[0-9]+$ ]] || die "AI_MEMORY / AI_CORES invalides."

    # 1) GPU
    AI_GPU_ON=false
    case "$AI_GPU" in
        true)  ai_gpu_present || die "AI_GPU=true mais aucune carte NVIDIA détectée (lspci). Mets AI_GPU=auto ou false."; AI_GPU_ON=true ;;
        false) ;;
        auto)  ai_gpu_present && AI_GPU_ON=true ;;
        *)     die "AI_GPU doit valoir auto, true ou false." ;;
    esac
    if [[ "$AI_GPU_ON" == "true" ]]; then
        info "  GPU NVIDIA détecté : IA sur GPU."
    else
        warn "  Pas de GPU utilisé : l'IA tournera sur le processeur (très lent au-delà de 7 milliards de paramètres)."
    fi

    # 2) RAM : somme des modules actifs + IA <= RAM de l'hôte - marge
    local total others avail
    total="$(ai_host_mem_mb)"
    others="$(ai_planned_ram)"
    avail=$((total - AI_RAM_RESERVE - others))

    info "  RAM hôte ${total} Mo | autres modules ${others} Mo | marge hôte ${AI_RAM_RESERVE} Mo | disponible pour l'IA ${avail} Mo"

    if (( AI_MEMORY > avail )); then
        if (( avail >= 8192 )); then
            warn "  AI_MEMORY ${AI_MEMORY} Mo > disponible : réduit à ${avail} Mo."
            AI_MEMORY="$avail"
        elif [[ "$AI_FORCE" == "true" ]]; then
            warn "  RAM insuffisante pour l'IA (${avail} Mo disponibles) : AI_FORCE=true, installation maintenue (risque de swap/OOM)."
        else
            die "RAM insuffisante : il ne reste que ${avail} Mo pour l'IA (minimum 8192). Désactive un module (XMRIG, MAIL, NODE...), réduis leur *_MEMORY, ajoute de la RAM, ou mets AI_FORCE=true."
        fi
    fi

    # 3) CPU : XMRig ne doit pas affamer l'IA
    local nc
    nc="$(nproc)"
    if [[ "${ENABLE_XMRIG:-false}" == "true" ]]; then
        local max_x=$((nc - AI_CORES - 1))
        (( max_x >= 1 )) || max_x=1
        if (( XMRIG_CORES > max_x )); then
            warn "  XMRig et IA activés ensemble : XMRIG_CORES ramené de ${XMRIG_CORES} à ${max_x} (l'IA garde ${AI_CORES} cœurs)."
            XMRIG_CORES="$max_x"
        fi
        warn "  Conseil : le minage ralentit l'IA (CPU, RAM, chaleur). Désactive ENABLE_XMRIG si le serveur sert surtout à l'IA."
    fi
    (( AI_CORES <= nc )) || { warn "  AI_CORES ${AI_CORES} > ${nc} cœurs : ramené à ${nc}."; AI_CORES="$nc"; }

    # 4) Immich : son machine-learning tourne sur le CPU de la VM Docker (jamais sur le GPU) ; on le bride.
    if [[ "${ENABLE_IMMICH:-false}" == "true" && "${ENABLE_DOCKER:-false}" == "true" ]]; then
        info "  Immich + IA : le machine-learning d'Immich reste sur le CPU (VM Docker) avec 1 worker et déchargement rapide des modèles ; le GPU est réservé à l'IA."
    fi

    # 5) Un seul usage du GPU
    if [[ "$AI_GPU_ON" == "true" && "${ENABLE_XMRIG:-false}" == "true" ]]; then
        info "  Le minage XMRig utilise le CPU uniquement : pas de conflit de GPU."
    fi

    [[ -n "$AI_WEBUI_EMAIL" ]] || AI_WEBUI_EMAIL="${LE_EMAIL:-admin@example.com}"
    [[ -n "$AI_WEBUI_PASSWORD" ]] || AI_WEBUI_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    [[ -n "$AI_WEBUI_PASSWORD" ]] || die "Échec de génération du mot de passe Open WebUI."
    return 0
}

# Affiche le budget RAM (utilisable seul : ./install.sh --run ai_budget)
ai_budget() {
    local total others
    total="$(ai_host_mem_mb)"; others="$(ai_planned_ram)"
    echo "RAM hôte            : ${total} Mo"
    echo "Marge hôte          : ${AI_RAM_RESERVE} Mo"
    echo "Autres modules actifs : ${others} Mo"
    echo "IA (AI_MEMORY)      : ${AI_MEMORY} Mo"
    echo "Reste               : $((total - AI_RAM_RESERVE - others - AI_MEMORY)) Mo"
    echo "VRAM GPU            : $(ai_vram_mb || true) Mo"
}

# Bloc d'environnement du machine-learning d'Immich (10 espaces d'indentation) : appelé par vm/30-docker.sh.
immich_ml_env() {
    [[ "${ENABLE_AI:-false}" == "true" ]] || return 0
    printf '          environment:\n'
    printf '            - MACHINE_LEARNING_WORKERS=1\n'
    printf '            - MACHINE_LEARNING_MODEL_TTL=60\n'
    printf '            - MACHINE_LEARNING_REQUEST_THREADS=2\n'
}

###############################################################################
#                           PILOTE NVIDIA (HÔTE)                              #
###############################################################################

# Installe le pilote NVIDIA sur l'hôte Proxmox si nécessaire. Un redémarrage est presque toujours requis
# la première fois : la fin de l'installation continue (le CT est créé), puis
#   reboot  +  ./install.sh --run ai_gpu_attach
ai_host_gpu_setup() {

    [[ "$AI_GPU_ON" == "true" ]] || return 0

    if nvidia-smi -L >/dev/null 2>&1; then
        info "IA : pilote NVIDIA déjà actif sur l'hôte ($(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1))."
        return 0
    fi

    info "IA : installation du pilote NVIDIA sur l'hôte (source : ${AI_NVIDIA_SOURCE})..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get install -y build-essential dkms pciutils >/dev/null 2>&1 || true
    apt-get install -y "proxmox-headers-$(uname -r)" >/dev/null 2>&1 \
        || apt-get install -y "pve-headers-$(uname -r)" >/dev/null 2>&1 \
        || warn "IA : en-têtes du noyau $(uname -r) introuvables (apt search headers) : la compilation du pilote échouera."

    printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/homelab-blacklist-nouveau.conf

    if [[ "$AI_NVIDIA_SOURCE" == "debian" ]]; then

        if ! grep -rqs "non-free" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            cat > /etc/apt/sources.list.d/homelab-nonfree.sources <<'NF_EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
NF_EOF
        fi
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends nvidia-kernel-dkms nvidia-smi libcuda1 nvidia-persistenced nvidia-modprobe \
            || warn "IA : installation des paquets NVIDIA Debian échouée (voir ci-dessus). Alternative : AI_NVIDIA_SOURCE=run avec AI_NVIDIA_VERSION."
    else
        local run="${IMAGE_STORE_DIR}/NVIDIA-Linux-x86_64-${AI_NVIDIA_VERSION}.run"
        [[ -f "$run" ]] || curl -fL -C - -o "${run}.part" "https://us.download.nvidia.com/XFree86/Linux-x86_64/${AI_NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${AI_NVIDIA_VERSION}.run" \
            || die "Téléchargement du pilote NVIDIA ${AI_NVIDIA_VERSION} impossible (version inexistante ?)."
        [[ -f "$run" ]] || mv -f "${run}.part" "$run"
        sh "$run" --silent --dkms --no-questions --no-drm || warn "IA : l'installateur NVIDIA a échoué (journal : /var/log/nvidia-installer.log)."
    fi

    printf 'nvidia\nnvidia_uvm\n' > /etc/modules-load.d/homelab-nvidia.conf
    cat > /etc/udev/rules.d/70-homelab-nvidia.rules <<'UDEV_EOF'
KERNEL=="nvidia", MODE="0666"
KERNEL=="nvidiactl", MODE="0666"
KERNEL=="nvidia[0-9]*", MODE="0666"
KERNEL=="nvidia_uvm", MODE="0666"
KERNEL=="nvidia_uvm_tools", MODE="0666"
UDEV_EOF
    udevadm control --reload-rules >/dev/null 2>&1 || true
    update-initramfs -u >/dev/null 2>&1 || true
    systemctl enable --now nvidia-persistenced >/dev/null 2>&1 || true

    modprobe nvidia >/dev/null 2>&1 || true
    modprobe nvidia_uvm >/dev/null 2>&1 || true

    if nvidia-smi -L >/dev/null 2>&1; then
        info "IA : pilote NVIDIA actif ($(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1))."
    else
        AI_NEEDS_REBOOT=true
        warn "IA : le pilote NVIDIA n'est pas encore actif (redémarrage nécessaire)."
        warn "     Si Secure Boot est activé dans le BIOS, le module non signé sera refusé : désactive Secure Boot."
    fi
    return 0
}

# Passe le GPU au CT (périphériques /dev/nvidia*), installe les bibliothèques CUDA côté CT à la MÊME version que l'hôte,
# redémarre le CT et Ollama. Idempotent. Utilisable seule : ./install.sh --run ai_gpu_attach
ai_gpu_attach() {

    pct status "$AI_ID" >/dev/null 2>&1 || die "CT IA ${AI_ID} introuvable."
    nvidia-modprobe -u -c=0 >/dev/null 2>&1 || true
    nvidia-smi -L >/dev/null 2>&1 || die "Pilote NVIDIA inactif sur l'hôte : redémarre l'hôte (puis relance cette commande). nvidia-smi doit afficher la carte."

    local conf="/etc/pve/lxc/${AI_ID}.conf" tmp dev major uvm
    tmp="$(mktemp)"
    uvm="$(awk '$2=="nvidia-uvm" {print $1}' /proc/devices)"

    sed '/^# homelab-ai-gpu begin/,/^# homelab-ai-gpu end/d' "$conf" > "$tmp"
    {
        echo "# homelab-ai-gpu begin"
        echo "lxc.cgroup2.devices.allow: c 195:* rwm"
        [[ -n "$uvm" ]] && echo "lxc.cgroup2.devices.allow: c ${uvm}:* rwm"
        for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
            [[ -c "$dev" ]] || continue
            echo "lxc.mount.entry: ${dev} ${dev#/} none bind,optional,create=file"
        done
        echo "# homelab-ai-gpu end"
    } >> "$tmp"

    pct stop "$AI_ID" >/dev/null 2>&1 || true
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    pct start "$AI_ID"
    pct_wait_for_network "$AI_ID"

    local hostv
    hostv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"

    if [[ "$AI_NVIDIA_SOURCE" == "run" ]]; then
        local run="${IMAGE_STORE_DIR}/NVIDIA-Linux-x86_64-${AI_NVIDIA_VERSION}.run"
        pct push "$AI_ID" "$run" /root/nvidia.run
        pct exec "$AI_ID" -- sh /root/nvidia.run --silent --no-kernel-module --no-questions --no-drm \
            || warn "IA : installation des bibliothèques NVIDIA dans le CT échouée."
        pct exec "$AI_ID" -- rm -f /root/nvidia.run || true
    else
        pct exec "$AI_ID" -- bash -c '
            export DEBIAN_FRONTEND=noninteractive
            grep -rqs non-free /etc/apt/sources.list.d/ || cat > /etc/apt/sources.list.d/nonfree.sources <<EOT
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
            apt-get update >/dev/null 2>&1
            apt-get install -y --no-install-recommends libcuda1 nvidia-smi' \
            || warn "IA : bibliothèques NVIDIA du CT non installées."
    fi

    local ctv
    ctv="$(pct exec "$AI_ID" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    if [[ -z "$ctv" ]]; then
        warn "IA : nvidia-smi ne répond pas dans le CT (périphériques ou bibliothèques)."
    elif [[ "$ctv" != "$hostv" ]]; then
        warn "IA : versions de pilote différentes (hôte ${hostv}, CT ${ctv}) : CUDA refusera de démarrer. Utilise AI_NVIDIA_SOURCE=run pour des versions identiques."
    else
        info "IA : GPU visible dans le CT (pilote ${ctv})."
    fi

    pct exec "$AI_ID" -- systemctl restart ollama >/dev/null 2>&1 || true
    return 0
}

###############################################################################
#                           CHOIX DES MODÈLES                                 #
###############################################################################

ai_pick_models() {

    local vram
    vram="$(ai_vram_mb 2>/dev/null || true)"
    if [[ -z "$vram" ]]; then
        if [[ "$AI_GPU_ON" == "true" ]]; then vram="${AI_VRAM_MB:-12000}"; else vram=0; fi
        [[ "$AI_GPU_ON" == "true" ]] && warn "IA : VRAM non lisible (pilote pas encore actif) : hypothèse ${vram} Mo (AI_VRAM_MB pour la corriger)."
    fi

    local chat code
    if   (( vram >= 20000 )); then chat="qwen2.5:32b"; code="qwen2.5-coder:32b"
    elif (( vram >= 10000 )); then chat="qwen2.5:14b"; code="qwen2.5-coder:14b"
    elif (( vram >=  6000 )); then chat="qwen2.5:7b";  code="qwen2.5-coder:7b"
    else                           chat="qwen2.5:3b";  code="qwen2.5-coder:3b"
    fi

    [[ -n "$AI_MODEL_CHAT" ]] || AI_MODEL_CHAT="$chat"
    [[ -n "$AI_MODEL_CODE" ]] || AI_MODEL_CODE="$code"
    info "IA : modèles (VRAM ${vram} Mo) : discussion ${AI_MODEL_CHAT} | code ${AI_MODEL_CODE} | embeddings ${AI_MODEL_EMBED} | autocomplétion ${AI_MODEL_AUTOCOMPLETE}"
}

# Télécharge les modèles dans le CT. Utilisable seule : ./install.sh --run ai_pull_models
ai_pull_models() {

    ai_pick_models

    local m
    for m in $(printf '%s\n' "$AI_MODEL_CHAT" "$AI_MODEL_CODE" "$AI_MODEL_EMBED" "$AI_MODEL_AUTOCOMPLETE" | awk 'NF && !s[$0]++'); do
        info "IA : téléchargement du modèle ${m} (plusieurs Go, patience)..."
        timeout 7200 pct exec "$AI_ID" -- ollama pull "$m" >/dev/null 2>&1 \
            || warn "IA : échec du téléchargement de ${m} (relancer : ./install.sh --run ai_pull_models)."
    done
}

###############################################################################
#                          FICHIERS DU CT (OLLAMA, WEBUI)                      #
###############################################################################

ai_web_url() { printf 'http://%s:%s' "${AI_IP%%/*}" "$AI_WEB_PORT"; }

ai_ollama_dropin() {
    cat <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${AI_API_PORT}"
Environment="OLLAMA_MODELS=/srv/ai/models"
Environment="OLLAMA_KEEP_ALIVE=${AI_KEEP_ALIVE}"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_CONTEXT_LENGTH=${AI_CONTEXT}"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF
}

ai_compose() {   # $1 = true|false (inscription ouverte)
    cat <<EOF
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=${AI_WEB_PORT}
      - OLLAMA_BASE_URL=http://127.0.0.1:${AI_API_PORT}
      - WEBUI_NAME=${AI_WEBUI_NAME}
      - ENABLE_SIGNUP=$1
      - ANONYMIZED_TELEMETRY=false
      - DO_NOT_TRACK=true
      - SCARF_NO_ANALYTICS=true
      - RAG_EMBEDDING_ENGINE=ollama
      - RAG_EMBEDDING_MODEL=${AI_MODEL_EMBED}
      - RAG_TOP_K=6
      - CHUNK_SIZE=900
      - CHUNK_OVERLAP=150
      - TZ=Europe/Paris
      - "RAG_TEMPLATE=Réponds en français uniquement à partir des extraits ci-dessous. Cite pour chaque affirmation le document et la page. Si les extraits ne contiennent pas la réponse, dis-le clairement sans rien inventer. Extraits : {{CONTEXT}} Question : {{QUERY}}"
    volumes:
      - /opt/ai/webui:/app/backend/data
EOF
}

# OCR + envoi dans Open WebUI : appelé par la minuterie ai-sync (toutes les 15 min).
ai_ocr_script() {
    cat <<'EOF'
#!/usr/bin/env bash
# OCR des PDF de /srv/ai/sources -> /srv/ai/ocr (PDF avec couche texte), sans toucher aux originaux.
set -uo pipefail
. /etc/ai/sync.env
SRC=/srv/ai/sources; OUT=/srv/ai/ocr; STATE=/var/lib/ai/ocr.done
mkdir -p "$OUT" /var/lib/ai; touch "$STATE"
[[ "${AI_OCR:-true}" == "true" ]] || exit 0
find "$SRC" -type f -iname '*.pdf' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    sig="$(stat -c '%n|%Y|%s' "$f")"
    grep -qxF "$sig" "$STATE" && continue
    rel="${f#$SRC/}"; dst="$OUT/$rel"; mkdir -p "$(dirname "$dst")"
    if ocrmypdf -l "$AI_OCR_LANG" --skip-text --deskew --rotate-pages --jobs 2 --output-type pdf "$f" "$dst" >/var/log/ai-ocr.last 2>&1 || [[ -s "$dst" ]]; then
        echo "$sig" >> "$STATE"; echo "OCR ok : $rel"
    else
        echo "OCR ÉCHEC : $rel (voir /var/log/ai-ocr.last)"; cp "$f" "$dst" 2>/dev/null || true
    fi
done
EOF
}

ai_ingest_script() {
    cat <<'EOF'
#!/usr/bin/env python3
"""Envoie les PDF de /srv/ai/ocr dans la base de connaissances Open WebUI (API). Les fichiers déjà envoyés sont ignorés."""
import json, os, sys, time, urllib.request, urllib.error, uuid
env = {}
for l in open('/etc/ai/sync.env'):
    if '=' in l and not l.startswith('#'):
        k, v = l.strip().split('=', 1); env[k] = v.strip('"')
if env.get('AI_INGEST', 'true') != 'true':
    sys.exit(0)
BASE, OUT, STATE = env['WEBUI_URL'].rstrip('/'), '/srv/ai/ocr', '/var/lib/ai/ingested.json'
done = json.load(open(STATE)) if os.path.exists(STATE) else {}

def call(method, path, data=None, headers=None, raw=None):
    h = dict(headers or {})
    body = raw
    if data is not None:
        body = json.dumps(data).encode(); h['Content-Type'] = 'application/json'
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read() or b'{}')

try:
    tok = call('POST', '/api/v1/auths/signin', {'email': env['WEBUI_EMAIL'], 'password': env['WEBUI_PASSWORD']})['token']
except Exception as e:
    print('Open WebUI injoignable ou identifiants refusés :', e); sys.exit(0)
auth = {'Authorization': 'Bearer ' + tok}

todo = []
for root, _, files in os.walk(OUT):
    for f in files:
        if f.lower().endswith('.pdf'):
            p = os.path.join(root, f); st = os.stat(p)
            sig = f'{int(st.st_mtime)}|{st.st_size}'
            if done.get(p) != sig:
                todo.append((p, sig))
if not todo:
    sys.exit(0)

name = env.get('AI_COLLECTION', 'Normes')
kid = None
for k in call('GET', '/api/v1/knowledge/', headers=auth) if True else []:
    if k.get('name') == name: kid = k['id']
if not kid:
    kid = call('POST', '/api/v1/knowledge/create', {'name': name, 'description': 'Documents indexés automatiquement'}, auth)['id']

for p, sig in todo:
    try:
        b = uuid.uuid4().hex
        fn = os.path.relpath(p, OUT).replace('/', ' - ')
        body = (f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{fn}"\r\nContent-Type: application/pdf\r\n\r\n').encode() + open(p, 'rb').read() + f'\r\n--{b}--\r\n'.encode()
        h = dict(auth); h['Content-Type'] = 'multipart/form-data; boundary=' + b
        fid = call('POST', '/api/v1/files/', headers=h, raw=body)['id']
        for _ in range(30):   # attend la fin de l'extraction/indexation
            try:
                call('POST', f'/api/v1/knowledge/{kid}/file/add', {'file_id': fid}, auth); break
            except urllib.error.HTTPError as e:
                if e.code in (400, 409, 500): time.sleep(10); continue
                raise
        done[p] = sig; print('Indexé :', fn)
        json.dump(done, open(STATE, 'w'))
    except Exception as e:
        print('Échec', p, e)
EOF
}

###############################################################################
#                              CRÉATION DU CT                                 #
###############################################################################

# Dossier des documents : écriture pour le groupe partagé (Samba), LECTURE pour le CT IA (utilisateur hôte 100000 =
# root du CT non privilégié), y compris pour les futurs fichiers (ACL par défaut). Idempotent.
ai_prepare_docs_dir() {
    mkdir -p "$AI_DOCS_DIR"
    chgrp -R "${SHARED_GROUP:-fileshare}" "$(dirname "$AI_DOCS_DIR")" 2>/dev/null || true
    find "$AI_DOCS_DIR" -type d -exec chmod 2770 {} \; 2>/dev/null || true
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -R -m "u:100000:rX" "$AI_DOCS_DIR" 2>/dev/null || true
        setfacl -R -d -m "u:100000:rX" "$AI_DOCS_DIR" 2>/dev/null || true
        setfacl -R -d -m "g:${SHARED_GROUP:-fileshare}:rwX" "$AI_DOCS_DIR" 2>/dev/null || true
    else
        chmod -R o+rX "$AI_DOCS_DIR" 2>/dev/null || true
    fi
}

create_ai_ct() {

    if pct status "$AI_ID" >/dev/null 2>&1; then
        warn "CT ${AI_ID} existe déjà. Création IA ignorée."
        return 0
    fi

    ai_pick_models

    ai_prepare_docs_dir

    download_debian_lxc_template
    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT IA ${AI_ID} (${AI_CORES} cœurs, ${AI_MEMORY} Mo, disque ${AI_DISK})..."

    pct create "$AI_ID" \
        "$TEMPLATE" \
        --hostname "$AI_HOSTNAME" \
        --cores "$AI_CORES" \
        --cpuunits 2048 \
        --memory "$AI_MEMORY" \
        --swap 0 \
        --rootfs "${GUEST_STORAGE}:${AI_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${AI_GATEWAY},ip=${AI_IP}" \
        --mp0 "${AI_DOCS_DIR},mp=/srv/ai/sources,ro=1,backup=0" \
        --unprivileged 1 \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct start "$AI_ID"
    pct_wait_for_network "$AI_ID"

    local WORK
    WORK="$(mktemp -d)"

    ai_ollama_dropin      > "${WORK}/ollama.conf"
    ai_compose true       > "${WORK}/docker-compose.yml"
    ai_ocr_script         > "${WORK}/ai-ocr"
    ai_ingest_script      > "${WORK}/ai-ingest"
    {
        printf 'AI_OCR=%s\nAI_OCR_LANG=%s\nAI_INGEST=%s\nAI_COLLECTION="%s"\n' "$AI_OCR" "$AI_OCR_LANG" "$AI_INGEST" "$AI_COLLECTION"
        printf 'WEBUI_URL=http://127.0.0.1:%s\nWEBUI_EMAIL=%s\nWEBUI_PASSWORD=%s\n' "$AI_WEB_PORT" "$AI_WEBUI_EMAIL" "$AI_WEBUI_PASSWORD"
    } > "${WORK}/sync.env"

    cat > "${WORK}/ai-sync" <<'SYNC_EOF'
#!/usr/bin/env bash
exec 9>/run/ai-sync.lock; flock -n 9 || exit 0
/usr/local/sbin/ai-ocr && /usr/local/sbin/ai-ingest
SYNC_EOF

    cat > "${WORK}/ai-sync.service" <<'UNIT_EOF'
[Unit]
Description=OCR et indexation des documents pour l'IA
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ai-sync
Nice=15
IOSchedulingClass=idle
UNIT_EOF

    cat > "${WORK}/ai-sync.timer" <<'TIMER_EOF'
[Unit]
Description=OCR et indexation des documents (toutes les 15 min)

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
TIMER_EOF

    cat > "${WORK}/install-ai.sh" <<'INST_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg zstd python3 util-linux pciutils \
    ocrmypdf tesseract-ocr-fra tesseract-ocr-eng
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
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
mkdir -p /srv/ai/models /srv/ai/ocr /opt/ai/webui /etc/ai /var/lib/ai
curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /etc/systemd/system/ollama.service.d
install -m 0644 /root/ai-files/ollama.conf /etc/systemd/system/ollama.service.d/homelab.conf
chown -R ollama:ollama /srv/ai/models 2>/dev/null || true
install -m 0600 /root/ai-files/sync.env /etc/ai/sync.env
install -m 0755 /root/ai-files/ai-ocr /usr/local/sbin/ai-ocr
install -m 0755 /root/ai-files/ai-ingest /usr/local/sbin/ai-ingest
install -m 0755 /root/ai-files/ai-sync /usr/local/sbin/ai-sync
install -m 0644 /root/ai-files/ai-sync.service /etc/systemd/system/ai-sync.service
install -m 0644 /root/ai-files/ai-sync.timer /etc/systemd/system/ai-sync.timer
install -m 0644 /root/ai-files/docker-compose.yml /opt/ai/docker-compose.yml
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama
systemctl enable --now ai-sync.timer
cd /opt/ai && docker compose pull && docker compose up -d
INST_EOF

    pct exec "$AI_ID" -- mkdir -p /root/ai-files
    local f
    for f in ollama.conf docker-compose.yml ai-ocr ai-ingest ai-sync sync.env ai-sync.service ai-sync.timer; do
        pct push "$AI_ID" "${WORK}/${f}" "/root/ai-files/${f}"
    done
    pct_push_script "$AI_ID" "${WORK}/install-ai.sh" /root/install-ai.sh
    rm -rf "$WORK"

    pct exec "$AI_ID" -- bash /root/install-ai.sh || die "Installation de l'IA dans le CT ${AI_ID} échouée."

    if [[ "$AI_GPU_ON" == "true" ]] && nvidia-smi -L >/dev/null 2>&1; then
        ai_gpu_attach
    elif [[ "$AI_GPU_ON" == "true" ]]; then
        AI_NEEDS_REBOOT=true
    fi

    ai_webui_admin
    ai_pull_models
    ai_continue_config

    info "IA installée dans le CT ${AI_ID} : $(ai_web_url)"
    if [[ "$AI_NEEDS_REBOOT" == "true" ]]; then
        warn "IA : REDÉMARRE l'hôte pour activer le pilote NVIDIA, puis lance : ./install.sh --run ai_gpu_attach  (sans GPU, l'IA fonctionne mais sur le CPU)."
    fi
}

# Crée le compte administrateur Open WebUI (premier inscrit = admin) puis ferme les inscriptions.
ai_webui_admin() {

    local url body code i
    url="$(ai_web_url)"

    info "IA : attente d'Open WebUI (jusqu'à 5 min)..."
    for ((i = 1; i <= 60; i++)); do
        curl -fsS -m 5 "${url}/health" >/dev/null 2>&1 && break
        sleep 5
    done
    curl -fsS -m 5 "${url}/health" >/dev/null 2>&1 || { warn "IA : Open WebUI ne répond pas (docker logs open-webui dans le CT ${AI_ID})."; return 0; }

    body="$(AI_N="Admin" AI_E="$AI_WEBUI_EMAIL" AI_P="$AI_WEBUI_PASSWORD" python3 -c 'import json,os; print(json.dumps({"name":os.environ["AI_N"],"email":os.environ["AI_E"],"password":os.environ["AI_P"],"profile_image_url":"/user.png"}))')"
    code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" "${url}/api/v1/auths/signup" || true)"

    if [[ "$code" == "200" ]]; then
        info "IA : compte administrateur créé (${AI_WEBUI_EMAIL})."
    else
        warn "IA : création du compte administrateur : code ${code} (compte déjà existant ? crée-le toi-même sur ${url})."
    fi

    # Inscriptions fermées désormais
    local tmp
    tmp="$(mktemp)"
    ai_compose false > "$tmp"
    pct push "$AI_ID" "$tmp" /opt/ai/docker-compose.yml
    rm -f "$tmp"
    pct exec "$AI_ID" -- bash -c 'cd /opt/ai && docker compose up -d' >/dev/null 2>&1 \
        || warn "IA : fermeture des inscriptions échouée (ENABLE_SIGNUP=false dans /opt/ai/docker-compose.yml du CT)."
}

# Fichier de configuration pour l'extension VS Code « Continue » (posé dans SHARED/IA, accessible par Samba).
ai_continue_config() {

    local ip="${LAN_IP}" f
    f="$(dirname "$AI_DOCS_DIR")/continue-config.yaml"
    mkdir -p "$(dirname "$f")"

    cat > "$f" <<EOF
# À copier dans  ~/.continue/config.yaml  (extension VS Code « Continue »). Réseau local ou VPN uniquement.
name: Homelab IA
version: 1.0.0
schema: v1
models:
  - name: Code (${AI_MODEL_CODE})
    provider: ollama
    model: ${AI_MODEL_CODE}
    apiBase: http://${ip}:${AI_API_PORT}
    roles: [chat, edit, apply]
  - name: Discussion (${AI_MODEL_CHAT})
    provider: ollama
    model: ${AI_MODEL_CHAT}
    apiBase: http://${ip}:${AI_API_PORT}
    roles: [chat]
  - name: Autocomplétion
    provider: ollama
    model: ${AI_MODEL_AUTOCOMPLETE}
    apiBase: http://${ip}:${AI_API_PORT}
    roles: [autocomplete]
  - name: Embeddings
    provider: ollama
    model: ${AI_MODEL_EMBED}
    apiBase: http://${ip}:${AI_API_PORT}
    roles: [embed]
EOF
    info "IA : configuration VS Code (Continue) écrite : ${f}"
}

# Mode run (ENABLE_AI=run) : réapplique les paramètres sur le CT existant, sans rien installer :
# cœurs/RAM, réglages d'Ollama, compose d'Open WebUI, modèles manquants, GPU, dossier de documents, config VS Code.
ai_reconfigure() {

    pct status "$AI_ID" >/dev/null 2>&1 || die "CT IA ${AI_ID} introuvable."
    info "IA : mode run, réapplication des paramètres (CT ${AI_ID})..."

    ai_pick_models
    ai_prepare_docs_dir

    pct set "$AI_ID" --cores "$AI_CORES" --memory "$AI_MEMORY" >/dev/null 2>&1 \
        || warn "IA : cœurs/RAM non modifiés (pct set)."
    pct status "$AI_ID" | grep -q running || { pct start "$AI_ID" >/dev/null; pct_wait_for_network "$AI_ID"; }

    local WORK
    WORK="$(mktemp -d)"
    ai_ollama_dropin > "${WORK}/ollama.conf"
    ai_compose false > "${WORK}/docker-compose.yml"
    {
        printf 'AI_OCR=%s\nAI_OCR_LANG=%s\nAI_INGEST=%s\nAI_COLLECTION="%s"\n' "$AI_OCR" "$AI_OCR_LANG" "$AI_INGEST" "$AI_COLLECTION"
        printf 'WEBUI_URL=http://127.0.0.1:%s\nWEBUI_EMAIL=%s\nWEBUI_PASSWORD=%s\n' "$AI_WEB_PORT" "$AI_WEBUI_EMAIL" "$AI_WEBUI_PASSWORD"
    } > "${WORK}/sync.env"

    pct push "$AI_ID" "${WORK}/ollama.conf" /etc/systemd/system/ollama.service.d/homelab.conf
    pct push "$AI_ID" "${WORK}/docker-compose.yml" /opt/ai/docker-compose.yml
    pct push "$AI_ID" "${WORK}/sync.env" /etc/ai/sync.env
    pct exec "$AI_ID" -- chmod 0600 /etc/ai/sync.env
    rm -rf "$WORK"

    pct exec "$AI_ID" -- bash -c 'systemctl daemon-reload && systemctl restart ollama && cd /opt/ai && docker compose up -d' \
        || warn "IA : redémarrage d'Ollama / Open WebUI échoué."

    if [[ "$AI_GPU_ON" == "true" ]] && nvidia-smi -L >/dev/null 2>&1 && ! grep -q "homelab-ai-gpu begin" "/etc/pve/lxc/${AI_ID}.conf"; then
        ai_gpu_attach
    fi

    ai_pull_models
    ai_continue_config
}

# Relance l'OCR et l'indexation tout de suite (sinon toutes les 15 min). ./install.sh --run ai_sync_now
ai_sync_now() { pct exec "$AI_ID" -- /usr/local/sbin/ai-sync; }

ai_status() {
    pct status "$AI_ID" || true
    pct exec "$AI_ID" -- bash -c 'nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null || echo "GPU : non visible"; ollama list; ollama ps; docker ps --format "{{.Names}} {{.Status}}"' || true
}

verify_ai() {
    info "CT IA :"
    pct config "$AI_ID"
    curl -fsS -m 10 "http://${AI_IP%%/*}:${AI_API_PORT}/api/tags" >/dev/null 2>&1 \
        && info "  Ollama : répond" || warn "  Ollama : ne répond pas"
    curl -fsS -m 10 "$(ai_web_url)/health" >/dev/null 2>&1 \
        && info "  Open WebUI : répond" || warn "  Open WebUI : ne répond pas"
}

ai_summary() {

    [[ "${ENABLE_AI:-false}" == "true" ]] || return 0

    echo "IA (CT ${AI_ID}, ${AI_IP}) :"
    echo "  Interface : http://${LAN_IP}:${AI_WEB_PORT}  (réseau local / VPN uniquement)"
    echo "  Compte    : ${AI_WEBUI_EMAIL} / ${AI_WEBUI_PASSWORD}"
    echo "  Modèles   : ${AI_MODEL_CHAT} | ${AI_MODEL_CODE} | ${AI_MODEL_EMBED} | ${AI_MODEL_AUTOCOMPLETE}"
    [[ "$AI_API_LAN" == "true" ]] && echo "  API Ollama: http://${LAN_IP}:${AI_API_PORT}  (SANS mot de passe : réseau local uniquement)"
    echo "  Normes    : dépose les PDF (même scannés) dans ${AI_DOCS_DIR} ; OCR + indexation auto toutes les 15 min dans « ${AI_COLLECTION} » (immédiat : ./install.sh --run ai_sync_now)"
    echo "  VS Code   : $(dirname "$AI_DOCS_DIR")/continue-config.yaml -> ~/.continue/config.yaml"
    [[ "$AI_NEEDS_REBOOT" == "true" ]] && echo "  ATTENTION : redémarre l'hôte puis ./install.sh --run ai_gpu_attach (pilote NVIDIA)"
    echo
}

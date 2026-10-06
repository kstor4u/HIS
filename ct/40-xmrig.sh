###############################################################################
#                              XMRIG                                          #
###############################################################################

resolve_xmrig_expected_hash() {

    # Récupère le hash officiel depuis le fichier SHA256SUMS publié avec
    # la release GitHub (source unique de vérité, ne se périme pas quand
    # XMRIG_VERSION change). Si le téléchargement échoue (réseau hôte
    # restreint, GitHub indisponible), on retombe sur le hash codé en dur
    # avec un avertissement explicite plutôt que d'échouer silencieusement.

    local expected_hash=""
    local sums_file
    sums_file="$(mktemp)"

    if wget --https-only -q -O "$sums_file" "$XMRIG_SHA256SUMS_URL"; then

        expected_hash="$(
            grep -F "$XMRIG_ARCHIVE" "$sums_file" |
                awk '{print $1}'
        )"
    fi

    rm -f "$sums_file"

    if [[ -z "$expected_hash" ]]; then

        warn "Impossible de récupérer SHA256SUMS officiel depuis GitHub pour XMRig ${XMRIG_VERSION}."
        warn "Utilisation du hash de secours codé en dur (XMRIG_SHA256_FALLBACK) : vérifie-le manuellement si tu changes XMRIG_VERSION."

        expected_hash="$XMRIG_SHA256_FALLBACK"
    fi

    printf '%s' "$expected_hash"
}

create_xmrig_ct() {

    if pct status "$XMRIG_ID" >/dev/null 2>&1; then

        warn "CT ${XMRIG_ID} existe déjà. Création XMRig ignorée."

        return 0
    fi

    download_debian_lxc_template

    local TEMPLATE="$DOWNLOADED_TEMPLATE"

    info "Création du CT XMRig ${XMRIG_ID}..."

    pct create "$XMRIG_ID" \
        "$TEMPLATE" \
        --hostname "$XMRIG_HOSTNAME" \
        --cores "$XMRIG_CORES" \
        --memory "$XMRIG_MEMORY" \
        --swap 1024 \
        --rootfs "local-lvm:${XMRIG_DISK%G}" \
        --net0 "name=eth0,bridge=${PRIVATE_BRIDGE},firewall=1,gw=${XMRIG_GATEWAY},ip=${XMRIG_IP}" \
        --unprivileged 1 \
        --onboot 1 \
        --password "$ROOT_PASSWORD"

    pct set "$XMRIG_ID" \
        --mp0 "${HUGEPAGES_MOUNT},mp=${HUGEPAGES_MOUNT}"

    pct start "$XMRIG_ID"

    pct_wait_for_network "$XMRIG_ID"

    local XMRIG_EXPECTED_SHA256
    XMRIG_EXPECTED_SHA256="$(resolve_xmrig_expected_hash)"

    local SCRIPT
    SCRIPT="$(mktemp)"

    cat > "$SCRIPT" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    tar

mkdir -p /opt/xmrig
mkdir -p /etc/xmrig

cd /opt/xmrig

wget \
    --https-only \
    -O xmrig.tar.gz \
    "${XMRIG_URL}"

echo "${XMRIG_EXPECTED_SHA256}  xmrig.tar.gz" |
    sha256sum -c -

tar -xzf xmrig.tar.gz --strip-components=1

test -x /opt/xmrig/xmrig

cat > /etc/xmrig/config.json <<'CONFIG_EOF'
{
    "autosave": false,
    "background": false,
    "colors": false,
    "donate-level": 1,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "yield": true,
        "max-threads-hint": 100
    },
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "auto",
        "1gb-pages": false,
        "rdmsr": false,
        "wrmsr": false,
        "huge-pages": true,
        "huge-pages-jit": false
    },
    "pools": [
        {
            "url": "${XMRIG_POOL}",
            "user": "${XMRIG_WALLET}",
            "pass": "x",
            "keepalive": true,
            "tls": false
        }
    ]
}
CONFIG_EOF

chmod 600 /etc/xmrig/config.json

cat > /etc/systemd/system/xmrig.service <<'SERVICE_EOF'
[Unit]
Description=XMRig Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/xmrig/xmrig --config=/etc/xmrig/config.json
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable xmrig
systemctl restart xmrig

systemctl is-active --quiet xmrig

/opt/xmrig/xmrig --version
EOF

    pct_push_script \
        "$XMRIG_ID" \
        "$SCRIPT" \
        "/root/install-xmrig.sh"

    pct exec "$XMRIG_ID" -- \
        bash /root/install-xmrig.sh

    rm -f "$SCRIPT"

    info "XMRig ${XMRIG_VERSION} installé."
}

###############################################################################
#                              XMRIG MONITOR                                  #
###############################################################################

create_xmrig_monitor() {

    info "Création du monitor XMRig..."

    cat > /usr/local/sbin/xmrig-monitor.sh <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

CT_ID="__XMRIG_ID__"

STOP_THRESHOLD="__STOP_THRESHOLD__"
RESUME_THRESHOLD="__RESUME_THRESHOLD__"
RESUME_DELAY="__RESUME_DELAY__"
INTERVAL="__INTERVAL__"

STATE_FILE="/run/xmrig-monitor.state"

host_cpu_count="$(nproc)"

read_cpu() {

    awk '/^cpu / {
        idle=$5+$6
        total=$2+$3+$4+$5+$6+$7+$8+$9+$10
        print total, idle
        exit
    }' /proc/stat
}

cpu_usage() {

    local total1 idle1 total2 idle2

    read -r total1 idle1 < <(read_cpu)

    sleep 1

    read -r total2 idle2 < <(read_cpu)

    awk \
        -v t1="$total1" \
        -v i1="$idle1" \
        -v t2="$total2" \
        -v i2="$idle2" '
        BEGIN {
            dt=t2-t1
            di=i2-i1

            if (dt <= 0) {
                print "0"
                exit
            }

            printf "%.2f\n", ((dt-di)/dt)*100
        }
    '
}

xmrig_cpu_usage() {

    if ! pct status "$CT_ID" 2>/dev/null |
        grep -q "status: running"; then

        echo "0"
        return 0
    fi

    local process_cpu

    process_cpu="$(
        pct exec "$CT_ID" -- \
            bash -c \
            "ps -C xmrig -o %cpu= 2>/dev/null | awk '{s+=\$1} END {printf \"%.2f\", s+0}'"
    )"

    awk \
        -v process="$process_cpu" \
        -v cpus="$host_cpu_count" '
        BEGIN {
            printf "%.2f\n", process/cpus
        }
    '
}

other_workload_cpu() {

    local total_cpu
    local xmrig_cpu

    total_cpu="$(cpu_usage)"
    xmrig_cpu="$(xmrig_cpu_usage)"

    awk \
        -v total="$total_cpu" \
        -v xmrig="$xmrig_cpu" '
        BEGIN {
            value=total-xmrig

            if (value < 0) {
                value=0
            }

            printf "%.2f\n", value
        }
    '
}

is_xmrig_active() {

    pct exec "$CT_ID" -- \
        systemctl is-active --quiet xmrig
}

start_xmrig() {

    pct exec "$CT_ID" -- \
        systemctl start xmrig

    rm -f "$STATE_FILE"
}

stop_xmrig() {

    pct exec "$CT_ID" -- \
        systemctl stop xmrig

    printf '%s\n' "PAUSED_BY_MONITOR" > "$STATE_FILE"
}

resume_since=0

while true; do

    if ! pct status "$CT_ID" 2>/dev/null |
        grep -q "status: running"; then

        sleep "$INTERVAL"
        continue
    fi

    OTHER_CPU="$(other_workload_cpu)"

    if is_xmrig_active; then

        resume_since=0

        if awk \
            -v cpu="$OTHER_CPU" \
            -v threshold="$STOP_THRESHOLD" \
            'BEGIN { exit !(cpu >= threshold) }'; then

            logger -t xmrig-monitor \
                "Other workloads CPU=${OTHER_CPU}% >= ${STOP_THRESHOLD}%, stopping XMRig."

            stop_xmrig
        fi

    else

        if [[ -f "$STATE_FILE" ]]; then

            if awk \
                -v cpu="$OTHER_CPU" \
                -v threshold="$RESUME_THRESHOLD" \
                'BEGIN { exit !(cpu < threshold) }'; then

                if [[ "$resume_since" -eq 0 ]]; then
                    resume_since="$(date +%s)"
                fi

                now="$(date +%s)"
                elapsed=$((now-resume_since))

                if (( elapsed >= RESUME_DELAY )); then

                    logger -t xmrig-monitor \
                        "Other workloads CPU=${OTHER_CPU}% < ${RESUME_THRESHOLD}% for ${RESUME_DELAY}s, starting XMRig."

                    start_xmrig
                    resume_since=0
                fi

            else

                resume_since=0
            fi

        else

            resume_since=0
        fi
    fi

    sleep "$INTERVAL"
done
EOF

    sed -i \
        "s/__XMRIG_ID__/${XMRIG_ID}/g" \
        /usr/local/sbin/xmrig-monitor.sh

    sed -i \
        "s/__STOP_THRESHOLD__/${XMRIG_STOP_THRESHOLD}/g" \
        /usr/local/sbin/xmrig-monitor.sh

    sed -i \
        "s/__RESUME_THRESHOLD__/${XMRIG_RESUME_THRESHOLD}/g" \
        /usr/local/sbin/xmrig-monitor.sh

    sed -i \
        "s/__RESUME_DELAY__/${XMRIG_RESUME_DELAY}/g" \
        /usr/local/sbin/xmrig-monitor.sh

    sed -i \
        "s/__INTERVAL__/${XMRIG_MONITOR_INTERVAL}/g" \
        /usr/local/sbin/xmrig-monitor.sh

    chmod 755 /usr/local/sbin/xmrig-monitor.sh

    cat > /etc/systemd/system/xmrig-monitor.service <<EOF
[Unit]
Description=XMRig CPU Load Monitor
After=network-online.target pve-guests.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/xmrig-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xmrig-monitor.service
    systemctl restart xmrig-monitor.service

    systemctl is-active --quiet xmrig-monitor.service \
        || die "Le service xmrig-monitor n'est pas actif."
}


###############################################################################
#                              SAUVEGARDES                                    #
###############################################################################

# Deux niveaux (réglages BACKUP_* dans core/00-config.sh) :
#  1. Tâche Proxmox planifiée (vzdump) : sauvegarde de toutes les VM/CT installés vers
#     le storage BACKUP_STORAGE (DATA par défaut), avec rotation. Protège contre
#     une fausse manipulation ou une mise à jour ratée, PAS contre la panne du disque
#     DATA (les sauvegardes sont sur le même disque).
#  2. Copie HORS SITE optionnelle (restic) du disque DATA (sauvegardes vzdump, données
#     d'applications dont les mails et Immich, partage SHARED) vers un autre serveur
#     (SFTP, par exemple au travers du VPN WireGuard) ou un stockage objet (S3...).
#     Les données sont chiffrées avant l'envoi (BACKUP_RESTIC_PASSWORD : à CONSERVER
#     ailleurs, sans lui la sauvegarde est inutilisable).
#
# Les dossiers d'applications bruts (/mnt/data/apps) ne sont PAS inclus dans vzdump
# (points de montage / VirtioFS) : seule la copie hors site les protège.

# IDs des VM/CT installés qui existent réellement, séparés par des virgules.
backup_vmid_list() {

    local -a ids=()

    [[ "$ENABLE_SWAG" == "true" ]]      && pct status "$SWAG_ID" >/dev/null 2>&1 && ids+=("$SWAG_ID")
    [[ "$ENABLE_DOCKER" == "true" ]]    && qm status "$DOCKER_ID" >/dev/null 2>&1 && ids+=("$DOCKER_ID")
    [[ "$ENABLE_FILES" == "true" ]]     && qm status "$FILES_ID" >/dev/null 2>&1 && ids+=("$FILES_ID")
    [[ "$ENABLE_XMRIG" == "true" ]]     && pct status "$XMRIG_ID" >/dev/null 2>&1 && ids+=("$XMRIG_ID")
    [[ "$ENABLE_WIREGUARD" == "true" ]] && pct status "$WG_ID" >/dev/null 2>&1 && ids+=("$WG_ID")
    [[ "$ENABLE_NODE" == "true" ]]      && pct status "$NODE_ID" >/dev/null 2>&1 && ids+=("$NODE_ID")
    [[ "$ENABLE_MAIL" == "true" ]]      && pct status "$MAIL_ID" >/dev/null 2>&1 && ids+=("$MAIL_ID")
    [[ "$ENABLE_DNS" == "true" ]]       && pct status "$DNS_ID" >/dev/null 2>&1 && ids+=("$DNS_ID")
    [[ "$ENABLE_MONITOR" == "true" ]]   && pct status "$MONITOR_ID" >/dev/null 2>&1 && ids+=("$MONITOR_ID")
    [[ "$ENABLE_AI" == "true" && "${AI_BACKUP:-false}" == "true" ]] && pct status "$AI_ID" >/dev/null 2>&1 && ids+=("$AI_ID")

    local IFS=,
    printf '%s' "${ids[*]:-}"
}

# Crée ou met à jour la tâche vzdump planifiée "homelab-daily". Idempotent.
configure_vzdump_job() {

    local ids job_id="homelab-daily"
    ids="$(backup_vmid_list)"

    if [[ -z "$ids" ]]; then
        warn "Sauvegardes : aucune VM/CT installé à sauvegarder, tâche vzdump ignorée."
        return 0
    fi

    pvesm status --storage "$BACKUP_STORAGE" >/dev/null 2>&1 \
        || die "Sauvegardes : le storage '${BACKUP_STORAGE}' n'existe pas (BACKUP_STORAGE)."

    local -a args=(
        --schedule "$BACKUP_SCHEDULE"
        --storage "$BACKUP_STORAGE"
        --mode "$BACKUP_MODE"
        --compress "$BACKUP_COMPRESS"
        --vmid "$ids"
        --prune-backups "$BACKUP_KEEP"
        --enabled 1
        --comment "Homelab : sauvegarde quotidienne (créée par l'installateur)"
    )

    if pvesh get /cluster/backup --output-format json 2>/dev/null | jq -e --arg id "$job_id" '.[] | select(.id == $id)' >/dev/null; then
        pvesh set "/cluster/backup/${job_id}" "${args[@]}" >/dev/null
        info "Sauvegardes : tâche ${job_id} mise à jour (${BACKUP_SCHEDULE}, VM/CT ${ids}, rotation ${BACKUP_KEEP})."
    else
        pvesh create /cluster/backup --id "$job_id" "${args[@]}" >/dev/null
        info "Sauvegardes : tâche ${job_id} créée (${BACKUP_SCHEDULE}, VM/CT ${ids}, rotation ${BACKUP_KEEP})."
    fi

    info "Sauvegardes : stockées dans '${BACKUP_STORAGE}' (même disque que les données : voir la copie hors site restic)."
}

# Prépare la copie hors site (restic) : paquet, clé SSH dédiée, mot de passe du dépôt,
# script et cron. Sans BACKUP_RESTIC_REPO, ne fait rien.
configure_offsite_backup() {

    [[ -n "$BACKUP_RESTIC_REPO" ]] || {
        info "Sauvegardes hors site : BACKUP_RESTIC_REPO vide, non configurées."
        return 0
    }

    [[ -n "$BACKUP_RESTIC_PASSWORD" ]] \
        || die "BACKUP_RESTIC_PASSWORD est vide : il chiffre la sauvegarde hors site (à définir dans le fichier de réponses)."

    command -v restic >/dev/null 2>&1 || {
        info "Installation de restic..."
        apt-get install -y restic >/dev/null
    }

    install -d -m 700 /root/.config/homelab
    printf '%s\n' "$BACKUP_RESTIC_PASSWORD" > /root/.config/homelab/restic-password
    chmod 600 /root/.config/homelab/restic-password

    local paths="${BACKUP_OFFSITE_PATHS:-${PROXMOX_DATA_DIR}/dump $(sites_data_dirs | awk '!s[$0]++' | paste -sd" " -)}"
    local sftp_opt="" key=/root/.ssh/homelab-backup

    if [[ "$BACKUP_RESTIC_REPO" == sftp:* ]]; then

        local target="${BACKUP_RESTIC_REPO#sftp:}"   # user@hote:/chemin
        local userhost="${target%%:*}"

        install -d -m 700 /root/.ssh

        if [[ ! -f "$key" ]]; then
            ssh-keygen -q -t ed25519 -N "" -C "homelab-backup@$(hostname -s)" -f "$key"
            info "Sauvegardes hors site : clé SSH créée (${key})."
        fi

        sftp_opt="-o sftp.command='ssh -i ${key} -o StrictHostKeyChecking=accept-new -o BatchMode=yes ${userhost} -s sftp'"

        info "Sauvegardes hors site : AUTORISE cette clé publique sur ${userhost} (fichier ~/.ssh/authorized_keys) :"
        cat "${key}.pub"
    fi

    cat > /usr/local/sbin/homelab-offsite-backup.sh <<SCRIPT_EOF
#!/usr/bin/env bash
# Généré par l'installateur homelab : copie hors site chiffrée (restic).
set -Eeuo pipefail
export RESTIC_REPOSITORY='${BACKUP_RESTIC_REPO}'
export RESTIC_PASSWORD_FILE=/root/.config/homelab/restic-password
OPT=(${sftp_opt})
LOG=/var/log/homelab-offsite-backup.log
{
  echo "=== \$(date -Is) ==="
  restic "\${OPT[@]}" cat config >/dev/null 2>&1 || restic "\${OPT[@]}" init
  restic "\${OPT[@]}" backup --one-file-system --exclude-caches ${paths}
  restic "\${OPT[@]}" forget --prune ${BACKUP_OFFSITE_KEEP}
  echo "OK"
} >> "\$LOG" 2>&1 || { logger -t homelab-offsite-backup -p user.err "ÉCHEC, voir \$LOG"; exit 1; }
logger -t homelab-offsite-backup "sauvegarde hors site terminée"
SCRIPT_EOF
    chmod 700 /usr/local/sbin/homelab-offsite-backup.sh

    printf '%s root /usr/local/sbin/homelab-offsite-backup.sh\n' "$BACKUP_OFFSITE_CRON" > /etc/cron.d/homelab-offsite-backup
    chmod 644 /etc/cron.d/homelab-offsite-backup

    info "Sauvegardes hors site : tâche cron '${BACKUP_OFFSITE_CRON}' vers ${BACKUP_RESTIC_REPO}."
    info "Sauvegardes hors site : lance un premier essai avec  ./install.sh --run backup_offsite_run  (journal : /var/log/homelab-offsite-backup.log)."
}

configure_backups() {

    [[ "$ENABLE_BACKUP" == "true" ]] || return 0

    info "Configuration des sauvegardes..."
    configure_vzdump_job
    configure_offsite_backup
}

# Lance la sauvegarde vzdump tout de suite (mêmes réglages que la tâche planifiée).
backup_run_now() {

    local ids
    ids="$(backup_vmid_list)"
    [[ -n "$ids" ]] || die "Aucune VM/CT à sauvegarder."

    info "Sauvegarde immédiate des VM/CT ${ids} vers ${BACKUP_STORAGE} (mode ${BACKUP_MODE})..."
    vzdump $(tr ',' ' ' <<< "$ids") --storage "$BACKUP_STORAGE" --mode "$BACKUP_MODE" \
        --compress "$BACKUP_COMPRESS" --prune-backups "$BACKUP_KEEP"
}

backup_offsite_run() {

    [[ -x /usr/local/sbin/homelab-offsite-backup.sh ]] \
        || die "Copie hors site non configurée : renseigne BACKUP_RESTIC_REPO puis ./install.sh --run configure_offsite_backup"

    /usr/local/sbin/homelab-offsite-backup.sh
    tail -n 15 /var/log/homelab-offsite-backup.log
}

# État : tâche planifiée, dernières sauvegardes, instantanés hors site.
backup_status() {

    echo "--- Tâche planifiée"
    pvesh get /cluster/backup --output-format json 2>/dev/null | jq -r '.[] | "\(.id)  \(.schedule)  VM/CT: \(.vmid)  stockage: \(.storage)  actif: \(.enabled)"' || true

    echo "--- Sauvegardes présentes (${BACKUP_STORAGE})"
    pvesm list "$BACKUP_STORAGE" --content backup 2>/dev/null || true

    if [[ -x /usr/local/sbin/homelab-offsite-backup.sh ]]; then
        echo "--- Hors site (restic)"
        tail -n 8 /var/log/homelab-offsite-backup.log 2>/dev/null || echo "(pas encore exécutée)"
    fi
}

# Fichiers témoins : de vrais docx/jpg/avi, que le serveur de sauvegarde compare d'une
# semaine à l'autre. N'écrase jamais un fichier existant.
# Fichiers témoins de chaque site (groupe et dossiers du site).
create_backup_canaries() {

    local d
    [[ "$BACKUP_CANARY" == "true" ]] || return 0
    for d in "${SITE_LIST[@]}"; do
        site_enter "$d"
        create_site_canaries
        site_leave
    done
}

create_site_canaries() {

    [[ "$BACKUP_CANARY" == "true" ]] || return 0

    local d f
    for d in "${SHARED_DIR}/00_temoin" "${APPS_DIR}/00_temoin"; do
        mkdir -p "$d"

        f="$d/temoin.docx"
        [[ -f "$f" ]] || python3 - "$f" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED)
z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
z.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Fichier temoin de sauvegarde : ne pas modifier ni supprimer.</w:t></w:r></w:p></w:body></w:document>')
z.close()
PY

        f="$d/temoin.jpg"
        [[ -f "$f" ]] || base64 -d > "$f" <<'B64'
/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=
B64

        f="$d/temoin.avi"
        [[ -f "$f" ]] || { printf 'RIFF\x24\x00\x00\x00AVI LIST\x10\x00\x00\x00hdrlavih\x04\x00\x00\x00\x00\x00\x00\x00' > "$f"; head -c 4096 /dev/zero >> "$f"; }

        if [[ "$d" == "${SHARED_DIR}"/* ]] && getent group "$SHARED_GROUP" >/dev/null 2>&1; then
            # Dans SHARED (visible via Samba) : mêmes droits que le reste du partage, pour qu'un
            # ransomware qui passe par Samba (compte fileshare) puisse les chiffrer ET ainsi être détecté.
            chown -R root:"$SHARED_GROUP" "$d"
            chmod 2770 "$d"
            chmod 0660 "$d"/temoin.*
        else
            chmod 644 "$d"/temoin.*
        fi
    done

    info "Sauvegardes : fichiers témoins en place (${SHARED_DIR}/00_temoin, ${APPS_DIR}/00_temoin, site ${SITE_CUR}) : ne pas modifier."
}

# Copie de rsync portant UNE capacité (lecture de tous les fichiers, aucune écriture), réservée au compte
# de tirage. Rappelée par un hook apt pour suivre les mises à jour de sécurité de rsync.
install_pull_rsync_cap() {

    local user="$1" rrsync_src="$2" dir=/usr/local/lib/homelab

    install -d -m 755 "$dir" "$dir/bin"
    install -m 0750 -o root -g "$user" /usr/bin/rsync "$dir/bin/rsync"
    setcap cap_dac_read_search+ep "$dir/bin/rsync"

    getcap "$dir/bin/rsync" | grep -q cap_dac_read_search \
        || die "setcap a échoué sur ${dir}/bin/rsync (système de fichiers sans attributs étendus ?)."

    # rrsync copié : son appel à rsync est redirigé vers la copie à capacité
    install -m 0750 -o root -g "$user" "$rrsync_src" "$dir/rrsync"
    sed -i "s#/usr/bin/rsync#${dir}/bin/rsync#g" "$dir/rrsync"
}

# Autorise le serveur de sauvegarde (tirage) SANS compte root : utilisateur système dédié, sans mot de passe,
# clé publique restreinte (rrsync -ro : lecture seule de DATA_MOUNT, sans terminal ni redirection), et rsync
# n'a que la capacité de LIRE (CAP_DAC_READ_SEARCH) : même un contournement de rrsync ne permettrait aucune écriture.
configure_backup_pull_access() {

    [[ "$ENABLE_BACKUP_PULL" == "true" ]] || return 0

    local user="${BACKUP_PULL_USER:-backup-pull}" home="/var/lib/${BACKUP_PULL_USER:-backup-pull}"

    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != "root" ]] || die "BACKUP_PULL_USER invalide."
    # Clé vide autorisée : les clés peuvent venir de backup_source_export (une par serveur de sauvegarde).
    [[ -z "$BACKUP_PULL_PUBKEY" || "$BACKUP_PULL_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)\ [A-Za-z0-9+/=]+ ]] \
        || die "BACKUP_PULL_PUBKEY invalide : colle le contenu de /root/.ssh/homelab-pull.pub du serveur de sauvegarde (ou laisse vide et utilise backup_source_export)."
    # BACKUP_PULL_FROM facultatif : vide = n'importe quelle IP (IP publique non fixe).
    [[ -z "$BACKUP_PULL_FROM" || "$BACKUP_PULL_FROM" =~ ^[0-9a-zA-Z:.,/*?!-]+$ ]] \
        || die "BACKUP_PULL_FROM invalide (IP, plage, ou vide pour accepter toute IP)."

    command -v rsync  >/dev/null 2>&1 || apt-get install -y rsync >/dev/null
    command -v setcap >/dev/null 2>&1 || apt-get install -y libcap2-bin >/dev/null

    local rrsync
    rrsync="$(command -v rrsync || true)"
    [[ -n "$rrsync" ]] || die "rrsync introuvable (paquet rsync trop ancien ?)."

    create_backup_canaries

    # Compte système : pas de mot de passe, aucun groupe, home appartenant à root (il ne peut pas modifier
    # ses propres clés autorisées ni la commande imposée).
    if ! id "$user" >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$home" --no-create-home --shell /bin/sh \
            --comment "Tirage des sauvegardes (lecture seule)" "$user"
    fi
    passwd -l "$user" >/dev/null 2>&1 || true

    install_pull_rsync_cap "$user" "$rrsync"

    # Hook apt : après une mise à jour de rsync, la copie à capacité est rafraîchie
    cat > /usr/local/sbin/homelab-refresh-rsync-cap <<REFRESH
#!/usr/bin/env bash
# Généré par l'installateur homelab : met à jour la copie de rsync à capacité de lecture.
set -e
install -m 0750 -o root -g ${user} /usr/bin/rsync /usr/local/lib/homelab/bin/rsync
setcap cap_dac_read_search+ep /usr/local/lib/homelab/bin/rsync
REFRESH
    chmod 755 /usr/local/sbin/homelab-refresh-rsync-cap
    printf 'DPkg::Post-Invoke { "[ -x /usr/local/sbin/homelab-refresh-rsync-cap ] && /usr/local/sbin/homelab-refresh-rsync-cap || true"; };\n' \
        > /etc/apt/apt.conf.d/99-homelab-rsync-cap

    local keytype keydata extra=""

    install -d -m 755 -o root -g root "$home" "$home/.ssh"

    # Clés ajoutées par backup_source_export (commentaire homelab-pull-<nom>) : conservées.
    extra="$(grep ' homelab-pull-' "$home/.ssh/authorized_keys" 2>/dev/null || true)"

    {
        if [[ -n "$BACKUP_PULL_PUBKEY" ]]; then
            read -r keytype keydata _ <<< "$BACKUP_PULL_PUBKEY"
            backup_pull_key_line "$keytype" "$keydata" "homelab-pull"
        fi
        [[ -n "$extra" ]] && printf '%s\n' "$extra"
    } > "$home/.ssh/authorized_keys"
    chown root:root "$home/.ssh/authorized_keys"
    chmod 644 "$home/.ssh/authorized_keys"

    # Migration : l'ancienne clé de tirage donnée à root est retirée
    if [[ -f /root/.ssh/authorized_keys ]] && grep -q ' homelab-pull$' /root/.ssh/authorized_keys; then
        sed -i '/ homelab-pull$/d' /root/.ssh/authorized_keys
        info "Sauvegardes : ancienne clé de tirage retirée du compte root."
    fi

    info "Sauvegardes : accès en lecture seule à ${DATA_MOUNT} pour le compte '${user}' (sans root ; ${BACKUP_PULL_FROM:-toute IP})."
    info "Sauvegardes : côté serveur de sauvegarde, mets \"USER\": \"${user}\" dans sources.d/<nom>.json."
}

###############################################################################
#                              FILES CLOUD-INIT                               #
###############################################################################

create_files_cloud_init() {

    info "Création du cloud-init FILES..."

    local SNIPPET="/var/lib/vz/snippets/files-${FILES_ID}.yaml"

    cat > "$SNIPPET" <<EOF
#cloud-config

hostname: ${FILES_HOSTNAME}
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: false
    passwd: ${ROOT_PASSWORD_HASH}

package_update: true

packages:
  - qemu-guest-agent
  - samba
  - samba-common-bin
  - acl
  - attr
  - curl
  - wget
  - ca-certificates
  - fail2ban

write_files:

  - path: /etc/samba/smb.conf
    owner: root:root
    permissions: '0644'
    content: |
      [global]
          workgroup = WORKGROUP
          server string = FILES
          security = user
          map to guest = never
          server min protocol = SMB2
          server max protocol = SMB3
          load printers = no
          printing = bsd
          printcap name = /dev/null
          disable spoolss = yes

      [SHARED]
          path = ${FILES_MOUNT}
          browseable = yes
          read only = no
          writable = yes
          valid users = fileshare
          force user = fileshare
          force group = fileshare
          create mask = 0660
          directory mask = 2770
          inherit permissions = yes
          inherit acls = yes
          ea support = yes
          store dos attributes = yes

  - path: /usr/local/sbin/files-firstboot.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash

      set -Eeuo pipefail

      export DEBIAN_FRONTEND=noninteractive

      # Priorité absolue, avant tout le reste : l'agent QEMU doit être
      # actif dès que possible, quoi qu'il arrive plus loin dans ce
      # script (le reste du script servait avant à le faire, mais trop
      # tard : un échec sur une étape ultérieure - le montage VirtioFS,
      # forcément raté au tout premier boot - empêchait ce script
      # d'atteindre ces lignes à cause de "set -e").
      systemctl enable qemu-guest-agent
      systemctl restart qemu-guest-agent

      SHARED_GROUP="${SHARED_GROUP}"
      SHARED_GID="${SHARED_GID}"
      SHARED_USER="fileshare"
      SHARED_UID="${SHARED_GID}"
      MOUNT_POINT="${FILES_MOUNT}"
      SAMBA_PASSWORD_B64="${SAMBA_PASSWORD_B64}"

      if getent group "\${SHARED_GROUP}" >/dev/null 2>&1; then

          EXISTING_GID="\$(getent group "\${SHARED_GROUP}" | cut -d: -f3)"

          [[ "\${EXISTING_GID}" == "\${SHARED_GID}" ]] \
              || exit 1

      else

          groupadd \
              -g "\${SHARED_GID}" \
              "\${SHARED_GROUP}"
      fi

      if id "\${SHARED_USER}" >/dev/null 2>&1; then

          EXISTING_UID="\$(id -u "\${SHARED_USER}")"
          EXISTING_GID="\$(id -g "\${SHARED_USER}")"

          [[ "\${EXISTING_UID}" == "\${SHARED_UID}" ]] \
              || exit 1

          [[ "\${EXISTING_GID}" == "\${SHARED_GID}" ]] \
              || exit 1

      else

          useradd \
              -u "\${SHARED_UID}" \
              -g "\${SHARED_GID}" \
              -M \
              -s /usr/sbin/nologin \
              "\${SHARED_USER}"
      fi

      mkdir -p "\${MOUNT_POINT}"

      for attempt in {1..20}; do

          if mountpoint -q "\${MOUNT_POINT}"; then
              break
          fi

          if ! mount "\${MOUNT_POINT}"; then
              sleep 2
          fi
      done

      if ! mountpoint -q "\${MOUNT_POINT}"; then
          echo "AVERTISSEMENT: \${MOUNT_POINT} non monté (normal au tout premier boot, le device VirtioFS n'est attaché qu'après le redémarrage prévu par le script d'installation). Poursuite : Samba/Webmin ne dépendent pas de ce montage pour être configurés." >&2
      fi

      SAMBA_PASSWORD_PLAIN="\$(printf '%s' "\${SAMBA_PASSWORD_B64}" | base64 -d)"

      # smbpasswd -s (mode stdin) attend le mot de passe DEUX fois
      # (nouveau + confirmation), chacun terminé par un retour à la
      # ligne - comme "passwd" en interactif. Sans les deux "\n", il
      # échoue avec "Unable to get new password." et le reste du script
      # ne s'exécute jamais (set -e).
      printf '%s\n%s\n' "\${SAMBA_PASSWORD_PLAIN}" "\${SAMBA_PASSWORD_PLAIN}" |
          smbpasswd -a -s "\${SHARED_USER}"

      unset SAMBA_PASSWORD_PLAIN

      test "\$(pdbedit -L | cut -d: -f1 | grep -Fx "\${SHARED_USER}" | wc -l)" -eq 1

      # samba-ad-dc (contrôleur de domaine Active Directory complet) est
      # tiré comme dépendance du paquet "samba" sur Debian 13 et
      # s'auto-active, alors qu'on veut juste un partage de fichiers
      # simple (smbd/nmbd). On le désactive explicitement pour éviter
      # tout conflit de port avec smbd - il ne serait de toute façon pas
      # fonctionnel sans provisioning d'un domaine.
      systemctl disable --now samba-ad-dc >/dev/null 2>&1 || true

      systemctl enable smbd
      systemctl restart smbd

      systemctl is-active --quiet smbd

      #########################################################################
      #                              WEBMIN                                    #
      #########################################################################

      if ! dpkg-query -W -f='\${Status}' webmin 2>/dev/null |
          grep -q '^install ok installed$'; then

          cd /root

          wget \
              --https-only \
              -O webmin-setup-repo.sh \
              https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh

          chmod 700 webmin-setup-repo.sh

          # Le script de dépôt Webmin peut demander une confirmation (y/N) ;
          # sans terminal (cloud-init) il n'aurait aucune réponse : on la fournit.
          sh ./webmin-setup-repo.sh <<< "y"

          apt-get update

          apt-get install -y \
              --install-recommends \
              webmin
      fi

      systemctl enable webmin
      systemctl restart webmin

      systemctl is-active --quiet webmin

      test -x /usr/sbin/webmin
      test -d /etc/webmin

      rm -f /root/webmin-setup-repo.sh

  - path: /etc/fstab
    append: true
    content: |

      files_shared ${FILES_MOUNT} virtiofs defaults,_netdev,nofail 0 0

runcmd:
  - [bash, /usr/local/sbin/files-firstboot.sh]
EOF

    chmod 600 "$SNIPPET"
}

###############################################################################
#                              FILES VM                                       #
###############################################################################

create_files_vm() {

    create_files_cloud_init

    create_cloud_vm \
        "$FILES_ID" \
        "$FILES_HOSTNAME" \
        "$FILES_CORES" \
        "$FILES_MEMORY" \
        "$FILES_DISK" \
        "$FILES_IP" \
        "$FILES_GATEWAY" \
        "files-${FILES_ID}.yaml"

    info "Configuration VirtioFS de la VM ${FILES_ID}..."

    qm set "$FILES_ID" \
        --virtiofs0 "dirid=${VIRTIOFS_DIR_ID},cache=auto,expose-acl=1"

    if qm status "$FILES_ID" |
        grep -q "status: running"; then

        info "Attente du qemu-guest-agent sur la VM FILES..."

        wait_for_qemu_agent "$FILES_ID" \
            || warn "L'agent QEMU ne répond pas après 5 minutes, tentative d'arrêt quand même."

        info "Attente de la fin du cloud-init (Samba/Webmin) sur la VM FILES, ça peut prendre quelques minutes..."

        wait_for_cloud_init "$FILES_ID" \
            || warn "cloud-init ne signale pas 'done' après 7,5 minutes, tentative d'arrêt quand même."

        qm shutdown "$FILES_ID" --timeout 60 \
            || die "Impossible d'arrêter proprement la VM FILES."

        for _ in {1..30}; do

            if qm status "$FILES_ID" |
                grep -q "status: stopped"; then
                break
            fi

            sleep 1
        done

        qm status "$FILES_ID" |
            grep -q "status: stopped" \
            || die "La VM FILES ne s'est pas arrêtée."
    fi

    qm start "$FILES_ID"

    info "VM FILES ${FILES_ID} créée."
}


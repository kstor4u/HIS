#!/usr/bin/env bash
# build.sh : assemble les modules (ordre du MANIFEST) en un script unique sur la sortie standard.
#   ./build.sh > proxmox-homelab-install-vX.Y.Z.sh && chmod +x proxmox-homelab-install-vX.Y.Z.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
while IFS= read -r mod; do
    [[ -z "$mod" || "$mod" == \#* ]] && continue
    cat "$mod"
done < MANIFEST

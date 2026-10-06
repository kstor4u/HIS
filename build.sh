#!/usr/bin/env bash
# Reconstruit le script monolithique depuis les modules : ./build.sh > proxmox-homelab-install.sh
set -euo pipefail
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
first=1
while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    cat "$d/$m"
done < "$d/MANIFEST"

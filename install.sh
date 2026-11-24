#!/usr/bin/env bash
# install.sh : lanceur de la version modulaire. Charge les modules listés dans MANIFEST, dans l'ordre, dans CE shell
# (équivaut au script monolithe : ./build.sh > proxmox-homelab-install.sh). Usage identique : sudo ./install.sh [options]
_HOMELAB_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS= read -r _homelab_mod; do
    [[ -z "$_homelab_mod" || "$_homelab_mod" == \#* ]] && continue
    # shellcheck disable=SC1090
    source "${_HOMELAB_SRC_DIR}/${_homelab_mod}"
done < "${_HOMELAB_SRC_DIR}/MANIFEST"

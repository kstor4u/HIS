#!/usr/bin/env bash
# Point d'entrée modulaire : charge les modules listés dans MANIFEST (dans l'ordre)
# puis lance main() (définie dans main.sh). Usage : ./install.sh [fichier-reponses.conf]
_HL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS= read -r _m; do
    [[ -z "$_m" ]] && continue
    # shellcheck disable=SC1090
    source "${_HL_DIR}/${_m}"
done < "${_HL_DIR}/MANIFEST"

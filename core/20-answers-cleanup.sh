###############################################################################
#                              FICHIER DE RÉPONSES                            #
###############################################################################

# Charge un fichier de réponses (simples affectations bash) s'il existe,
# pour éviter de retaper mots de passe / email / wallet à chaque test.
# Voir proxmox-homelab-answers.conf.example pour le format attendu.
load_answers_file() {

    if [[ -f "$ANSWERS_FILE" ]]; then

        info "Chargement des réponses depuis ${ANSWERS_FILE}..."

        # shellcheck disable=SC1090
        source "$ANSWERS_FILE"

        ANSWERS_FILE_LOADED=true

    else

        info "Pas de fichier de réponses (${ANSWERS_FILE} introuvable) : mode interactif complet."
    fi
}

###############################################################################
#                              NETTOYAGE PRÉALABLE                            #
###############################################################################

# Détecte les VM/CT homelab déjà existantes et propose de les supprimer
# avant de continuer, pour repartir vraiment de zéro sans avoir à le
# faire à la main à chaque tentative. Le disque DATA n'est jamais touché
# ici (voir prepare_data_disk(), idempotent séparément).
propose_cleanup_existing() {

    info "Vérification des VM/CT existantes..."

    local -a existing_vms=()
    local -a existing_cts=()

    if [[ "$ENABLE_FILES" == "true" ]] && qm status "$FILES_ID" >/dev/null 2>&1; then
        existing_vms+=("${FILES_ID}:FILES")
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]] && qm status "$DOCKER_ID" >/dev/null 2>&1; then
        existing_vms+=("${DOCKER_ID}:DOCKER")
    fi

    if [[ "$ENABLE_SWAG" == "true" ]] && pct status "$SWAG_ID" >/dev/null 2>&1; then
        existing_cts+=("${SWAG_ID}:SWAG")
    fi

    if [[ "$ENABLE_WIREGUARD" == "true" ]] && pct status "$WG_ID" >/dev/null 2>&1; then
        existing_cts+=("${WG_ID}:WIREGUARD")
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]] && pct status "$XMRIG_ID" >/dev/null 2>&1; then
        existing_cts+=("${XMRIG_ID}:XMRIG")
    fi

    if ((${#existing_vms[@]} == 0 && ${#existing_cts[@]} == 0)); then
        info "Aucune VM/CT homelab existante détectée, rien à nettoyer."
        return 0
    fi

    echo
    echo "VM/CT homelab déjà existantes détectées :"

    local entry
    for entry in "${existing_vms[@]}" "${existing_cts[@]}"; do
        echo "  - ${entry%%:*} (${entry##*:})"
    done

    echo
    echo "(le disque DATA n'est jamais touché par cette étape : il est géré séparément et n'est reformaté que s'il ne porte pas déjà le label DATA)"
    echo

    local answer

    if [[ -n "$CLEANUP_EXISTING_VMS" ]]; then

        answer="$CLEANUP_EXISTING_VMS"
        info "Suppression préalable définie via ${ANSWERS_FILE} : ${answer}"

    elif [[ "$ANSWERS_FILE_LOADED" == "true" ]]; then

        info "Mode fichier de réponses sans CLEANUP_EXISTING_VMS défini : conservation par défaut (pas de suppression automatique)."
        answer="non"

    else

        read -r -p "Supprimer ces VM/CT avant de continuer ? (oui/non) : " answer
    fi

    if [[ "$answer" != "oui" && "$answer" != "true" ]]; then
        info "VM/CT existantes conservées : les étapes de création correspondantes seront simplement sautées (idempotence)."
        return 0
    fi

    for entry in "${existing_vms[@]}"; do

        local vmid="${entry%%:*}"

        info "Suppression de la VM ${entry%%:*} (${entry##*:})..."

        qm stop "$vmid" --skiplock >/dev/null 2>&1 || true

        qm destroy "$vmid" --purge --destroy-unreferenced-disks 1 \
            || warn "Échec de la suppression de la VM ${vmid}, vérifie manuellement (qm destroy ${vmid} --purge)."
    done

    for entry in "${existing_cts[@]}"; do

        local ctid="${entry%%:*}"

        info "Suppression du CT ${entry%%:*} (${entry##*:})..."

        pct stop "$ctid" --skiplock >/dev/null 2>&1 || true

        pct destroy "$ctid" --purge \
            || warn "Échec de la suppression du CT ${ctid}, vérifie manuellement (pct destroy ${ctid} --purge)."
    done

    info "Nettoyage terminé."
}


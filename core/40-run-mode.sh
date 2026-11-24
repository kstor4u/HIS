###############################################################################
#        MODE « run » : APPLIQUER SEULEMENT LES PARAMÈTRES, SANS RÉINSTALLER    #
###############################################################################

# ENABLE_<SERVICE>=run : la VM/CT existe déjà, le script ne la crée pas, ne la supprime pas, ne télécharge rien
# et n'installe aucun paquet dedans : il ne fait que ré-appliquer les PARAMÈTRES du fichier de réponses
# (sous-domaines, DNS, mémoire/cœurs, modèles IA, redirections de ports, notifications...).
# Si le service n'existe pas encore, "run" se comporte comme "keep" (il est installé).
# Quand TOUS les services actifs sont en "run", les étapes d'installation de l'hôte (dépôts, paquets, pont réseau,
# NAT, disque DATA, stockage, images) sont aussi sautées : lancement beaucoup plus court, aucune écriture inutile.
# Limite : ce qui est écrit dans une VM/CT à sa création (cloud-init, docker-compose.yml de Nextcloud/Immich...)
# n'est pas régénéré ; utilise cleanup pour recréer, ou les fonctions de réparation (./install.sh --run <fonction>).

declare -gA SERVICE_RUN=()
RUN_FAST=false

# $1 = nom de la variable ENABLE_*. Vrai si le service est en mode run ET existe déjà.
svc_run_only() { [[ "${SERVICE_RUN[$1]:-}" == "true" ]]; }

# Fixe RUN_FAST=true si au moins un service est actif et que tous les services actifs sont en mode run.
run_mode_detect() {

    local var active=0 runs=0

    for var in ENABLE_FILES ENABLE_DOCKER ENABLE_SWAG ENABLE_WIREGUARD ENABLE_XMRIG ENABLE_NODE ENABLE_MAIL ENABLE_DNS ENABLE_MONITOR ENABLE_AI; do
        [[ "${!var:-false}" == "true" ]] || continue
        active=$((active + 1))
        svc_run_only "$var" && runs=$((runs + 1))
    done

    RUN_FAST=false
    if (( runs > 0 && runs == active )); then
        RUN_FAST=true
        info "Mode run : tous les services actifs existent déjà, seules les modifications de paramètres sont appliquées (installation de l'hôte sautée)."
    elif (( runs > 0 )); then
        info "Mode run : ${runs} service(s) sur ${active} en reconfiguration seule ; les autres suivent leur mode (keep/cleanup)."
    fi
}

###############################################################################
#                   RECONFIGURATION PAR SERVICE (SANS INSTALLATION)           #
###############################################################################

reconfigure_files() {
    info "FILES : mode run, aucune modification de la VM (les partages Samba sont définis à la création ; redirection Samba déjà réappliquée)."
    qm status "$FILES_ID" 2>/dev/null | grep -q running || qm start "$FILES_ID" >/dev/null 2>&1 || true
}

reconfigure_docker() {
    info "DOCKER : mode run, application des fichiers docker-compose existants (docker compose up -d ne recrée que ce qui a changé)..."
    qm status "$DOCKER_ID" 2>/dev/null | grep -q running || qm start "$DOCKER_ID" >/dev/null 2>&1 || true
    verify_docker_shared_storage "$DOCKER_ID"
    start_docker_apps "$DOCKER_ID"
}

reconfigure_swag() {
    info "SWAG : mode run, sous-domaines, certificat et configuration des sites..."
    pct status "$SWAG_ID" 2>/dev/null | grep -q running || pct start "$SWAG_ID" >/dev/null 2>&1 || true
    repair_swag_subdomains
}

reconfigure_node() {
    info "NODE : mode run, aucun paramètre à réappliquer (config créée avec le CT ; ./install.sh --run node_restart pour redémarrer)."
    pct status "$NODE_ID" 2>/dev/null | grep -q running || pct start "$NODE_ID" >/dev/null 2>&1 || true
}

reconfigure_mail() {
    info "MAIL : mode run, synchronisation des certificats..."
    pct status "$MAIL_ID" 2>/dev/null | grep -q running || pct start "$MAIL_ID" >/dev/null 2>&1 || true
    mail_sync_certs || warn "MAIL : synchronisation des certificats échouée (./install.sh --run mail_check)."
}

reconfigure_dns() {
    info "DNS : mode run, réapplication de la configuration AdGuard Home..."
    pct status "$DNS_ID" 2>/dev/null | grep -q running || pct start "$DNS_ID" >/dev/null 2>&1 || true
    dns_zone_generate || true
    dns_configure || warn "DNS : configuration non réappliquée (./install.sh --run dns_configure)."
}

reconfigure_monitor() {
    info "MONITOR : mode run, régénération de la page Homepage..."
    pct status "$MONITOR_ID" 2>/dev/null | grep -q running || pct start "$MONITOR_ID" >/dev/null 2>&1 || true
    [[ "${MONITOR_HOMEPAGE:-false}" == "true" ]] && monitor_homepage_regen || true
}

reconfigure_xmrig() {
    info "XMRIG : mode run, réapplication du service de surveillance sur l'hôte..."
    pct status "$XMRIG_ID" 2>/dev/null | grep -q running || pct start "$XMRIG_ID" >/dev/null 2>&1 || true
    create_xmrig_monitor
}

###############################################################################
#                              NETTOYAGE PRÉALABLE                            #
###############################################################################

# Le disque DATA n'est jamais touché ici (voir prepare_data_disk(), idempotent
# séparément).

# Interprète une valeur de mode de service. Résultat dans SERVICE_MODE :
# keep | run | cleanup | remove | skip | "" (vide = à demander). Retourne 1 si la valeur est inconnue.
service_mode_parse() {

    SERVICE_MODE=""

    case "${1,,}" in
        keep | true)    SERVICE_MODE="keep" ;;
        run | config)   SERVICE_MODE="run" ;;
        skip | ignore)  SERVICE_MODE="skip" ;;
        cleanup)        SERVICE_MODE="cleanup" ;;
        remove | false) SERVICE_MODE="remove" ;;
        "")             ;;
        *)              return 1 ;;
    esac
}

# Supprime une VM ("vm") ou un CT ("ct"). Avant de détruire SWAG, sauvegarde
# ses certificats Let's Encrypt (limite de 5 certificats identiques/semaine) :
# les restaurer ensuite avec ./install.sh --run swag_restore_certs
destroy_homelab_resource() {

    local kind="$1" id="$2" label="$3"

    if [[ "$label" == "SWAG" ]] && declare -F swag_backup_certs >/dev/null; then

        if pct status "$id" 2>/dev/null | grep -q running; then
            swag_backup_certs || warn "Sauvegarde des certificats SWAG impossible (voir plus haut)."
        else
            warn "CT SWAG arrêté : certificats Let's Encrypt non sauvegardés."
        fi
    fi

    if [[ "$kind" == "vm" ]]; then

        info "Suppression de la VM ${id} (${label})..."

        qm stop "$id" --skiplock >/dev/null 2>&1 || true

        qm destroy "$id" --purge --destroy-unreferenced-disks 1 \
            || warn "Échec de la suppression de la VM ${id}, vérifie manuellement (qm destroy ${id} --purge)."

        # Les données de Nextcloud vivent sur l'HÔTE (APPS_DIR, partagé en virtiofs), pas dans la VM :
        # la VM recréée a une base et une config NEUVES, alors que l'ancien dossier de données (.ncdata,
        # appdata_<ancienne instance>, dossiers utilisateurs) est resté. Nextcloud refuse alors de
        # s'installer (status.php : "installed":false). On met l'ancien dossier de côté (rien n'est supprimé).
        if [[ "$label" == "DOCKER" && -f "${APPS_DIR}/nextcloud/.ncdata" ]]; then
            local aside="${APPS_DIR}/nextcloud.ancien-$(date +%Y%m%d-%H%M%S)"
            if mv "${APPS_DIR}/nextcloud" "$aside" && mkdir "${APPS_DIR}/nextcloud"; then
                chown --reference="$aside" "${APPS_DIR}/nextcloud" 2>/dev/null || true
                chmod --reference="$aside" "${APPS_DIR}/nextcloud" 2>/dev/null || true
                warn "Nextcloud : l'ancien dossier de données est conservé dans ${aside} (le nouveau Nextcloud repart d'un dossier vide). Tu peux le supprimer quand tu n'en as plus besoin."
            else
                warn "Nextcloud : ancien dossier de données ${APPS_DIR}/nextcloud à vider à la main avant la réinstallation (sinon l'installation échoue)."
            fi
        fi
    else

        info "Suppression du CT ${id} (${label})..."

        pct stop "$id" --skiplock >/dev/null 2>&1 || true

        pct destroy "$id" --purge \
            || warn "Échec de la suppression du CT ${id}, vérifie manuellement (pct destroy ${id} --purge)."
    fi
}

# Nettoie ce qu'un service "remove" laisse sur l'hôte : redirections DNAT vers
# son IP (sinon règles orphelines persistées) et, pour XMRIG, le service
# xmrig-monitor de l'hôte.
purge_service_leftovers() {

    local label="$1" ip="$2" rule changed=false

    if [[ "$label" == "XMRIG" ]] && [[ -f /etc/systemd/system/xmrig-monitor.service ]]; then
        info "XMRIG : arrêt et désactivation de xmrig-monitor.service sur l'hôte."
        systemctl disable --now xmrig-monitor.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xmrig-monitor.service /usr/local/sbin/xmrig-monitor.sh
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    command -v iptables >/dev/null 2>&1 || return 0

    while read -r rule; do
        [[ -n "$rule" ]] || continue
        # shellcheck disable=SC2086
        iptables -t nat ${rule/-A /-D } && changed=true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--to-destination ${ip}:" || true)

    if [[ "$changed" == "true" ]]; then
        info "${label} : redirections de ports vers ${ip} supprimées."
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

# Décide, service par service, de la suite (voir ENABLE_* dans core/00-config.sh),
# supprime ce qui doit l'être, puis fixe ENABLE_<SERVICE> à "true" ou "false"
# pour toute la suite du script. Appelée avant configure_variables.
resolve_service_modes() {

    info "Vérification des VM/CT existants..."

    local entry label kind id var raw exists answer ip_var
    local -a services=(
        "FILES:vm:${FILES_ID}:ENABLE_FILES"
        "DOCKER:vm:${DOCKER_ID}:ENABLE_DOCKER"
        "SWAG:ct:${SWAG_ID}:ENABLE_SWAG"
        "WIREGUARD:ct:${WG_ID}:ENABLE_WIREGUARD"
        "XMRIG:ct:${XMRIG_ID}:ENABLE_XMRIG"
        "NODE:ct:${NODE_ID}:ENABLE_NODE"
        "MAIL:ct:${MAIL_ID}:ENABLE_MAIL"
        "DNS:ct:${DNS_ID}:ENABLE_DNS"
        "MONITOR:ct:${MONITOR_ID}:ENABLE_MONITOR"
        "AI:ct:${AI_ID}:ENABLE_AI"
    )

    SERVICE_RUN=()

    echo
    echo "(le disque DATA n'est jamais touché par cette étape : il est géré séparément et n'est reformaté que s'il ne porte pas déjà le label DATA)"
    echo

    for entry in "${services[@]}"; do

        IFS=: read -r label kind id var <<< "$entry"
        raw="${!var:-}"

        exists=false
        if [[ "$kind" == "vm" ]]; then
            qm status "$id" >/dev/null 2>&1 && exists=true
        else
            pct status "$id" >/dev/null 2>&1 && exists=true
        fi

        if ! service_mode_parse "$raw"; then
            warn "${var}='${raw}' non reconnu (attendu : keep, run, cleanup, remove, skip ou vide) : traité comme vide."
        fi

        if [[ -z "$SERVICE_MODE" ]]; then

            if [[ "$exists" != "true" ]]; then

                SERVICE_MODE="keep"

            else

                echo "${label} (${id}) existe déjà."
                read -r -p "  keep = conserver, run = appliquer seulement les paramètres, cleanup = supprimer puis recréer, remove = supprimer sans réinstaller [keep] : " answer \
                    || answer=""

                case "${answer,,}" in
                    c) answer="cleanup" ;;
                    r) answer="remove" ;;
                    k) answer="keep" ;;
                    p) answer="run" ;;
                esac

                if ! service_mode_parse "$answer"; then
                    warn "Réponse '${answer}' non reconnue : conservation."
                fi

                [[ -n "$SERVICE_MODE" ]] || SERVICE_MODE="keep"
            fi
        fi

        # Mode retenu, mémorisé pour le fichier de réponses généré (cleanup devient keep : déjà nettoyé)
        SERVICE_MODES_USED["$var"]="$SERVICE_MODE"
        [[ "$SERVICE_MODE" != "cleanup" ]] || SERVICE_MODES_USED["$var"]="keep"

        case "$SERVICE_MODE" in

            skip)
                printf -v "$var" '%s' "false"
                info "${label} (${id}) : ignoré, non installé et laissé tel quel (${var}=skip)."
                ;;

            run)
                printf -v "$var" '%s' "true"
                if [[ "$exists" == "true" ]]; then
                    SERVICE_RUN["$var"]="true"
                    info "${label} (${id}) : existe, seuls les paramètres seront réappliqués (${var}=run)."
                else
                    info "${label} (${id}) : absent, sera installé (${var}=run)."
                fi
                ;;

            keep)
                printf -v "$var" '%s' "true"
                if [[ "$exists" == "true" ]]; then
                    info "${label} (${id}) : conservé, l'étape de création sera sautée (${var}=keep)."
                else
                    info "${label} (${id}) : sera installé (${var}=keep)."
                fi
                ;;

            cleanup)
                printf -v "$var" '%s' "true"
                if [[ "$exists" == "true" ]]; then
                    info "${label} (${id}) : suppression puis recréation (${var}=cleanup)."
                    destroy_homelab_resource "$kind" "$id" "$label"
                else
                    info "${label} (${id}) : absent, sera installé (${var}=cleanup)."
                fi
                ;;

            remove)
                printf -v "$var" '%s' "false"
                if [[ "$exists" == "true" ]]; then
                    info "${label} (${id}) : suppression, non réinstallé (${var}=remove)."
                    destroy_homelab_resource "$kind" "$id" "$label"
                else
                    info "${label} (${id}) : non installé (${var}=remove)."
                fi
                ip_var="${label/WIREGUARD/WG}_IP"
                [[ -n "${!ip_var:-}" ]] && purge_service_leftovers "$label" "${!ip_var%%/*}"
                ;;
        esac
    done

    run_mode_detect
    info "Nettoyage terminé."
}

# Convertit ENABLE_* en true/false SANS rien supprimer ni demander (mode
# --run : la décision a déjà été prise lors de l'installation).
normalize_service_flags() {

    local var

    for var in ENABLE_FILES ENABLE_DOCKER ENABLE_SWAG ENABLE_WIREGUARD ENABLE_XMRIG ENABLE_NODE ENABLE_MAIL ENABLE_DNS ENABLE_MONITOR ENABLE_AI; do

        service_mode_parse "${!var:-}" || true

        if [[ "$SERVICE_MODE" == "remove" || "$SERVICE_MODE" == "skip" ]]; then
            printf -v "$var" '%s' "false"
        else
            printf -v "$var" '%s' "true"
        fi
    done
}

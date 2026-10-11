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

# Le disque DATA n'est jamais touché ici (voir prepare_data_disk(), idempotent
# séparément).

# Interprète une valeur de mode de service. Résultat dans SERVICE_MODE :
# keep | cleanup | remove | "" (vide = à demander). Retourne 1 si la valeur est inconnue.
service_mode_parse() {

    SERVICE_MODE=""

    case "${1,,}" in
        keep | true)    SERVICE_MODE="keep" ;;
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
    )

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
            warn "${var}='${raw}' non reconnu (attendu : keep, cleanup, remove ou vide) : traité comme vide."
        fi

        if [[ -z "$SERVICE_MODE" ]]; then

            if [[ "$exists" != "true" ]]; then

                SERVICE_MODE="keep"

            else

                echo "${label} (${id}) existe déjà."
                read -r -p "  keep = conserver, cleanup = supprimer puis recréer, remove = supprimer sans réinstaller [keep] : " answer \
                    || answer=""

                case "${answer,,}" in
                    c) answer="cleanup" ;;
                    r) answer="remove" ;;
                    k) answer="keep" ;;
                esac

                if ! service_mode_parse "$answer"; then
                    warn "Réponse '${answer}' non reconnue : conservation."
                fi

                [[ -n "$SERVICE_MODE" ]] || SERVICE_MODE="keep"
            fi
        fi

        case "$SERVICE_MODE" in

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

    info "Nettoyage terminé."
}

# Convertit ENABLE_* en true/false SANS rien supprimer ni demander (mode
# --run : la décision a déjà été prise lors de l'installation).
normalize_service_flags() {

    local var

    for var in ENABLE_FILES ENABLE_DOCKER ENABLE_SWAG ENABLE_WIREGUARD ENABLE_XMRIG; do

        service_mode_parse "${!var:-}" || true

        if [[ "$SERVICE_MODE" == "remove" ]]; then
            printf -v "$var" '%s' "false"
        else
            printf -v "$var" '%s' "true"
        fi
    done
}

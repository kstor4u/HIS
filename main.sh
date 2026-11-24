###############################################################################
#                                  MAIN                                       #
###############################################################################

main() {

    check_root
    check_proxmox

    load_answers_file
    answers_offer_template
    answers_check_new_vars
    validate_subdomains
    validate_sites
    configure_hostname
    configure_lan_ip_interactive

    resolve_service_modes
    configure_variables
    [[ "$ENABLE_AI" == "true" ]] && ai_preflight
    answers_save_run

    if [[ "$RUN_FAST" != "true" ]]; then
        configure_repositories
        install_host_dependencies
        disable_subscription_nag
    fi
    configure_admin_user
    configure_ssh_root_login
    if [[ "$SSH_EXTERNAL" == "true" ]]; then
        ssh_external_enable
    elif [[ -f "$SSH_EXT_EXPIRES" ]]; then
        info "SSH externe : SSH_EXTERNAL=false, fermeture de l'accès ouvert précédemment."
        ssh_external_off
    fi
    configure_fail2ban_host

    if [[ "$RUN_FAST" != "true" ]]; then
        configure_private_bridge
        configure_forwarding
        configure_nat
    fi

    if [[ "$ENABLE_FILES" == "true" ]]; then
        configure_samba_port_forward
    fi

    configure_web_port_forwards

    if [[ "$RUN_FAST" != "true" ]]; then
        prepare_data_disk
        configure_trim
        create_data_tree
        sites_tree_extra

        configure_proxmox_storage
        configure_virtiofs_mapping

        download_debian_image
        configure_local_snippets
    fi

    check_guest_storage

    if [[ "$ENABLE_FILES" == "true" ]]; then
        if svc_run_only ENABLE_FILES; then reconfigure_files; else create_files_vm; fi
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        generate_app_secrets
        secrets_persist
        answers_save_run
        if svc_run_only ENABLE_DOCKER; then reconfigure_docker; else create_docker_vm; fi
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then
        if svc_run_only ENABLE_SWAG; then reconfigure_swag; else create_swag_ct; fi
        portal_apply
        answers_save_run
    fi

    if [[ "$ENABLE_WIREGUARD" == "true" ]]; then
        deploy_wireguard
    fi

    if [[ "$ENABLE_NODE" == "true" ]]; then
        if svc_run_only ENABLE_NODE; then reconfigure_node; else create_node_ct; fi
        secrets_persist
    fi

    if [[ "$ENABLE_MAIL" == "true" ]]; then
        if svc_run_only ENABLE_MAIL; then reconfigure_mail; else create_mail_ct; fi
        secrets_persist
    fi

    if [[ "$ENABLE_DNS" == "true" ]]; then
        if svc_run_only ENABLE_DNS; then reconfigure_dns; else create_dns_ct; fi
        secrets_persist
    fi

    if [[ "$ENABLE_MONITOR" == "true" ]]; then
        if svc_run_only ENABLE_MONITOR; then reconfigure_monitor; else create_monitor_ct; fi
        secrets_persist
    fi

    if [[ "$ENABLE_AI" == "true" ]]; then
        if svc_run_only ENABLE_AI; then
            ai_reconfigure
        else
            ai_host_gpu_setup
            create_ai_ct
        fi
    fi

    if [[ "$ENABLE_CROWDSEC" == "true" && "$ENABLE_SWAG" == "true" ]]; then
        configure_crowdsec
    fi

    if [[ "$ENABLE_ARR" == "true" && "$ENABLE_DOCKER" == "true" ]]; then
        deploy_arr_stack
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]]; then
        configure_hugepages
        configure_msr_optimization
        if svc_run_only ENABLE_XMRIG; then
            reconfigure_xmrig
        else
            create_xmrig_ct
            create_xmrig_monitor
        fi
    fi

    configure_backups
    configure_backup_pull_access
    backup_source_auto
    configure_usb_export
    [[ "${ENABLE_BACKUP_USB:-false}" == "true" ]] && usb_marker_generate tous

    configure_notify
    configure_pool_guard
    configure_db_dump
    configure_restore_test
    configure_docker_update
    dns_zone_generate || true

    if [[ "$ENABLE_FILES" == "true" ]]; then
        sleep 10
        verify_files
    fi

    verify_docker_apps
    nextcloud_post_install || true
    verify_installation
    images_cleanup
    secrets_persist
    show_summary
}

# Raccourcis : ./install.sh --ssh_external_expand 7  ==  ./install.sh --run ssh_external_expand 7
case "${1:-}" in
    --sites_status | --sites-status | --site_add | --site-add | \
    --ssh_external_on | --ssh_external_off | --ssh_external_expand | --ssh_external_status | --ssh_external_diag | --ssh_key_sync | \
    --ssh-external-on | --ssh-external-off | --ssh-external-expand | --ssh-external-status | --ssh-external-diag | --ssh-key-sync)
        _fn="${1#--}"; _fn="${_fn//-/_}"; shift
        set -- --run "$_fn" "$@"
        ;;
esac

if [[ "${1:-}" == "--run" ]]; then
    # Exécute une seule fonction (réparations à chaud, voir tools/10-repair.sh)
    # ANSWERS_FILE valait "--run" (premier argument) : on revient au fichier par
    # défaut et on le charge s'il existe (DOMAIN, ENABLE_*, etc. cohérents).
    shift
    ANSWERS_FILE="./proxmox-homelab-answers.json"
    if [[ -f "$ANSWERS_FILE" ]]; then
        load_answers_file
    fi
    normalize_service_flags
    normalize_subdomains
    resolve_guest_storage
    sites_load
    "$@"
else
    main "$@"
fi
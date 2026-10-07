###############################################################################
#                                  MAIN                                       #
###############################################################################

main() {

    check_root
    check_proxmox

    load_answers_file
    configure_lan_ip_interactive

    propose_cleanup_existing
    configure_variables

    configure_repositories
    install_host_dependencies
    configure_fail2ban_host

    configure_private_bridge
    configure_forwarding
    configure_nat

    if [[ "$ENABLE_FILES" == "true" ]]; then
        configure_samba_port_forward
    fi

    configure_web_port_forwards

    prepare_data_disk
    create_data_tree

    configure_proxmox_storage
    configure_virtiofs_mapping

    download_debian_image
    configure_local_snippets

    if [[ "$ENABLE_FILES" == "true" ]]; then
        create_files_vm
    fi

    if [[ "$ENABLE_DOCKER" == "true" ]]; then
        generate_app_secrets
        create_docker_vm
    fi

    if [[ "$ENABLE_SWAG" == "true" ]]; then
        create_swag_ct
    fi

    if [[ "$ENABLE_WIREGUARD" == "true" ]]; then
        deploy_wireguard
    fi

    if [[ "$ENABLE_XMRIG" == "true" ]]; then
        configure_hugepages
        configure_msr_optimization
        create_xmrig_ct
        create_xmrig_monitor
    fi

    if [[ "$ENABLE_FILES" == "true" ]]; then
        sleep 10
        verify_files
    fi

    verify_docker_apps
    verify_installation
    show_summary
}

if [[ "${1:-}" == "--run" ]]; then
    # Exécute une seule fonction (réparations à chaud, voir tools/10-repair.sh)
    # ANSWERS_FILE valait "--run" (premier argument) : on revient au fichier par
    # défaut et on le charge s'il existe (DOMAIN, ENABLE_*, etc. cohérents).
    shift
    ANSWERS_FILE="./proxmox-homelab-answers.conf"
    if [[ -f "$ANSWERS_FILE" ]]; then
        load_answers_file
    fi
    "$@"
else
    main "$@"
fi
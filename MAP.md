# MAP — proxmox-homelab-install v2.26.1 (modulaire)

Chargement dans l'ordre de `MANIFEST` via `install.sh`. `./build.sh > fichier.sh` régénère le script monolithique (2.26.1 = original octet pour octet ; depuis 2.26.2 : correctifs).

**Règle** : pour une modification, ne charger que `MAP.md` + le(s) module(s) concerné(s). Toutes les variables sont dans `core/00-config.sh`.

| Module | Lignes | Contenu / fonctions (nom:ligne) |
|---|---|---|
| `core/00-config.sh` | 350 | Toutes les variables de config (IDs, IP, ressources, ports, apps, XMRIG, domaine) + HOST_PACKAGES + globales. Fonctions : `detect_lan_ip`:61 |
| `core/10-logging-checks.sh` | 73 | Logging (tee), log/info/warn/die, trap ERR, check_root, check_proxmox. Fonctions : `log`:11, `info`:21, `warn`:25, `die`:29, `check_root`:48, `check_proxmox`:53 |
| `core/20-answers-cleanup.sh` | 125 | Fichier de réponses (.conf) + proposition de suppression des VM/CT existants. Fonctions : `load_answers_file`:8, `propose_cleanup_existing`:33 |
| `core/30-variables-secrets.sh` | 284 | configure_variables (questions interactives) + generate_app_secrets. Fonctions : `configure_variables`:5, `generate_app_secrets`:250 |
| `host/10-apt.sh` | 203 | Dépôts APT Proxmox + dépendances hôte (simulation APT sécurisée) + disable_subscription_nag (fenêtre d'abonnement). Fonctions : `configure_repositories`:5, `install_host_dependencies`:46, `disable_subscription_nag`:148 |
| `host/20-bridges-lan.sh` | 286 | vmbr1 privé, bascule LAN DHCP/statique, IP LAN interactive. Fonctions : `configure_private_bridge`:5, `switch_lan_to_dhcp`:45, `detect_lan_mode`:107, `switch_lan_to_static`:125, `configure_lan_ip_interactive`:199 |
| `host/30-firewall.sh` | 170 | fail2ban hôte, ip_forward, NAT, port forwards (Samba, web). Fonctions : `configure_fail2ban_host`:10, `configure_forwarding`:23, `configure_nat`:41, `add_dnat_forward`:83, `configure_samba_port_forward`:105, `configure_web_port_forwards`:132 |
| `host/40-storage.sh` | 317 | Disque DATA (formatage), arborescence, storage Proxmox, mapping virtiofs. Fonctions : `release_data_disk`:13, `prepare_data_disk`:58, `prepare_apps_data_dirs`:158, `create_data_tree`:177, `configure_proxmox_storage`:233, `configure_virtiofs_mapping`:278 |
| `vm/10-common.sh` | 283 | Image Debian cloud, snippets, attente agent QEMU/cloud-init, create_cloud_vm (commun aux VM). Fonctions : `download_debian_image`:5, `configure_local_snippets`:33, `wait_for_qemu_agent`:52, `wait_for_cloud_init`:94, `create_cloud_vm`:178 |
| `vm/20-files.sh` | 281 | VM FILES (104) : cloud-init (Samba...) + création. Fonctions : `create_files_cloud_init`:5, `create_files_vm`:227 |
| `vm/30-docker.sh` | 676 | VM DOCKER (103) : cloud-init avec compose par app (Nextcloud, Syncin, Immich, HA, Jellyfin), démarrage, création. Fonctions : `create_docker_cloud_init`:5, `nextcloud_occ`:428, `configure_nextcloud_external_storage`:446, `start_docker_apps`:513, `verify_docker_shared_storage`:577, `create_docker_vm`:614 |
| `ct/10-common.sh` | 87 | Template LXC Debian, attente réseau CT, pct_push_script (commun aux CT). Fonctions : `download_debian_lxc_template`:16, `pct_wait_for_network`:55, `pct_push_script`:73 |
| `ct/20-swag.sh` | 268 | CT SWAG (101) : reverse proxy + Let's Encrypt. Fonctions : `swag_media_conf`:6, `verify_swag_certificate`:32, `create_swag_ct`:63 |
| `ct/30-xmrig-host.sh` | 128 | Hugepages + optimisation MSR (RandomX) côté hôte. Fonctions : `configure_hugepages`:5, `configure_msr_optimization`:59 |
| `ct/40-xmrig.sh` | 432 | CT XMRIG (105) + script moniteur CPU (start/stop auto). Fonctions : `resolve_xmrig_expected_hash`:5, `create_xmrig_ct`:38, `create_xmrig_monitor`:189, `read_cpu`:209, `cpu_usage`:219, `xmrig_cpu_usage`:248, `other_workload_cpu`:274, `is_xmrig_active`:297, `start_xmrig`:303, `stop_xmrig`:311 |
| `ct/50-wireguard.sh` | 759 | CT WireGuard (VPN) : profils lan/backup/internet, sorties VPN multiples (wx-*), CLI wg-homelab dans le CT, commandes wg_* côté hôte (wg_add_peer, wg_add_device, wg_add_exit, wg_show_peer, wg_status...). Fonctions : `wg_backup_dests`:35, `configure_wireguard_host`:41, `wireguard_cli_script`:68, `die`:96, `in_list`:98, `clear_rules`:101, `exit_is_up`:108, `fw_up`:110, `fw_down`:194, `apply`:213, `next_ip`:221, `cmd_add`:232, `cmd_add_device`:316, `cmd_remove`:337, `cmd_show`:351, `cmd_set_exit`:361, `cmd_list`:378, `cmd_exit_add`:394, `cmd_exit_remove`:447, `cmd_exit_list`:463, `cmd_exit_test`:475, `cmd_status`:486, `usage`:494, `wireguard_install_script`:528, `wireguard_env_file`:590, `wg_push_files`:605, `create_wireguard_ct`:628, `wg_create_default_peers`:680, `verify_wireguard`:698, `deploy_wireguard`:713, `wg_remove_peer`:728, `wg_add_exit`:737, `wg_update_cli`:754 |
| `verify/10-verify.sh` | 181 | Vérifications FILES, apps Docker, installation globale. Fonctions : `verify_files`:5, `verify_docker_apps`:31, `verify_installation`:55 |
| `verify/20-summary.sh` | 152 | show_summary (récapitulatif final). Fonctions : `show_summary`:5 |
| `tools/10-repair.sh` | 385 | Réparations à chaud sur VM existantes : `./install.sh --run <fonction>` (repair_syncin_stack, repair_webmin, diagnose_webmin, configure_nextcloud_external_storage, repair_nextcloud_proxy, repair_swag_add_media, repair_apps_data_location, check_letsencrypt ; ct/20-swag.sh : verify_swag_certificate). Fonctions : `vm_read_file`:22, `vm_write_file`:33, `vm_run`:45, `repair_syncin_stack`:59, `diagnose_webmin`:139, `repair_webmin`:159, `repair_nextcloud_proxy`:185, `check_letsencrypt`:198, `repair_swag_add_media`:255, `repair_apps_data_location`:302 |
| `main.sh` | 85 | Ordre d'exécution (main) + appel main "$@". Fonctions : `main`:5 |

## Où modifier quoi

- Changer IP/RAM/CPU/ports/versions/domaine → `core/00-config.sh` uniquement
- Nouvelle question interactive / variable lue depuis le .conf → `core/30-variables-secrets.sh` (+ `core/00-config.sh`)
- Réseau, NAT, redirections de ports → `host/20-bridges-lan.sh`, `host/30-firewall.sh`
- Disque / partage virtiofs → `host/40-storage.sh`
- Ajouter/modifier une app Docker → `vm/30-docker.sh` (+ flag `ENABLE_*` et port dans config, + `verify/10-verify.sh`)
- Samba / VM fichiers → `vm/20-files.sh`
- SWAG / reverse proxy → `ct/20-swag.sh`
- XMRig → `ct/40-xmrig.sh` (+ `ct/30-xmrig-host.sh` pour hugepages/MSR)
- Ordre des étapes / activer-désactiver un module → `main.sh`
- VPN WireGuard (pairs, profils, sorties fournisseur) → `ct/50-wireguard.sh` ; variables WG_* dans `core/00-config.sh`
- Résumé final affiché → `verify/20-summary.sh`
- Corriger une VM DÉJÀ créée (cloud-init ne rejoue pas) → `tools/10-repair.sh` + `./install.sh --run <fonction>`

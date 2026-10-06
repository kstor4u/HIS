# MAP — proxmox-homelab-install v2.26.1 (modulaire)

Chargement dans l'ordre de `MANIFEST` via `install.sh`. `./build.sh > fichier.sh` régénère le script monolithique (identique à l'original octet pour octet en 2.26.1).

**Règle** : pour une modification, ne charger que `MAP.md` + le(s) module(s) concerné(s). Toutes les variables sont dans `core/00-config.sh`.

| Module | Lignes | Contenu / fonctions (nom:ligne) |
|---|---|---|
| `core/00-config.sh` | 310 | Toutes les variables de config (IDs, IP, ressources, ports, apps, XMRIG, domaine) + HOST_PACKAGES + globales. Fonctions : `detect_lan_ip`:56 |
| `core/10-logging-checks.sh` | 73 | Logging (tee), log/info/warn/die, trap ERR, check_root, check_proxmox. Fonctions : `log`:11, `info`:21, `warn`:25, `die`:29, `check_root`:48, `check_proxmox`:53 |
| `core/20-answers-cleanup.sh` | 121 | Fichier de réponses (.conf) + proposition de suppression des VM/CT existants. Fonctions : `load_answers_file`:8, `propose_cleanup_existing`:33 |
| `core/30-variables-secrets.sh` | 283 | configure_variables (questions interactives) + generate_app_secrets. Fonctions : `configure_variables`:5, `generate_app_secrets`:249 |
| `host/10-apt.sh` | 139 | Dépôts APT Proxmox + dépendances hôte (simulation APT sécurisée). Fonctions : `configure_repositories`:5, `install_host_dependencies`:46 |
| `host/20-bridges-lan.sh` | 286 | vmbr1 privé, bascule LAN DHCP/statique, IP LAN interactive. Fonctions : `configure_private_bridge`:5, `switch_lan_to_dhcp`:45, `detect_lan_mode`:107, `switch_lan_to_static`:125, `configure_lan_ip_interactive`:199 |
| `host/30-firewall.sh` | 169 | fail2ban hôte, ip_forward, NAT, port forwards (Samba, web). Fonctions : `configure_fail2ban_host`:10, `configure_forwarding`:23, `configure_nat`:41, `add_dnat_forward`:83, `configure_samba_port_forward`:104, `configure_web_port_forwards`:131 |
| `host/40-storage.sh` | 293 | Disque DATA (formatage), arborescence, storage Proxmox, mapping virtiofs. Fonctions : `release_data_disk`:13, `prepare_data_disk`:58, `create_data_tree`:155, `configure_proxmox_storage`:209, `configure_virtiofs_mapping`:254 |
| `vm/10-common.sh` | 283 | Image Debian cloud, snippets, attente agent QEMU/cloud-init, create_cloud_vm (commun aux VM). Fonctions : `download_debian_image`:5, `configure_local_snippets`:33, `wait_for_qemu_agent`:52, `wait_for_cloud_init`:94, `create_cloud_vm`:178 |
| `vm/20-files.sh` | 279 | VM FILES (104) : cloud-init (Samba...) + création. Fonctions : `create_files_cloud_init`:5, `create_files_vm`:225 |
| `vm/30-docker.sh` | 604 | VM DOCKER (103) : cloud-init avec compose par app (Nextcloud, Syncin, Immich, HA, Jellyfin), démarrage, création. Fonctions : `create_docker_cloud_init`:5, `start_docker_apps`:466, `verify_docker_shared_storage`:523, `create_docker_vm`:542 |
| `ct/10-common.sh` | 87 | Template LXC Debian, attente réseau CT, pct_push_script (commun aux CT). Fonctions : `download_debian_lxc_template`:16, `pct_wait_for_network`:55, `pct_push_script`:73 |
| `ct/20-swag.sh` | 196 | CT SWAG (101) : reverse proxy + Let's Encrypt. Fonctions : `create_swag_ct`:5 |
| `ct/30-xmrig-host.sh` | 128 | Hugepages + optimisation MSR (RandomX) côté hôte. Fonctions : `configure_hugepages`:5, `configure_msr_optimization`:59 |
| `ct/40-xmrig.sh` | 432 | CT XMRIG (105) + script moniteur CPU (start/stop auto). Fonctions : `resolve_xmrig_expected_hash`:5, `create_xmrig_ct`:38, `create_xmrig_monitor`:189, `read_cpu`:209, `cpu_usage`:219, `xmrig_cpu_usage`:248, `other_workload_cpu`:274, `is_xmrig_active`:297, `start_xmrig`:303, `stop_xmrig`:311 |
| `verify/10-verify.sh` | 175 | Vérifications FILES, apps Docker, installation globale. Fonctions : `verify_files`:5, `verify_docker_apps`:31, `verify_installation`:55 |
| `verify/20-summary.sh` | 132 | show_summary (récapitulatif final). Fonctions : `show_summary`:5 |
| `main.sh` | 69 | Ordre d'exécution (main) + appel main "$@". Fonctions : `main`:5 |

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
- Résumé final affiché → `verify/20-summary.sh`

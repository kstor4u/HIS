# HIS : Homelab Installation Script

Installateur bash modulaire pour un homelab Proxmox (Nextcloud, Sync-in, Immich, Jellyfin, Home Assistant, Sonarr/Radarr, SWAG, WireGuard, mail, DNS, supervision, XMRig...), plus un serveur de sauvegarde par tirage (`backup-server/`).

Version actuelle : voir `SCRIPT_VERSION` dans `core/00-config.sh` (2.61.0).

## Utiliser

```bash
./install.sh --init-answers      # crée proxmox-homelab-answers.json (à compléter) et la doc des variables
sudo ./install.sh                # installe à partir du fichier de réponses
./install.sh --help              # options et commandes --run <fonction>
./build.sh > proxmox-homelab-install-vX.Y.Z.sh   # script unique équivalent (monolithe)
```

Le fichier de réponses et les secrets générés (`proxmox-homelab-answers.json`, `proxmox-homelab-secrets.json`) contiennent des mots de passe : droits 600, jamais dans git (`.gitignore`).

## Contenu

| Dossier / fichier | Rôle |
|---|---|
| `core/ host/ vm/ ct/ tools/ verify/ main.sh` | modules de l'installateur, chargés dans l'ordre de `MANIFEST` |
| `MAP.md` | carte des modules (fonctions et lignes), générée |
| `proxmox-homelab-answers.json.example` | modèle du fichier de réponses |
| `docs/variables.md` | documentation de toutes les variables (générée) |
| `docs/etat-du-projet.md` | état, règles de travail, pièges connus, historique |
| `backup-server/` | serveur de sauvegarde N54L (tirage, miroir + instantanés, test de restauration, Telegram) ; son propre `README.md` |
| `dev/split-modules.py` | découpe un monolithe en modules et le reconstruit à l'identique |

## Faire évoluer

1. Modifier le(s) module(s) concerné(s) ; une variable = sa valeur par défaut dans `core/00-config.sh` + une ligne dans `core/04-answers-schema.sh`.
2. Augmenter `SCRIPT_VERSION`, `./build.sh > proxmox-homelab-install-vX.Y.Z.sh`, tester avec `bash -n`.
3. Régénérer `MAP.md` : `python3 -I dev/split-modules.py map .`

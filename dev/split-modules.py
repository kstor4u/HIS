#!/usr/bin/env python3
"""split-modules.py : découpe le monolithe proxmox-homelab-install en modules, et le reconstruit.

  python3 -I split-modules.py split <monolithe.sh> <dossier>   monolithe -> modules + MANIFEST + install.sh + build.sh + MAP.md
  python3 -I split-modules.py build <dossier>                  modules -> monolithe sur la sortie standard (comme build.sh)
  python3 -I split-modules.py map   <dossier>                  régénère MAP.md (fonctions et lignes de chaque module)

Le découpage se fait aux bannières « ####\n# TITRE #\n#### » : chaque module commence à la bannière dont le titre
est donné dans MODULES ci-dessous (le premier module commence à la ligne 1). Les modules mis bout à bout redonnent
le monolithe OCTET POUR OCTET (vérifié par « split » lui-même). Pour ajouter un module à une version future :
ajouter une ligne (chemin, titre de sa bannière d'ouverture) à MODULES, à sa place dans l'ordre de chargement.
"""
import os
import re
import stat
import sys

# (module, titre de la bannière d'ouverture ; None = début du fichier). Ordre = ordre de chargement.
MODULES = [
    ("core/00-config.sh", None),
    ("core/04-answers-schema.sh", "SCHÉMA DU FICHIER DE RÉPONSES (SOURCE UNIQUE DES VARIABLES)"),
    ("core/05-answers.sh", "FICHIER DE RÉPONSES JSON : CRÉATION, FUSION, DOCUMENTATION"),
    ("core/10-logging-checks.sh", "LOGGING"),
    ("core/15-answers-load.sh", "FICHIER DE RÉPONSES"),
    ("core/20-cleanup.sh", "NETTOYAGE PRÉALABLE"),
    ("core/30-variables-secrets.sh", "CONFIGURATION INTERACTIVE"),
    ("core/35-subdomains.sh", "SOUS-DOMAINES DES SERVICES (UN OU PLUSIEURS NOMS)"),
    ("core/36-sites.sh", "SITES : PLUSIEURS DOMAINES SUR UN MÊME SERVEUR"),
    ("core/40-run-mode.sh", "MODE « run » : APPLIQUER SEULEMENT LES PARAMÈTRES, SANS RÉINSTALLER"),
    ("host/05-hostname.sh", "NOM D'HÔTE DU SERVEUR PROXMOX (HOST_NAME)"),
    ("host/10-apt.sh", "REPOSITORIES"),
    ("host/15-admin-user.sh", "COMPTE ADMINISTRATEUR (sudo) SUR L'HÔTE"),
    ("host/16-ssh-external.sh", "SSH DEPUIS L'EXTÉRIEUR (PHASE DE DÉVELOPPEMENT, TEMPORAIRE)"),
    ("host/20-bridges-lan.sh", "PRIVATE NETWORK"),
    ("host/30-firewall.sh", "FAIL2BAN (HÔTE)"),
    ("host/35-existing-volume.sh", "VOLUME EXISTANT (RAID / DISQUE DE DONNÉES)"),
    ("host/40-storage.sh", "DATA DISK"),
    ("host/50-backup.sh", "SAUVEGARDES"),
    ("host/55-usb-export.sh", "EXPORT VERS DISQUE EXTERNE (BRANCHER = COPIER)"),
    ("host/56-backup-source.sh", "SERVEUR DE SAUVEGARDE : GÉNÉRATION AUTOMATIQUE DU FICHIER « SOURCE »"),
    ("host/57-dns-zone.sh", "FICHIER DE ZONE DNS (enregistrements à publier chez l'hébergeur)"),
    ("host/58-notify.sh", "NOTIFICATIONS, SURVEILLANCE DE L'HÔTE (SMART, DISQUES, SERVICES)"),
    ("host/59-pool-guard.sh", "GARDE-FOU DE STOCKAGE : ARRÊT DES INVITÉS QUAND LE STOCKAGE EST PLEIN"),
    ("host/58-telegram.sh", "TELEGRAM : ALERTES + BOT DE QUESTIONS (CPU, MÉMOIRE, STOCKAGE)"),
    ("host/58-actions.sh", "ACTIONS À DISTANCE PAR TELEGRAM (sauvegarde, VM/CT, hôte) : SÉCURISÉES"),
    ("host/59-db-dump.sh", "DUMP DES BASES DE DONNÉES AVANT CHAQUE SAUVEGARDE"),
    ("host/60-maintenance.sh", "TEST DE RESTAURATION MENSUEL + MISES À JOUR DES IMAGES DOCKER"),
    ("vm/10-common.sh", "CLOUD IMAGE"),
    ("vm/20-files.sh", "FILES CLOUD-INIT"),
    ("vm/30-docker.sh", "DOCKER VM"),
    ("vm/40-arr.sh", "SONARR / RADARR / PROWLARR + QBITTORRENT (derrière un VPN) — VM DOCKER"),
    ("ct/10-common.sh", "LXC TEMPLATE"),
    ("ct/20-swag.sh", "SWAG"),
    ("ct/25-portal.sh", "PORTAIL : UNE PAGE D'ACCUEIL POUR TOUS LES SERVICES"),
    ("ct/25-crowdsec.sh", "CROWDSEC DEVANT SWAG (anti brute-force/scan)"),
    ("ct/30-xmrig-host.sh", "HUGE PAGES"),
    ("ct/40-xmrig.sh", "XMRIG"),
    ("ct/50-wireguard.sh", "WIREGUARD (CT VPN + SORTIES VPN)"),
    ("ct/60-node.sh", "NODE.JS + MONGODB (CT LXC, Docker)"),
    ("ct/65-ai.sh", "IA LOCALE : Ollama + Open WebUI (GPU NVIDIA) + OCR + normes (RAG)"),
    ("ct/70-mail.sh", "SERVEUR MAIL AUTONOME (CT LXC + docker-mailserver)"),
    ("ct/80-dns.sh", "DNS FILTRANT / ANTI-PUBLICITÉS (CT LXC + AdGuard Home)"),
    ("ct/90-monitor.sh", "SUPERVISION : Uptime Kuma + ntfy + Homepage (CT LXC, Docker)"),
    ("verify/10-verify.sh", "FILES VERIFICATION"),
    ("verify/20-summary.sh", "SUMMARY"),
    ("tools/10-repair.sh", "OUTILS DE RÉPARATION À CHAUD"),
    ("tools/20-nextcloud.sh", "NEXTCLOUD : OPTIMISATION, CORRECTIFS PHP (PHP2Shell), PHOTOS + IA"),
    ("tools/30-docker-vm.sh", "VM DOCKER : TYPE DE PROCESSEUR"),
    ("tools/40-nextcloud-photos.sh", "PHOTOS : MEMORIES + RECOGNIZE (IA)"),
    ("main.sh", "MAIN"),
]

BANNER = "#" * 79

INSTALL_SH = r'''#!/usr/bin/env bash
# install.sh : lanceur de la version modulaire. Charge les modules listés dans MANIFEST, dans l'ordre, dans CE shell
# (équivaut au script monolithe : ./build.sh > proxmox-homelab-install.sh). Usage identique : sudo ./install.sh [options]
_HOMELAB_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS= read -r _homelab_mod; do
    [[ -z "$_homelab_mod" || "$_homelab_mod" == \#* ]] && continue
    # shellcheck disable=SC1090
    source "${_HOMELAB_SRC_DIR}/${_homelab_mod}"
done < "${_HOMELAB_SRC_DIR}/MANIFEST"
'''

BUILD_SH = r'''#!/usr/bin/env bash
# build.sh : assemble les modules (ordre du MANIFEST) en un script unique sur la sortie standard.
#   ./build.sh > proxmox-homelab-install-vX.Y.Z.sh && chmod +x proxmox-homelab-install-vX.Y.Z.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
while IFS= read -r mod; do
    [[ -z "$mod" || "$mod" == \#* ]] && continue
    cat "$mod"
done < MANIFEST
'''


def find_cuts(lines):
    """Index de ligne (0-based) où commence chaque module."""
    cuts = []
    for mod, title in MODULES:
        if title is None:
            cuts.append(0)
            continue
        hits = [
            i - 1
            for i in range(1, len(lines) - 1)
            if lines[i - 1].rstrip("\n") == BANNER
            and lines[i + 1].rstrip("\n") == BANNER
            and re.sub(r"^#\s*|\s*#$", "", lines[i].rstrip("\n")).strip() == title
        ]
        if len(hits) != 1:
            sys.exit(f"ERREUR : bannière « {title} » trouvée {len(hits)} fois (module {mod}).")
        cuts.append(hits[0])
    if cuts != sorted(cuts):
        sys.exit("ERREUR : les modules ne sont pas dans l'ordre du fichier.")
    return cuts


def read_manifest(d):
    with open(os.path.join(d, "MANIFEST"), encoding="utf-8") as f:
        return [m.strip() for m in f if m.strip() and not m.startswith("#")]


def build(d):
    out = b""
    for mod in read_manifest(d):
        with open(os.path.join(d, mod), "rb") as f:
            out += f.read()
    return out


FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")


def make_map(d):
    rows = []
    version = "?"
    for mod in read_manifest(d):
        with open(os.path.join(d, mod), encoding="utf-8") as f:
            text = f.read()
        lines = text.split("\n")
        m = re.search(r'^SCRIPT_VERSION="([^"]+)"', text, re.M)
        if m:
            version = m.group(1)
        funcs = [f"`{FUNC_RE.match(l).group(1)}`:{n}" for n, l in enumerate(lines, 1) if FUNC_RE.match(l)]
        title = next(
            (re.sub(r"^#\s*|\s*#$", "", lines[i]).strip() for i in range(1, len(lines) - 1)
             if lines[i - 1] == BANNER and lines[i + 1] == BANNER and lines[i].startswith("#  ")),
            "",
        )
        rows.append((mod, len(lines), title, funcs))
    out = [
        f"# MAP — proxmox-homelab-install v{version} (modulaire, générée par split-modules.py)\n",
        "Chargement dans l'ordre de `MANIFEST` (`install.sh`). `./build.sh > fichier.sh` produit le script monolithique.\n",
        "**Règle** : pour une modification, ne charger que ce fichier + le(s) module(s) concerné(s). Toutes les variables sont "
        "dans `core/00-config.sh` ; le modèle du fichier de réponses est dans `core/05-answers.sh` "
        "(à tenir à jour quand une variable est ajoutée).\n",
        "| Module | Lignes | Contenu | Fonctions (nom:ligne) |",
        "|---|---|---|---|",
    ]
    for mod, n, title, funcs in rows:
        out.append(f"| `{mod}` | {n} | {title} | {', '.join(funcs)} |")
    return "\n".join(out) + "\n"


def split(src, d):
    with open(src, "rb") as f:
        data = f.read()
    text = data.decode("utf-8")
    lines = text.splitlines(keepends=True)
    cuts = find_cuts(lines) + [len(lines)]
    os.makedirs(d, exist_ok=True)
    manifest = ["# Ordre de chargement des modules (une ligne = un fichier). Généré par split-modules.py."]
    for i, (mod, _) in enumerate(MODULES):
        path = os.path.join(d, mod)
        os.makedirs(os.path.dirname(path) or d, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("".join(lines[cuts[i]:cuts[i + 1]]))
        manifest.append(mod)
    with open(os.path.join(d, "MANIFEST"), "w", encoding="utf-8") as f:
        f.write("\n".join(manifest) + "\n")
    for name, body in (("install.sh", INSTALL_SH), ("build.sh", BUILD_SH)):
        p = os.path.join(d, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if build(d) != data:
        sys.exit("ERREUR : le rebuild ne redonne pas le monolithe octet pour octet.")
    with open(os.path.join(d, "MAP.md"), "w", encoding="utf-8") as f:
        f.write(make_map(d))
    print(f"OK : {len(MODULES)} modules dans {d} ; rebuild identique au monolithe ({len(data)} octets).")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "split":
        split(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "build":
        sys.stdout.buffer.write(build(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == "map":
        with open(os.path.join(sys.argv[2], "MAP.md"), "w", encoding="utf-8") as f:
            f.write(make_map(sys.argv[2]))
    else:
        sys.exit(__doc__)

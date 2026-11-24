#!/usr/bin/env python3
"""Construit l'installateur autonome du serveur de sauvegarde : python3 -I bs-build.py <arbre> <sortie.sh>
Arbre = install.sh, lib/, bin/, conf/, README.md. Sortie = script bash + archive tar.gz en base64."""
import base64, io, os, sys, tarfile
tree, out = sys.argv[1], sys.argv[2]
ver = [l for l in open(os.path.join(tree, "lib/lib.sh"), encoding="utf-8") if l.startswith("HB_VERSION=")][0].split('"')[1]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    for dp, dn, fn in os.walk(tree):
        dn[:] = sorted(d for d in dn if d != "__pycache__")
        for f in sorted(fn):
            p = os.path.join(dp, f)
            ti = tf.gettarinfo(p, os.path.relpath(p, tree))
            ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"; ti.mtime = 0
            with open(p, "rb") as fh: tf.addfile(ti, fh)
b64 = base64.encodebytes(buf.getvalue()).decode()
head = f'''#!/usr/bin/env bash
# Serveur de sauvegarde par tirage (N54L) v{ver} : installateur autonome (archive intégrée).
#   sudo bash <ce fichier> [options de install.sh]      installe / met à jour
#   HB_KEEP=dossier bash <ce fichier> --extract-only    extrait l'arbre modulaire sans installer
set -euo pipefail
ME="$(readlink -f "$0")"
if [[ "${{1:-}}" == "--extract-only" ]]; then
    D="${{HB_KEEP:-./homelab-backup-src}}"; mkdir -p "$D"
else
    (( EUID == 0 )) || {{ echo "Lance avec sudo." >&2; exit 1; }}
    D="$(mktemp -d /tmp/homelab-backup.XXXXXX)"; trap 'rm -rf "$D"' EXIT
fi
sed -n '/^__ARCHIVE__$/,$p' "$ME" | tail -n +2 | base64 -d | tar -xzf - -C "$D"
if [[ "${{1:-}}" == "--extract-only" ]]; then echo "Arbre extrait dans $D"; exit 0; fi
cd "$D" && bash ./install.sh "$@"
exit $?
__ARCHIVE__
'''
open(out, "w", encoding="utf-8", newline="").write(head + b64)
os.chmod(out, 0o755)
print(out, ver, len(b64) // 1024, "Ko")

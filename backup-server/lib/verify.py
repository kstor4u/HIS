#!/usr/bin/env python3
"""Vérification d'intégrité d'un miroir de sauvegarde (détection de corruption silencieuse).

Principe : une base SQLite (manifeste) mémorise, pour chaque fichier, taille + date de modification
+ empreinte. À chaque passage :
  - fichier connu, même taille et même date  -> on recalcule l'empreinte : si elle diffère, le
    contenu a changé SANS que le fichier ait été modifié = corruption (pourriture de bits, secteur
    défaillant). C'est signalé et le manifeste N'EST PAS mis à jour.
  - fichier connu mais taille/date changées   -> modification légitime : nouvelle empreinte.
  - fichier nouveau                           -> ajouté.
  - fichier disparu                           -> retiré du manifeste (fin de parcours complet).
Un délai maximal permet d'interrompre le parcours ; il reprend au même endroit au passage suivant.

Usage : verify.py <miroir> <manifeste.sqlite> [--deadline <epoch>] [--corrupt-list <fichier>]
Sortie (dernière ligne) : RESULT verified=N new=N updated=N corrupt=N removed=N complete=0|1
Code de retour : 0 = rien d'anormal, 1 = corruption détectée.
"""
import hashlib
import os
import sqlite3
import sys
import time


def hash_file(path):
    h = hashlib.blake2b(digest_size=16)
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(4 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def walk_sorted(root, rel=""):
    """Parcours récursif trié par nom, fichiers et dossiers entremêlés : l'ordre correspond à celui des
    tuples de composants du chemin (stable d'un passage à l'autre, nécessaire à la reprise)."""
    try:
        with os.scandir(os.path.join(root, rel) if rel else root) as it:
            entries = sorted(it, key=lambda e: e.name)
    except OSError:
        return
    for e in entries:
        r = os.path.join(rel, e.name) if rel else e.name
        if e.is_symlink():
            continue
        if e.is_dir(follow_symlinks=False):
            yield from walk_sorted(root, r)
        elif e.is_file(follow_symlinks=False):
            yield r


def key(rel):
    return tuple(rel.split(os.sep))


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    root, dbpath = args[0], args[1]
    deadline = None
    corrupt_list = None
    i = 2
    while i < len(args):
        if args[i] == "--deadline":
            deadline = float(args[i + 1]); i += 2
        elif args[i] == "--corrupt-list":
            corrupt_list = args[i + 1]; i += 2
        else:
            i += 1

    db = sqlite3.connect(dbpath)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER, mtime_ns INTEGER, hash TEXT, gen INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")

    def meta_get(k, default=""):
        r = db.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
        return r[0] if r else default

    def meta_set(k, v):
        db.execute("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", (k, str(v)))

    gen = int(meta_get("gen", "0"))
    cursor = meta_get("cursor", "")
    if not cursor:                      # nouveau parcours complet
        gen += 1
        meta_set("gen", gen)
        corrupt = []
    else:                               # reprise d'un parcours interrompu
        corrupt = []

    stats = {"verified": 0, "new": 0, "updated": 0, "corrupt": 0, "removed": 0}
    complete = True
    last = cursor
    n = 0

    for rel in walk_sorted(root):
        if cursor and key(rel) <= key(cursor):
            continue
        full = os.path.join(root, rel)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        row = db.execute("SELECT size, mtime_ns, hash FROM files WHERE path=?", (rel,)).fetchone()
        try:
            if row and row[0] == st.st_size and row[1] == st.st_mtime_ns:
                if hash_file(full) == row[2]:
                    db.execute("UPDATE files SET gen=? WHERE path=?", (gen, rel))
                    stats["verified"] += 1
                else:
                    stats["corrupt"] += 1
                    corrupt.append(rel)
                    db.execute("UPDATE files SET gen=? WHERE path=?", (gen, rel))
            else:
                h = hash_file(full)
                db.execute("INSERT OR REPLACE INTO files(path, size, mtime_ns, hash, gen) VALUES(?,?,?,?,?)",
                           (rel, st.st_size, st.st_mtime_ns, h, gen))
                stats["updated" if row else "new"] += 1
        except OSError as e:
            # Erreur de lecture = très probablement un secteur défaillant
            stats["corrupt"] += 1
            corrupt.append(rel + "  (lecture impossible : %s)" % e.strerror)
        last = rel
        n += 1
        if n % 500 == 0:
            meta_set("cursor", last)
            db.commit()
            if deadline and time.time() > deadline:
                complete = False
                break

    if complete:
        stats["removed"] = db.execute("SELECT COUNT(*) FROM files WHERE gen < ?", (gen,)).fetchone()[0]
        db.execute("DELETE FROM files WHERE gen < ?", (gen,))
        meta_set("cursor", "")
        meta_set("last_complete", int(time.time()))
    else:
        meta_set("cursor", last)
    db.commit()
    db.close()

    if corrupt_list:
        with open(corrupt_list, "a") as f:
            for c in corrupt:
                f.write(c + "\n")
    for c in corrupt[:50]:
        print("CORRUPT " + c)
    if len(corrupt) > 50:
        print("CORRUPT ... et %d autres (voir la liste complète)" % (len(corrupt) - 50))
    print("RESULT verified=%d new=%d updated=%d corrupt=%d removed=%d complete=%d" % (
        stats["verified"], stats["new"], stats["updated"], stats["corrupt"], stats["removed"], 1 if complete else 0))
    return 1 if stats["corrupt"] else 0


if __name__ == "__main__":
    sys.exit(main())

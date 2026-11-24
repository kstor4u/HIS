#!/usr/bin/env python3
"""TOTP (RFC 6238, SHA-1, 6 chiffres, 30 s) sans dépendance.
  totp.py new                              affiche un nouveau secret (base32)
  totp.py verify <secret> <état> <code>    0 = bon ; 1 = faux ; 2 = déjà utilisé (rejeu)
  totp.py uri <secret> <libellé> <émetteur>
La variable TOTP_NOW (secondes) sert aux tests."""
import base64, hashlib, hmac, os, secrets, struct, sys, time
from urllib.parse import quote


def hotp(key, counter):
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    return (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000


def load(path):
    s = open(path).read().strip().replace(" ", "").upper()
    return base64.b32decode(s + "=" * (-len(s) % 8))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "new":
        print(base64.b32encode(secrets.token_bytes(20)).decode().rstrip("="))
    elif cmd == "uri":
        secret = open(sys.argv[2]).read().strip()
        label, issuer = quote(sys.argv[3]), quote(sys.argv[4])
        print("otpauth://totp/%s:%s?secret=%s&issuer=%s&period=30&digits=6&algorithm=SHA1" % (issuer, label, secret, issuer))
    elif cmd == "verify":
        key, state, code = load(sys.argv[2]), sys.argv[3], sys.argv[4]
        if len(code) != 6 or not code.isdigit():
            sys.exit(1)
        step = int(float(os.environ.get("TOTP_NOW", time.time()))) // 30
        try:
            last = int(open(state).read().strip() or 0)
        except Exception:
            last = 0
        found = None
        for s in (step - 1, step, step + 1):
            if hmac.compare_digest("%06d" % hotp(key, s), code):
                found = s
        if found is None:
            sys.exit(1)
        if found <= last:
            sys.exit(2)
        tmp = state + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(str(found))
        os.replace(tmp, state)
        sys.exit(0)
    else:
        sys.exit(64)


main()

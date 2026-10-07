#!/bin/sh
# Rebuild prefix.tar.gz (Termux aarch64 packages: Samba, Transmission, Syncthing, sshd, unbound, nginx, WireGuard...).
# Needs network + python3. Extra packages: ./make-bundle.sh samba transmission <more...>
set -e
cd "$(dirname "$0")"
rm -rf termux-prefix
python3 -I fetch-samba.py "$@"
python3 -I - <<'PY'
import tarfile
with tarfile.open("prefix.tar.gz", "w:gz", compresslevel=9) as t:
    t.add("termux-prefix", arcname=".")
PY
ls -lh prefix.tar.gz

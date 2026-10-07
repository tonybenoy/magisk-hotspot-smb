#!/usr/bin/env python3
"""Download Termux samba, transmission + deps (aarch64) and extract into ./termux-prefix (the Termux 'usr' tree)."""
import hashlib, os, re, subprocess, sys, tempfile, urllib.request

BASE = "https://packages-cf.termux.dev/apt/termux-main/"
ARCH = os.environ.get("ARCH", "aarch64")
ROOTS = sys.argv[1:] or ["samba", "transmission", "zstd", "openssh", "syncthing", "wireguard-tools", "bash", "unbound", "nginx"]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "termux-prefix")

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "curl/8"})).read()

idx = get(f"{BASE}dists/stable/main/binary-{ARCH}/Packages").decode()
pkgs = {}
for blk in idx.split("\n\n"):
    f = dict(re.findall(r"^([A-Za-z0-9-]+): (.*)$", blk, re.M))
    if "Package" in f:
        pkgs[f["Package"]] = f

def deps(p):
    out = []
    for d in pkgs[p].get("Depends", "").split(","):
        d = d.strip().split("|")[0].split("(")[0].strip()
        if d:
            out.append(d)
    return out

todo, seen = list(ROOTS), set()
while todo:
    p = todo.pop()
    if p in seen:
        continue
    if p not in pkgs:
        print("skip (not in repo):", p); continue
    seen.add(p)
    todo += deps(p)

def extract_deb(data, dest):
    """A .deb is an ar archive; data.tar.* holds the files."""
    import io, tarfile
    assert data[:8] == b"!<arch>\n"
    pos = 8
    while pos < len(data):
        name = data[pos:pos + 16].decode().strip().rstrip("/")
        size = int(data[pos + 48:pos + 58])
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if name.startswith("data.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as t:
                t.extractall(dest, filter="tar")
            return
    raise RuntimeError("no data.tar in deb")

os.makedirs(OUT, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    for p in sorted(seen):
        f = pkgs[p]
        path = os.path.join(tmp, p + ".deb")
        data = get(BASE + f["Filename"])
        assert hashlib.sha256(data).hexdigest() == f["SHA256"], f"checksum mismatch: {p}"
        open(path, "wb").write(data)
        # deb data is rooted at ./data/data/com.termux/files/usr/...
        extract_deb(data, tmp + "/x")
        print("ok", p, f["Version"])
    src = tmp + "/x/data/data/com.termux/files/usr"
    subprocess.run(["cp", "-a", src + "/.", OUT], check=True)
print("extracted to", OUT)

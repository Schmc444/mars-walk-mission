#!/usr/bin/env python3
"""Descarga y descomprime el mundo (GitHub Release world-v1) en ./world.

Repo publico: no necesita token. Si hay GITHUB_TOKEN / GH_TOKEN (o `gh auth login`) lo usa, util si el repo vuelve a ser privado. Requiere el binario `zstd` o Python >= 3.14.
Uso: python tools/get_world.py [--dest world] [--tag world-v1]
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, tarfile, urllib.request

REPO = "Schmc444/mars-walk-mission"
SHA256 = "5ab6020fbf090132a38752e1a20e414dac0319fbfbe9e55501eec9acaedff591"


def token():
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not t and shutil.which("gh"):
        t = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default="world")
    ap.add_argument("--tag", default="world-v1")
    a = ap.parse_args()
    tk = token()
    h = {"Accept": "application/vnd.github+json"}
    if tk:
        h["Authorization"] = "Bearer " + tk
    rel = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, a.tag), headers=h)))
    asset = next(x for x in rel["assets"] if x["name"].endswith(".tar.zst"))
    out = asset["name"]
    print("descargando", out, asset["size"] // 2**20, "MB ...")
    req = urllib.request.Request(asset["url"], headers={**h, "Accept": "application/octet-stream"})
    sha = hashlib.sha256()
    with urllib.request.urlopen(req) as r, open(out, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
            sha.update(chunk)
    if a.tag == "world-v1" and sha.hexdigest() != SHA256:
        sys.exit("sha256 no coincide, descarga corrupta")
    parent = os.path.dirname(os.path.abspath(a.dest)) or "."
    if shutil.which("zstd"):
        p = subprocess.Popen(["zstd", "-dc", out], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=p.stdout, mode="r|") as t:
            t.extractall(parent)
        p.wait()
    else:
        from compression import zstd  # Python 3.14+
        with zstd.open(out) as z, tarfile.open(fileobj=z, mode="r|") as t:
            t.extractall(parent)
    os.remove(out)
    print("listo:", os.path.join(parent, "world"))


if __name__ == "__main__":
    main()

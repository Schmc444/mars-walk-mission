"""Integrity checks for a built world: files/sizes, NaN, tile seams, route coverage. Usage: python tools/validate_world.py <world_dir>"""
import json, os, sys, zlib, struct
import numpy as np
W = sys.argv[1]
w = json.load(open(W + "/world.json"))
B = w["block"]; tiles = {(t["bx"], t["by"]): t for t in w["tiles"]}
errs = []
def f32(p, n):
    a = np.fromfile(p, "<f4")
    if a.size != n * n: errs.append("size %s %d != %d" % (p, a.size, n * n)); return None
    return a.reshape(n, n)
def png_size(p):
    d = open(p, "rb").read(33); return struct.unpack(">II", d[16:24])
H = {}
for (bx, by) in tiles:
    for lod in w["terrain"]["lods"]:
        n = lod["samples"]; p = "%s/%s/%d_%d.f32" % (W, lod["dir"], bx, by)
        if not os.path.exists(p): errs.append("missing " + p); continue
        a = f32(p, n)
        if a is None: continue
        if not np.isfinite(a).all(): errs.append("nonfinite " + p)
        if lod["step_m"] == 1: H[(bx, by)] = a
    for lod in w["ortho"]["lods"]:
        p = "%s/%s/%d_%d.png" % (W, lod["dir"], bx, by)
        if not os.path.exists(p): errs.append("missing " + p); continue
        if png_size(p) != (lod["size"], lod["size"]): errs.append("png size " + p)
# seams: east border of tile == west column of east neighbour, same south
seam = 0; worst = 0.0
for (bx, by), a in H.items():
    e = H.get((bx + 1, by))
    if e is not None:
        d = np.abs(a[:, B] - e[:, 0]).max(); worst = max(worst, d); seam += d > 1e-4
    s = H.get((bx, by + 1))
    if s is not None:
        d = np.abs(a[B, :] - s[0, :]).max(); worst = max(worst, d); seam += d > 1e-4
print("tiles", len(tiles), "seam mismatches", seam, "worst %.4f m" % worst)
# neighbour height jumps (cell to cell) -> max slope per tile
mx = 0
for k, a in H.items():
    dz = np.abs(np.diff(a, axis=0)).max(); dx = np.abs(np.diff(a, axis=1)).max(); mx = max(mx, dz, dx)
print("max 1 m cell-to-cell height step: %.1f m" % mx)
# route coverage: every route vertex lies in a tile that exists and ortho nonzero
r = json.load(open(W + "/route.json"))["route"]
sx, sz = w["spacing_x"], w["spacing_z"]; opx, opy = w["origin"]["px"]
miss = 0; nodata = 0; tot = 0; cache = {}
def png_pixels(p):
    d = open(p, "rb").read(); i = 8; idat = b""; wd = ht = 0
    while i < len(d):
        L = struct.unpack(">I", d[i:i+4])[0]; t = d[i+4:i+8]
        if t == b"IHDR": wd, ht = struct.unpack(">II", d[i+8:i+16])
        if t == b"IDAT": idat += d[i+8:i+8+L]
        i += 12 + L
    raw = np.frombuffer(zlib.decompress(idat), "u1").reshape(ht, wd + 1)
    return raw[:, 1:]  # filter 0 only (our writer)
for seg in r:
    for x, z in seg["xz"][::5]:
        px, py = x / sx + opx, z / sz + opy
        k = (int(px // B), int(py // B)); tot += 1
        if k not in tiles: miss += 1; continue
        if k not in cache: cache[k] = png_pixels("%s/ortho/o100/%d_%d.png" % (W, *k))
        o = cache[k]; n = o.shape[0]
        v = o[min(int((py - k[1] * B) / B * n), n - 1), min(int((px - k[0] * B) / B * n), n - 1)]
        nodata += v == 0
print("route samples", tot, "outside tiles", miss, "ortho nodata at route", nodata)
nf = sorted(((t["nodata_frac"], k) for k, t in tiles.items()), reverse=True)[:5]
print("tiles with most DTM nodata:", nf)
print("sol range", min(s["sol"] for s in r), max(s["sol"] for s in r), "datum", w["datum_m"])
print("ERRORS:", errs[:10] if errs else "none", len(errs))

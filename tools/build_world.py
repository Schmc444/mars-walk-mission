"""Turn the raw band blocks (tools/fetch_band.py) into a streamable multi-LOD world.

  WORLD/world.json                  manifest (read by the viewer; the contract for layers)
  WORLD/route.json                  Perseverance route in world coordinates
  WORLD/terrain/t<step>/<bx>_<by>.f32   float32 LE, metres above datum, (N+1)^2 samples, row 0 = north
  WORLD/ortho/o<cm>/<bx>_<by>.png       8-bit grayscale, 0 = no data

World frame: x east, z south, y up, ground metres, origin = first route vertex, y = elevation - elevation at origin.
One DTM pixel is `spacing_x` m east-west (px*cos(lat0)) and `spacing_z` m north-south, so tiles are 500*spacing_x by 500 m.
Neighbouring tiles share their border row/column (the +1 sample), so same-LOD tiles join without cracks.
"""
import argparse, json, math, os, struct, sys, time, zlib
from concurrent.futures import ProcessPoolExecutor
import numpy as np

BLOCK = 500
T_STEPS = (1, 5, 20)           # terrain LODs: ground metres per sample (N-S)
O_CM = (25, 50, 100, 400)      # ortho LODs: cm per pixel (N-S)


def write_png_gray(path, a):
    h, w = a.shape
    raw = b"".join(b"\x00" + a[r].tobytes() for r in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path + ".part", "wb") as f:
        f.write(png)
    os.replace(path + ".part", path)


def load_dtm(band, bx, by):
    p = "%s/dtm_%d_%d.f32" % (band, bx, by)
    return np.fromfile(p, dtype="<f4").reshape(BLOCK, BLOCK) if os.path.exists(p) else None


def _ffill(b):
    idx = np.where(np.isfinite(b), np.arange(b.shape[1]), 0)
    np.maximum.accumulate(idx, axis=1, out=idx)
    return np.take_along_axis(b, idx, 1)


def fill_nan(a):
    """Fill NaN from the nearest valid sample along rows, then columns; all-NaN stays NaN."""
    for tr in (False, True):
        b = a.T if tr else a
        b = _ffill(b)
        b = _ffill(b[:, ::-1])[:, ::-1]
        a = np.ascontiguousarray(b.T if tr else b)
    return a


FILL = None   # (grid, x0_block, y0_block, cell_px): global low-res fill used for every nodata pixel (same value for shared borders)
CELL = 10


def build_fill(band, blocks):
    import warnings
    bxs, bys = [b[0] for b in blocks], [b[1] for b in blocks]
    x0, y0 = min(bxs) - 1, min(bys) - 1
    nb = BLOCK // CELL
    G = np.full(((max(bys) - y0 + 2) * nb, (max(bxs) - x0 + 2) * nb), np.nan, "f4")
    for bx, by in blocks:
        a = load_dtm(band, bx, by)
        if a is None:
            continue
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            c = np.nanmean(a.reshape(nb, CELL, nb, CELL), (1, 3))
        G[(by - y0) * nb:(by - y0 + 1) * nb, (bx - x0) * nb:(bx - x0 + 1) * nb] = c
    known = np.isfinite(G)
    F = fill_nan(G.copy())
    F = np.where(np.isfinite(F), F, np.nanmean(G))
    for _ in range(3000):
        P = np.pad(F, 1, mode="edge")
        F = np.where(known, G, (P[:-2, 1:-1] + P[2:, 1:-1] + P[1:-1, :-2] + P[1:-1, 2:]) / 4)
    return F.astype("f4"), x0, y0


def fill_sample(bx, by):
    F, x0, y0 = FILL
    fy = np.clip((by * BLOCK + np.arange(BLOCK + 1) - y0 * BLOCK - (CELL - 1) / 2) / CELL, 0, F.shape[0] - 1.001)
    fx = np.clip((bx * BLOCK + np.arange(BLOCK + 1) - x0 * BLOCK - (CELL - 1) / 2) / CELL, 0, F.shape[1] - 1.001)
    iy, ix = fy.astype(int), fx.astype(int)
    ty, tx = (fy - iy)[:, None], (fx - ix)[None, :]
    a, b = F[iy][:, ix], F[iy][:, ix + 1]
    c, d = F[iy + 1][:, ix], F[iy + 1][:, ix + 1]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def extended(band, bx, by):
    """BLOCK+1 square (own block + first row/col of the east/south/south-east neighbours)."""
    out = np.full((BLOCK + 1, BLOCK + 1), np.nan, "f4")
    own = load_dtm(band, bx, by)
    out[:BLOCK, :BLOCK] = own
    e, s, se = load_dtm(band, bx + 1, by), load_dtm(band, bx, by + 1), load_dtm(band, bx + 1, by + 1)
    out[:BLOCK, BLOCK] = e[:, 0] if e is not None else own[:, -1]
    out[BLOCK, :BLOCK] = s[0, :] if s is not None else own[-1, :]
    out[BLOCK, BLOCK] = se[0, 0] if se is not None else out[BLOCK - 1, BLOCK]
    return out


def mean_down(a, k, nodata0=False):
    h, w = a.shape
    b = a.reshape(h // k, k, w // k, k).astype("f4")
    if nodata0:
        cnt = (b > 0).sum((1, 3))
        return np.where(cnt > 0, b.sum((1, 3)) / np.maximum(cnt, 1), 0).round().astype("u1")
    return b.mean((1, 3))


def do_block(arg):
    band, out, bx, by, datum = arg
    ext = extended(band, bx, by)
    nod = float(np.isnan(ext).mean())
    m = np.isnan(ext)
    if m.any():
        ext[m] = fill_sample(bx, by)[m]
    ext = np.nan_to_num(ext, nan=datum)
    cm = (ext - datum).astype("<f4")
    for st in T_STEPS:
        d = "%s/terrain/t%d" % (out, st)
        os.makedirs(d, exist_ok=True)
        cm[::st, ::st].tofile("%s/%d_%d.f32.part" % (d, bx, by))
        os.replace("%s/%d_%d.f32.part" % (d, bx, by), "%s/%d_%d.f32" % (d, bx, by))
    p = "%s/ortho_%d_%d.u8" % (band, bx, by)
    o = np.fromfile(p, dtype="u1").reshape(BLOCK * 4, BLOCK * 4)
    for cmpx in O_CM:
        k = cmpx // 25
        d = "%s/ortho/o%d" % (out, cmpx)
        os.makedirs(d, exist_ok=True)
        write_png_gray("%s/%d_%d.png" % (d, bx, by), o if k == 1 else mean_down(o, k, True))
    return bx, by, nod, float(cm[:BLOCK, :BLOCK].min()), float(cm[:BLOCK, :BLOCK].max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--band", default="band")
    ap.add_argument("--out", default="world")
    ap.add_argument("--procs", type=int, default=12)
    a = ap.parse_args()
    m = json.load(open(a.band + "/manifest.json"))
    R, t = m["radius_m"], m["dtm"]
    pts = np.array([p for s in m["route"] for p in s["lonlat"]])
    lat0 = float(pts[:, 1].mean())
    cosl = math.cos(math.radians(lat0))

    def lonlat_px(lon, lat):
        return (R * np.radians(lon) - t["x0"]) / t["px_m"], (t["y0"] - R * np.radians(lat)) / t["px_m"]

    first = min(m["route"], key=lambda s: s["sol"])["lonlat"][0]
    opx, opy = lonlat_px(*first)
    ob = load_dtm(a.band, int(opx // BLOCK), int(opy // BLOCK))
    datum = float(ob[int(opy) % BLOCK, int(opx) % BLOCK])
    if not np.isfinite(datum):
        datum = float(np.nanmedian(ob))
    print("lat0 %.4f cos %.4f origin px (%.1f, %.1f) datum elev %.2f m" % (lat0, cosl, opx, opy, datum))

    global FILL
    t0 = time.time()
    FILL = build_fill(a.band, [tuple(b) for b in m["blocks"]])
    print("global nodata fill %.0fs" % (time.time() - t0), flush=True)
    os.makedirs(a.out, exist_ok=True)
    args = [(a.band, a.out, bx, by, datum) for bx, by in m["blocks"]]
    t0, res = time.time(), []
    with ProcessPoolExecutor(a.procs) as ex:
        for i, r in enumerate(ex.map(do_block, args), 1):
            res.append(r)
            if i % 10 == 0 or i == len(args):
                print("%d/%d blocks (%.0fs)" % (i, len(args), time.time() - t0), flush=True)
    lo, hi = min(r[3] for r in res), max(r[4] for r in res)
    print("height range vs datum: %.1f .. %.1f m" % (lo, hi))

    sx, sz = cosl * t["px_m"], t["px_m"]
    route = []
    for s in m["route"]:
        l = np.array(s["lonlat"])
        px, py = lonlat_px(l[:, 0], l[:, 1])
        route.append(dict(sol=s["sol"], xz=[[round((x - opx) * sx, 2), round((y - opy) * sz, 2)] for x, y in zip(px, py)]))
    json.dump(dict(schema=1, route=route), open(a.out + "/route.json", "w"))

    world = dict(
        schema=1, kind="tiled_world", frame="x east, z south, y up, ground metres; origin = first route vertex; y = elevation - datum_m",
        body=dict(name="Mars", radius_m=R), sol_max=m["sol_max"], half_m=m["half_m"],
        origin=dict(lon=first[0], lat=first[1], px=[opx, opy], mosaic_x0=t["x0"], mosaic_y0=t["y0"], lat0=lat0),
        datum_m=datum, block=BLOCK, spacing_x=sx, spacing_z=sz, tile_m=[BLOCK * sx, BLOCK * sz],
        tile_world_origin="tile (bx,by) west-north corner = ((bx*block - origin.px[0])*spacing_x, (by*block - origin.px[1])*spacing_z)",
        terrain=dict(dtype="f32", unit="m", nodata_filled=True, lods=[dict(dir="terrain/t%d" % s, step_m=s, samples=BLOCK // s + 1) for s in T_STEPS],
                     note="(N+1)^2 samples incl. shared east/south border; sample i at x=i*step_m*spacing_x/1 (x) and z=i*step_m (z)"),
        ortho=dict(format="png8", nodata=0, lods=[dict(dir="ortho/o%d" % c, cm=c, size=BLOCK * 100 // c) for c in O_CM]),
        tiles=[dict(bx=r[0], by=r[1], nodata_frac=round(r[2], 4)) for r in sorted(res, key=lambda r: (r[1], r[0]))],
        route="route.json", credit=m["dtm"]["credit"], sources=dict(dtm=m["dtm"]["url"], ortho=m["ortho"]["url"]),
        built_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    )
    json.dump(world, open(a.out + "/world.json", "w"), indent=1)
    print("DONE %d tiles in %.0fs" % (len(res), time.time() - t0))


if __name__ == "__main__":
    main()

"""Far-field rings for the tiled world (the world tiles only cover +-500 m around the route).

  WORLD/far/far.json        ring list (geometry in world metres, read by viewer-godot/far.gd)
  WORLD/far/mid.f32         HiRISE DTM block-averaged to ~12 m over the route bbox + margin (float32, rows = z, y = elev - datum)
  WORLD/far/mid_tex.png     CTX 6 m brightness over the same rectangle (8-bit)
  WORLD/far/far.f32         HRSC/MOLA 200 m, +-80 km around the route centre, offset-matched to the DTM

Run after build_world.py:  python tools/build_far.py --world world
"""
import argparse, json, math, os, sys, time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from marswalk import sources
from marswalk.geo import Site, sample_axes

K = 12                         # DTM px per mid-ring sample
ROWS = (1, 4, 7, 10)           # rows read inside every K-row block (a 4/12 subsample is enough for a block mean)


def mid_ring(world, X0, Z0, nx, nz):
    o = world["origin"]
    opx, opy = o["px"]
    sx, sz = world["spacing_x"], world["spacing_z"]
    px0, py0 = int(math.floor(opx + X0 / sx)), int(math.floor(opy + Z0 / sz))
    dtm = sources.raster("hirise_dtm_1m").tif
    dtm.workers = 1
    W = nx * K
    cl, cr = max(px0, 0), min(px0 + W, dtm.width)
    acc = np.full((nz, len(ROWS), nx), np.nan, "f4")

    def one(j):
        for r, off in enumerate(ROWS):
            y = py0 + j * K + off
            if not (0 <= y < dtm.height) or cr <= cl:
                continue
            row = dtm.window(cl, y, cr - cl, 1)[0].astype("f4")
            row[(row < -1e30) | ~np.isfinite(row)] = np.nan
            full = np.full(W, np.nan, "f4")
            full[cl - px0:cr - px0] = row
            acc[j, r] = full.reshape(nx, K).mean(1) if not np.isnan(full).any() else np.nanmean(full.reshape(nx, K), 1)
    t0 = time.time()
    with ThreadPoolExecutor(24) as ex:
        for i, _ in enumerate(ex.map(one, range(nz))):
            if i % 100 == 0:
                print("mid rows %d/%d (%.0fs)" % (i, nz, time.time() - t0), flush=True)
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        h = np.nanmean(acc, 1)
    # sample (i, j) sits at the centre of its K x K px block
    x0 = (px0 + K / 2 - opx) * sx
    z0 = (py0 + K / 2 - opy) * sz
    return h, x0, z0, K * sx, K * sz


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", default="world")
    ap.add_argument("--margin", type=float, default=3000.0)
    ap.add_argument("--far-half", type=float, default=80000.0)
    ap.add_argument("--far-step", type=float, default=200.0)
    a = ap.parse_args()
    world = json.load(open(a.world + "/world.json"))
    route = json.load(open(a.world + "/route.json"))["route"]
    xs = [p[0] for s in route for p in s["xz"]]
    zs = [p[1] for s in route for p in s["xz"]]
    datum = world["datum_m"]
    o = world["origin"]
    site = Site(o["lon"], o["lat"])
    site.cos = math.cos(math.radians(o["lat0"]))
    sx, sz = world["spacing_x"], world["spacing_z"]
    out = a.world + "/far"
    os.makedirs(out, exist_ok=True)

    X0, X1 = min(xs) - a.margin, max(xs) + a.margin
    Z0, Z1 = min(zs) - a.margin, max(zs) + a.margin
    nx, nz = int((X1 - X0) / (K * sx)) + 1, int((Z1 - Z0) / (K * sz)) + 1
    print("mid ring %d x %d samples, x %.0f..%.0f z %.0f..%.0f" % (nx, nz, X0, X1, Z0, Z1), flush=True)
    h, mx0, mz0, mdx, mdz = mid_ring(world, X0, Z0, nx, nz)

    hr = sources.raster("hrsc_mola_200m")
    E, S = mx0 + np.arange(nx) * mdx, mz0 + np.arange(nz) * mdz
    g, _ = sample_axes(hr, site, E, S, 1, keep_nan=True)
    both = np.isfinite(h) & np.isfinite(g)
    offset = float(np.median(h[both] - g[both]))
    print("DTM covers %.0f%% of the mid ring; HRSC->DTM offset %.2f m" % (100 * np.isfinite(h).mean(), offset), flush=True)
    h = np.where(np.isfinite(h), h, g + offset)
    h = np.nan_to_num(h, nan=datum)
    (h - datum).astype("<f4").tofile(out + "/mid.f32")

    # CTX brightness texture over the mid rectangle (6 m ground step)
    tn = 6.0
    tE, tS = np.arange(X0, X1, tn), np.arange(Z0, Z1, tn)
    ctx, _ = sample_axes(sources.raster("ctx_ortho_6m"), site, tE, tS, 1, nodata_below=-30000, keep_nan=True)
    lo, hi = np.nanpercentile(ctx, [1, 99])
    t = np.clip((np.nan_to_num(ctx, nan=float(np.nanmedian(ctx))) - lo) / max(hi - lo, 1e-6), 0, 1)
    Image.fromarray((t * 255 + 0.5).astype("u1")).save(out + "/mid_tex.png")
    print("texture %dx%d" % (t.shape[1], t.shape[0]), flush=True)

    # far ring: HRSC/MOLA around the route centre
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    n = int(round(2 * a.far_half / a.far_step)) + 1
    ax = -a.far_half + np.arange(n) * a.far_step
    fh, _ = sample_axes(hr, site, cx + ax, cz + ax, 1, keep_nan=True)
    fh = np.nan_to_num(fh + offset, nan=datum)
    (fh - datum).astype("<f4").tofile(out + "/far.f32")

    json.dump(dict(
        schema=1,
        rings=[
            dict(id="mid", file="mid.f32", nx=nx, nz=nz, x0=mx0, z0=mz0, dx=mdx, dz=mdz, texture="mid_tex.png",
                 tex_rect=[X0, Z0, X1 - X0, Z1 - Z0], subsample=4, lower_m=3.0, skip_covered=True),
            dict(id="far", file="far.f32", nx=n, nz=n, x0=cx - a.far_half, z0=cz - a.far_half, dx=a.far_step, dz=a.far_step,
                 subsample=3, lower_m=6.0, skip_rect=[mx0, mz0, (nx - 1) * mdx, (nz - 1) * mdz]),
        ],
        offset_hrsc_to_dtm_m=offset,
        credit="USGS/JPL HiRISE DTM, CTX orthomosaic; ESA HRSC / NASA MOLA", built_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    ), open(out + "/far.json", "w"), indent=1)
    print("DONE")


if __name__ == "__main__":
    main()

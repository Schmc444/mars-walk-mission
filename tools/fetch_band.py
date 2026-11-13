"""Download the HiRISE 1 m DTM + 25 cm ortho for a band around the Perseverance route (sols <= --sol-max).

Raw blocks in the mosaic's own pixel grid (resumable, no resampling):
  OUT/dtm_<bx>_<by>.f32   BLOCK x BLOCK float32, NaN = no data
  OUT/ortho_<bx>_<by>.u8  4*BLOCK x 4*BLOCK uint8, 0 = no data
  OUT/manifest.json       geometry, route, block list
"""
import argparse, json, math, os, sys, time
from concurrent.futures import ThreadPoolExecutor
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from marswalk import sources
from marswalk.geo import R

BLOCK = 500          # DTM pixels (1 m) per block side; ortho block is 4x
RATIO = 4


def route_points(sol_max, step_m=20.0):
    lines = []
    for f in sources.mission_json("M20_traverse.json")["features"]:
        if f["properties"]["sol"] <= sol_max:
            a = np.array(f["geometry"]["coordinates"])[:, :2]
            lines.append((f["properties"]["sol"], a))
    pts = []
    for sol, a in lines:
        if len(a) < 2:
            pts.extend(a.tolist()); continue
        lon, lat = np.radians(a[:, 0]), np.radians(a[:, 1])
        seg = np.hypot(R * np.cos((lat[1:] + lat[:-1]) / 2) * np.diff(lon), R * np.diff(lat))
        cum = np.r_[0, np.cumsum(seg)]
        for s in np.arange(0, cum[-1] + 1e-9, step_m):
            pts.append([np.interp(s, cum, a[:, 0]), np.interp(s, cum, a[:, 1])])
    return lines, np.array(pts)


def select_blocks(dtm, pts, half_m):
    px, py = dtm.lonlat_to_px(pts[:, 0], pts[:, 1])
    cosl = math.cos(math.radians(float(pts[:, 1].mean())))
    hx, hy = half_m / cosl, half_m
    t = dtm.tif
    nbx, nby = t.width // BLOCK, t.height // BLOCK
    out = []
    for by in range(max(0, int((py.min() - hy) // BLOCK)), min(nby - 1, int((py.max() + hy) // BLOCK)) + 1):
        for bx in range(max(0, int((px.min() - hx) // BLOCK)), min(nbx - 1, int((px.max() + hx) // BLOCK)) + 1):
            x0, x1, y0, y1 = bx * BLOCK, (bx + 1) * BLOCK, by * BLOCK, (by + 1) * BLOCK
            dx = np.maximum(np.maximum(x0 - px, px - x1), 0) * cosl
            dy = np.maximum(np.maximum(y0 - py, py - y1), 0)
            if (np.hypot(dx, dy) <= half_m).any():
                out.append((bx, by))
    return out


def runs(blocks):
    """Group blocks into horizontal runs of consecutive bx within the same by."""
    out = []
    for by in sorted({b[1] for b in blocks}):
        xs = sorted(b[0] for b in blocks if b[1] == by)
        s = p = xs[0]
        for x in xs[1:]:
            if x == p + 1:
                p = x
            else:
                out.append((s, p, by)); s = p = x
        out.append((s, p, by))
    return out


def save(path, arr):
    with open(path + ".part", "wb") as f:
        f.write(np.ascontiguousarray(arr).tobytes())
    os.replace(path + ".part", path)


def fetch_run(args):
    dtm, ortho, out, (b0, b1, by), maxrun = args
    for c0 in range(b0, b1 + 1, maxrun):
        c1 = min(b1, c0 + maxrun - 1)
        n = c1 - c0 + 1
        todo = [bx for bx in range(c0, c1 + 1)
                if not (os.path.exists("%s/dtm_%d_%d.f32" % (out, bx, by)) and os.path.exists("%s/ortho_%d_%d.u8" % (out, bx, by)))]
        if not todo:
            continue
        d = dtm.tif.window(c0 * BLOCK, by * BLOCK, n * BLOCK, BLOCK).astype("f4")
        d[(d < -1e30) | ~np.isfinite(d)] = np.nan
        o = ortho.tif.window(c0 * BLOCK * RATIO, by * BLOCK * RATIO, n * BLOCK * RATIO, BLOCK * RATIO)
        for bx in todo:
            i = bx - c0
            save("%s/dtm_%d_%d.f32" % (out, bx, by), d[:, i * BLOCK:(i + 1) * BLOCK])
            save("%s/ortho_%d_%d.u8" % (out, bx, by), o[:, i * BLOCK * RATIO:(i + 1) * BLOCK * RATIO])
    return (b0, b1, by)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sol-max", type=int, default=1599)
    ap.add_argument("--half-m", type=float, default=500.0)
    ap.add_argument("--out", default="band")
    ap.add_argument("--workers", type=int, default=48, help="parallel HTTP range requests per window read")
    ap.add_argument("--max-run", type=int, default=4, help="max blocks read together in one window")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    dtm, ortho = sources.raster("hirise_dtm_1m"), sources.raster("hirise_ortho_25cm")
    assert (dtm.tif.x0, dtm.tif.y0) == (ortho.tif.x0, ortho.tif.y0) and abs(dtm.tif.px / ortho.tif.px - RATIO) < 1e-9
    dtm.tif.workers = ortho.tif.workers = a.workers
    lines, pts = route_points(a.sol_max)
    blocks = select_blocks(dtm, pts, a.half_m)
    rs = runs(blocks)
    mb = len(blocks) * (BLOCK * BLOCK * 4 + (BLOCK * RATIO) ** 2) / 1e6
    print("route: %d traverse segments (sol<=%d), %d points; band +-%.0f m -> %d blocks of %d m (%.0f MB raw), %d window runs"
          % (len(lines), a.sol_max, len(pts), a.half_m, len(blocks), BLOCK, mb, len(rs)))
    if a.dry_run:
        return
    os.makedirs(a.out, exist_ok=True)
    t = dtm.tif
    manifest = dict(
        schema=1, sol_max=a.sol_max, half_m=a.half_m, block=BLOCK, ortho_ratio=RATIO,
        dtm=dict(url=sources.SOURCES["hirise_dtm_1m"]["url"], px_m=t.px, x0=t.x0, y0=t.y0, width=t.width, height=t.height,
                 credit=sources.SOURCES["hirise_dtm_1m"]["credit"]),
        ortho=dict(url=sources.SOURCES["hirise_ortho_25cm"]["url"], px_m=ortho.tif.px, x0=ortho.tif.x0, y0=ortho.tif.y0,
                   width=ortho.tif.width, height=ortho.tif.height, credit=sources.SOURCES["hirise_ortho_25cm"]["credit"]),
        radius_m=R, built_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        blocks=[list(b) for b in blocks],
        route=[dict(sol=int(s), lonlat=np.round(l, 7).tolist()) for s, l in lines],
    )
    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w"))
    t0 = time.time()
    done = 0
    with ThreadPoolExecutor(2) as ex:
        for r in ex.map(fetch_run, [(dtm, ortho, a.out, r, a.max_run) for r in rs]):
            done += 1
            print("run %d/%d bx %d..%d by %d  (%.0fs)" % (done, len(rs), r[0], r[1], r[2], time.time() - t0), flush=True)
    print("DONE", len(blocks), "blocks in %.0fs" % (time.time() - t0))


if __name__ == "__main__":
    main()

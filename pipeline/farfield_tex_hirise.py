"""Stage: enrich (mid-field albedo). HiRISE 25 cm ortho -> block-averaged texture for the 3 km ring (farfield_tex.png, 4096 px max).
usage: farfield_tex_hirise.py <sol> <site> <drive> [half_km=3] [out_dir]  (threaded tile reads)"""
import json, math, os, sys
import numpy as np
from concurrent.futures import ThreadPoolExecutor
from PIL import Image
from bigtiff_range import RemoteBigTiff

DATA = os.environ.get("MARS_DATA", "../mars_data/")
ORTHO = "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/mars2020_trn/HiRISE/JEZ_hirise_soc_006_orthoMosaic_25cm_Eqc_latTs0_lon0_first.tif"
R = 3396190.0
sol, site, drive = map(int, sys.argv[1:4])
half = float(sys.argv[4]) * 1000 if len(sys.argv) > 4 else 3000.0
out = sys.argv[5]
wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
cx, cy = R * math.radians(wp["lon"]), R * math.radians(wp["lat"])
t = RemoteBigTiff(ORTHO)
print("tiled", t.tiled, t.width, t.height, t.dtype)
K = 6
n = int(2 * half / t.px) // (K * 8) * (K * 8)
x, y = int(round((cx - t.x0) / t.px)) - n // 2, int(round((t.y0 - cy) / t.px)) - n // 2
o = np.zeros((n, n), dtype=t.dtype)
import time
_orig = t._rng
def _retry(a, b):
    for i in range(8):
        try: return _orig(a, b)
        except Exception: time.sleep(1 + i)
    raise RuntimeError("range fetch failed")
t._rng = _retry
def get(job):
    if t.tiled:
        ty, tx = job
        tw, th = t.tags[322][0], t.tags[323][0]
        k = ty * ((t.width + tw - 1) // tw) + tx
        tile = np.frombuffer(t._rng(t.tags[324][k], t.tags[324][k] + t.tags[325][k] - 1), dtype=t.dtype).reshape(th, tw)
        sx0, sy0 = max(x, tx * tw), max(y, ty * th); sx1, sy1 = min(x + n, (tx + 1) * tw), min(y + n, (ty + 1) * th)
        o[sy0 - y:sy1 - y, sx0 - x:sx1 - x] = tile[sy0 - ty * th:sy1 - ty * th, sx0 - tx * tw:sx1 - tx * tw]
    else:
        r = job; rps = t.tags[278][0]; s, rr = divmod(r, rps)
        a = t.tags[273][s] + (rr * t.width + x) * (t.bits // 8)
        o[r - y] = np.frombuffer(t._rng(a, a + n * (t.bits // 8) - 1), dtype=t.dtype)
if t.tiled:
    tw, th = t.tags[322][0], t.tags[323][0]
    jobs = [(a, b) for a in range(y // th, (y + n - 1) // th + 1) for b in range(x // tw, (x + n - 1) // tw + 1)]
else:
    jobs = list(range(y, y + n))
print("jobs", len(jobs), flush=True)
with ThreadPoolExecutor(10) as ex:
    list(ex.map(get, jobs))
m = n // K
b = o.reshape(m, K, m, K).astype("f4").mean(axis=(1, 3))
lo, hi = np.percentile(b, [0.5, 99.5]); print("pct", lo, hi, "res m/px", K * t.px)
Image.fromarray((np.clip((b - lo) / (hi - lo), 0, 1) * 255).astype("u1")).save(out + "/farfield_tex.png")
print("wrote", m)

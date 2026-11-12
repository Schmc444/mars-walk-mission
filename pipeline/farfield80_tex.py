"""Stage: enrich (very far field albedo). Grayscale CTX 100 m quad mosaic (Robbins MC13) resampled onto the farfield80 grid.
usage: farfield80_tex.py <sol> <site> <drive> <mc13.tif> <out_dir>"""
import json, math, os, sys
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
R = 3396190.0
sol, site, drive = map(int, sys.argv[1:4]); tif, out = sys.argv[4], sys.argv[5]
DATA = os.environ.get("MARS_DATA", "../mars_data/")
wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
lon0, lat0 = wp["lon"], wp["lat"]
m = json.load(open(out + "/farfield80.json")); half, n = m["half_m"], m["samples"]
im = Image.open(tif)
X0, Y0, PX = -8002085.55419512, 1778244.0, 100.0
def col(lon): return (R * math.radians(lon - 180) - X0) / PX
def row(lat): return (Y0 - R * math.radians(lat)) / PX
dlat = math.degrees(half / R) * 1.05; dlon = dlat / math.cos(math.radians(lat0))
c0, c1 = int(col(lon0 - dlon)), int(col(lon0 + dlon)) + 2
r0, r1 = int(row(lat0 + dlat)), int(row(lat0 - dlat)) + 2
w = np.asarray(im.crop((c0, r0, c1, r1))).astype("f4")
print("crop", w.shape, w.min(), w.max())
xs = -half + np.arange(n) * (2 * half / (n - 1))
lon = lon0 + np.degrees(xs / (R * math.cos(math.radians(lat0)))); lat = lat0 - np.degrees(xs / R)
fx = np.array([col(l) for l in lon]) - c0; fy = np.array([row(l) for l in lat]) - r0
x0 = np.clip(np.floor(fx).astype(int), 0, w.shape[1] - 2); y0 = np.clip(np.floor(fy).astype(int), 0, w.shape[0] - 2)
tx = np.clip(fx - x0, 0, 1)[None, :]; ty = np.clip(fy - y0, 0, 1)[:, None]
a = w[y0][:, x0]; b = w[y0][:, x0 + 1]; c = w[y0 + 1][:, x0]; d = w[y0 + 1][:, x0 + 1]
t = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
lo, hi = np.percentile(t, [1, 99]); print("pct", lo, hi)
Image.fromarray((np.clip((t - lo) / (hi - lo), 0, 1) * 255).astype("u1")).save(out + "/farfield80_tex.png")

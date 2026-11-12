"""Stage: normalize (very far field). Coarse ring from the global HRSC+MOLA blend DEM (200 m/px) for distant mountains.
usage: farfield_global.py <sol> <site> <drive> [half_km=80] [step_m=160] [out_dir]
Heights are relative to the waypoint's own DTM elevation (meta.json center_elevation_m), same convention as farfield.py."""
import json, math, os, sys
import numpy as np
from bigtiff_range import RemoteBigTiff

DATA = os.environ.get("MARS_DATA", "/home/aschie/dimensional_depot/Archieves/NASA_SpaceApps_2026/mars_data/")
GLOBAL = "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif"
R = 3396190.0
sol, site, drive = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
half = float(sys.argv[4]) * 1000 if len(sys.argv) > 4 else 80000.0
step = float(sys.argv[5]) if len(sys.argv) > 5 else 160.0
out = sys.argv[6] if len(sys.argv) > 6 else "../data/patch_sol%d_site%d_drive%d" % (sol, site, drive)
os.makedirs(out, exist_ok=True)

wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
lon0, lat0 = wp["lon"], wp["lat"]
cen_abs = json.load(open(out + "/meta.json"))["center_elevation_m"]

g = RemoteBigTiff(GLOBAL)
deg_px = g.px
dlat = math.degrees(half / R) * 1.02
dlon = dlat / math.cos(math.radians(lat0))
c0 = int((lon0 - dlon - g.x0) / deg_px)
c1 = int((lon0 + dlon - g.x0) / deg_px) + 2
r0 = int((g.y0 - (lat0 + dlat)) / deg_px)
r1 = int((g.y0 - (lat0 - dlat)) / deg_px) + 2
win = g.window(c0, r0, c1 - c0, r1 - r0).astype("f4")
print("window", win.shape, win.min(), win.max())

n = int(round(2 * half / step)) + 1
xs = -half + np.arange(n) * step            # east, metres (x = R*dlon convention is replaced by true local metres)
zs = -half + np.arange(n) * step            # south, metres
lon = lon0 + np.degrees(xs / (R * math.cos(math.radians(lat0))))
lat = lat0 - np.degrees(zs / R)
fx = (lon - g.x0) / deg_px - c0
fy = (g.y0 - lat) / deg_px - r0
x0 = np.clip(np.floor(fx).astype(int), 0, win.shape[1] - 2)
y0 = np.clip(np.floor(fy).astype(int), 0, win.shape[0] - 2)
tx = np.clip(fx - x0, 0, 1)[None, :]
ty = np.clip(fy - y0, 0, 1)[:, None]
a = win[y0][:, x0]; b = win[y0][:, x0 + 1]; c = win[y0 + 1][:, x0]; d = win[y0 + 1][:, x0 + 1]
h = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
h = (h - cen_abs).astype("f4")
h.tofile(out + "/farfield80.f32")
json.dump({"half_m": half, "samples": int(n), "step_m": step, "center_elevation_m": cen_abs,
           "min": float(h.min()), "max": float(h.max())}, open(out + "/farfield80.json", "w"))
print("farfield80", n, "x", n, "step", step, "m  range", h.min(), h.max())

"""Stage: normalize (far field). Coarse DTM ring around a waypoint for the horizon.
usage: farfield.py <sol> <site> <drive> [half_km=3] [factor=6] [out_dir]"""
import json, math, os, sys
import numpy as np
from bigtiff_range import RemoteBigTiff

DATA = os.environ.get("MARS_DATA", "../mars_data/")
DTM = DATA + "JEZ_hirise_soc_006_DTM_MOLAtopography_DeltaGeoid_1m_Eqc_latTs0_lon0_blend40.tif"
R = 3396190.0
sol, site, drive = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
half = int(float(sys.argv[4]) * 1000) if len(sys.argv) > 4 else 3000
k = int(sys.argv[5]) if len(sys.argv) > 5 else 6
out = sys.argv[6] if len(sys.argv) > 6 else "../data/patch_sol%d_site%d_drive%d" % (sol, site, drive)
os.makedirs(out, exist_ok=True)

wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
cx, cy = R * math.radians(wp["lon"]), R * math.radians(wp["lat"])
dtm = RemoteBigTiff(DTM)
n = 2 * half
x0 = int(round(cx - dtm.x0)) - half
y0 = int(round(dtm.y0 - cy)) - half
assert x0 >= 0 and y0 >= 0 and x0 + n <= dtm.width and y0 + n <= dtm.height, "far field leaves DTM"
h = dtm.window(x0, y0, n, n).astype("f4")
bad = h < -1e30
print("nodata fraction", bad.mean())
h[bad] = np.nan
m = n // k
b = h[:m * k, :m * k].reshape(m, k, m, k)
c = np.nanmean(b, axis=(1, 3))
c[np.isnan(c)] = np.nanmin(c)
cen = float(dtm.window(int(round(cx - dtm.x0)), int(round(dtm.y0 - cy)), 1, 1)[0, 0])
c = (c - cen).astype("f4")
c.tofile(out + "/farfield.f32")
json.dump({"half_m": half, "samples": int(m), "step_m": k, "center_elevation_m": cen,
           "min": float(c.min()), "max": float(c.max())}, open(out + "/farfield.json", "w"))
print("farfield", m, "x", m, "step", k, "m  range", c.min(), c.max())

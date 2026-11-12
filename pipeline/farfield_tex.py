"""Stage: enrich (far-field albedo). Grayscale CTX 6 m ortho texture for the 6 km ring (same extent as farfield6).
usage: farfield_tex.py <sol> <site> <drive> [half_km=6] [out_dir] ; writes farfield6_tex.png (1000x1000)"""
import json, math, os, sys
import numpy as np
from PIL import Image
from bigtiff_range import RemoteBigTiff

DATA = os.environ.get("MARS_DATA", "../mars_data/")
CTX = "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/mars2020_trn/CTX/JEZ_ctx_B_soc_008_orthoMosaic_6m_Eqc_latTs0_lon0.tif"
R = 3396190.0
sol, site, drive = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
half = int(float(sys.argv[4]) * 1000) if len(sys.argv) > 4 else 6000
out = sys.argv[5] if len(sys.argv) > 5 else "../data/patch_sol%d_site%d_drive%d" % (sol, site, drive)
wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
cx, cy = R * math.radians(wp["lon"]), R * math.radians(wp["lat"])
t = RemoteBigTiff(CTX)
n = int(2 * half / t.px)
c0 = int(round((cx - t.x0) / t.px)) - n // 2
r0 = int(round((t.y0 - cy) / t.px)) - n // 2
assert c0 >= 0 and r0 >= 0 and c0 + n <= t.width and r0 + n <= t.height, "ring leaves CTX mosaic"
w = t.window(c0, r0, n, n)
Image.fromarray(w).resize((1000, 1000), Image.LANCZOS).save(out + "/farfield6_tex.png")
print("wrote", out + "/farfield6_tex.png", "mean", w.mean(), "nodata0 frac", (w == 0).mean())

"""Stage: normalize. Cut a square patch around one rover waypoint into viewer-ready files.
usage: patch.py <sol> <site> <drive> [size_m=100] [out_dir]"""
import json, math, os, sys
import numpy as np
from PIL import Image
from bigtiff_range import RemoteBigTiff

DATA = os.environ.get("MARS_DATA", "/home/aschie/dimensional_depot/Archieves/NASA_SpaceApps_2026/mars_data/")
DTM = DATA + "JEZ_hirise_soc_006_DTM_MOLAtopography_DeltaGeoid_1m_Eqc_latTs0_lon0_blend40.tif"
ORTHO = "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/mars2020_trn/HiRISE/JEZ_hirise_soc_006_orthoMosaic_25cm_Eqc_latTs0_lon0_first.tif"
R = 3396190.0

sol, site, drive = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
size = int(sys.argv[4]) if len(sys.argv) > 4 else 100
out = sys.argv[5] if len(sys.argv) > 5 else "../data/patch_sol%d_site%d_drive%d" % (sol, site, drive)
os.makedirs(out, exist_ok=True)

wp = [f for f in json.load(open(DATA + "M20_waypoints.json"))["features"]
      if f["properties"]["sol"] == sol and f["properties"]["site"] == site and f["properties"]["drive"] == drive][0]["properties"]
cx_m, cy_m = R * math.radians(wp["lon"]), R * math.radians(wp["lat"])

dtm = RemoteBigTiff(DTM)
n = size + 1
dx = int(round(cx_m - dtm.x0)) - size // 2
dy = int(round(dtm.y0 - cy_m)) - size // 2
h = dtm.window(dx, dy, n, n).astype("f4")
assert (h > -1e30).all(), "nodata inside patch"
cen = h[size // 2, size // 2]
h -= cen
h.tofile(out + "/heightmap.f32")

ortho = RemoteBigTiff(ORTHO)
k = 4
ox = int(round((cx_m - ortho.x0) / 0.25)) - size * k // 2
oy = int(round((ortho.y0 - cy_m) / 0.25)) - size * k // 2
Image.fromarray(ortho.window(ox, oy, n * k, n * k)).save(out + "/ortho.png")

route = []
for f in json.load(open(DATA + "M20_traverse.json"))["features"]:
    pts = []
    for lon, lat, _ in f["geometry"]["coordinates"]:
        x = R * math.radians(lon) - dtm.x0 - dx
        z = dtm.y0 - R * math.radians(lat) - dy
        pts.append([round(x - size / 2, 2), round(z - size / 2, 2)])
    if any(abs(p[0]) <= size / 2 and abs(p[1]) <= size / 2 for p in pts):
        route.append({"sol": f["properties"]["sol"], "points": pts})
json.dump(route, open(out + "/route_local.json", "w"))

json.dump({
    "size_m": size, "samples": n, "step_m": 1.0, "ortho_px": n * k, "ortho_step_m": 0.25,
    "axes": "x east, z south, y up (m), origin = rover waypoint", "center_elevation_m": float(cen),
    "waypoint": {k2: wp[k2] for k2 in ("sol", "site", "drive", "lon", "lat", "roll", "pitch", "yaw")},
    "sources": {"dtm": "USGS/JPL Mars 2020 TRN HiRISE DTM mosaic 1 m", "ortho": "USGS/JPL Mars 2020 TRN HiRISE ortho mosaic 25 cm (grayscale)"},
    "relief_m": float(h.max() - h.min()),
}, open(out + "/meta.json", "w"), indent=1)
print(out, "relief", h.max() - h.min(), "route segs", len(route))

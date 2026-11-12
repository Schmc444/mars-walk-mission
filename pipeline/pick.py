import json, math, sys
import numpy as np
from bigtiff_range import RemoteBigTiff
DATA = "/home/aschie/dimensional_depot/Archieves/NASA_SpaceApps_2026/mars_data/"
R = 3396190.0
dtm = RemoteBigTiff(DATA + "JEZ_hirise_soc_006_DTM_MOLAtopography_DeltaGeoid_1m_Eqc_latTs0_lon0_blend40.tif")
w = json.load(open(DATA + "M20_waypoints.json"))["features"]
rows = []
for f in w:
    p = f["properties"]
    if p["final"] != "y" or not (300 <= p["sol"] <= 1500):
        continue
    x = int(R * math.radians(p["lon"]) - dtm.x0) - 50
    y = int(dtm.y0 - R * math.radians(p["lat"])) - 50
    if x < 0 or y < 0 or x + 100 >= dtm.width or y + 100 >= dtm.height:
        continue
    a = dtm.window(x, y, 100, 100).astype("f8")
    if (a < -1e30).any():
        continue
    gy, gx = np.gradient(a)
    sl = np.degrees(np.arctan(np.hypot(gx, gy)))
    rows.append((a.max() - a.min(), sl.mean(), sl.max(), p["sol"], p["site"], p["drive"], p["lon"], p["lat"]))
rows.sort(reverse=True)
print(len(rows), "candidates; relief, meanslope, maxslope, sol, site, drive")
for r in rows[:: max(1, len(rows) // 12)]:
    print("%.1f %.1f %.1f sol%d site%d drive%d" % r[:6])

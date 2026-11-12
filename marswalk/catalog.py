"""Index of the public HiRISE DTMs (NASA/USGS, AWS open data). Built once from the TIFF headers, so no extra catalog is needed."""
import json, math, re, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from .bigtiff import RemoteBigTiff
from .geo import R

BUCKET = "https://astrogeo-ard.s3.us-west-2.amazonaws.com"
PREFIX = "mars/mro/hirise/controlled/dtm/"


def _get(url):
    for k in range(5):
        try:
            return urllib.request.urlopen(url, timeout=60).read().decode()
        except Exception:
            if k == 4:
                raise


def list_folders():
    out, tok = [], None
    while True:
        u = "%s/?list-type=2&prefix=%s&delimiter=/&max-keys=1000" % (BUCKET, PREFIX)
        if tok:
            u += "&continuation-token=" + urllib.parse.quote(tok, safe="")
        r = _get(u)
        out += [p for p in re.findall(r"<Prefix>([^<]*)</Prefix>", r) if p != PREFIX]
        m = re.search(r"<NextContinuationToken>([^<]*)", r)
        if not m:
            return out
        tok = m.group(1)


def _entry(folder):
    keys = re.findall(r"<Key>([^<]*)</Key>", _get("%s/?list-type=2&prefix=%s" % (BUCKET, folder)))
    name = folder[len(PREFIX):].strip("/")
    dtm = [k for k in keys if re.search(r"/DTE[EP][CD]_[^/]*_[A-Z]\d+\.tif$", k) and "hillshade" not in k]
    ortho = [k for k in keys if k.endswith("_ORTHO.tif") and "_RED_" in k]
    e = {"id": name, "dtm": dtm[0] if dtm else None, "ortho": ortho}
    if not dtm:
        return e
    t = RemoteBigTiff("%s/%s" % (BUCKET, dtm[0]))
    crs = str(t.tags.get(34737, ""))
    if "Equirectangular" not in crs:
        e["skipped"] = "projection: " + crs.split("|")[0][:60]
        return e
    clon = 0.0
    m = re.search(r"clon = ([-0-9.]+)", crs)
    if m:
        clon = float(m.group(1))
    x0, y0, px = t.x0, t.y0, t.px
    x1, y1 = x0 + t.width * px, y0 - t.height * px
    e.update(width=t.width, height=t.height, px_m=round(px, 4), dtype=t.dtype, nodata=t.nodata,
             lon_w=round(math.degrees(x0 / R) + clon, 5), lon_e=round(math.degrees(x1 / R) + clon, 5),
             lat_n=round(math.degrees(y0 / R), 5), lat_s=round(math.degrees(y1 / R), 5),
             area_km2=round(t.width * t.height * px * px / 1e6, 1))
    return e


def build_index(workers=16, progress=None):
    folders = list_folders()
    out = []

    def one(f):
        try:
            return _entry(f)
        except Exception as ex:
            return {"id": f[len(PREFIX):].strip("/"), "error": str(ex)[:120]}
    with ThreadPoolExecutor(workers) as ex:
        for i, e in enumerate(ex.map(one, folders)):
            out.append(e)
            if progress and i % 100 == 0:
                progress(i, len(folders))
    return {"schema": 1, "bucket": BUCKET, "sites": sorted(out, key=lambda e: e["id"])}


def find(index, lon, lat, margin_deg=0.0):
    """Sites whose DTM footprint contains lon/lat (bounding box; may include nodata corners)."""
    return [s for s in index["sites"] if "lon_w" in s and s["lon_w"] - margin_deg <= lon <= s["lon_e"] + margin_deg
            and s["lat_s"] - margin_deg <= lat <= s["lat_n"] + margin_deg]

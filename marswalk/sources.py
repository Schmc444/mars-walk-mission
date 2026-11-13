"""Registry of source datasets. Add a new mosaic here, then point a layer at its id."""
import json, os, urllib.request
from .bigtiff import RemoteBigTiff
from .geo import Raster, ClonRaster

S3 = "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic"
MMGIS = "https://mars.nasa.gov/mmgis-maps/M20/Layers/json/"

SOURCES = {
    "hirise_dtm_1m": dict(url=S3 + "/mars2020_trn/HiRISE/JEZ_hirise_soc_006_DTM_MOLAtopography_DeltaGeoid_1m_Eqc_latTs0_lon0_blend40.tif",
                          unit="m", name="HiRISE DTM 1 m (USGS/JPL Mars 2020 TRN mosaic)", credit="USGS Astrogeology / NASA JPL"),
    "hirise_ortho_25cm": dict(url=S3 + "/mars2020_trn/HiRISE/JEZ_hirise_soc_006_orthoMosaic_25cm_Eqc_latTs0_lon0_first.tif",
                              unit="m", name="HiRISE orthophoto 25 cm (grayscale)", credit="USGS Astrogeology / NASA JPL"),
    "ctx_ortho_6m": dict(url=S3 + "/mars2020_trn/CTX/JEZ_ctx_B_soc_008_orthoMosaic_6m_Eqc_latTs0_lon0.tif",
                         unit="m", name="CTX orthophoto 6 m (grayscale)", credit="USGS Astrogeology / NASA JPL"),
    "hrsc_mola_200m": dict(url=S3 + "/Mars/HRSC_MOLA_Blend/Mars_HRSC_MOLA_BlendDEM_Global_200mp_v2.tif",
                           unit="deg", name="HRSC+MOLA blended global DEM 200 m", credit="ESA/DLR HRSC, NASA MOLA, USGS"),
}

_open = {}


def raster(source_id):
    """Open a registered mosaic once per process. MARSWALK_LOCAL_<ID> (a file path) overrides the URL for offline use."""
    if source_id not in _open:
        s = SOURCES[source_id]
        url = os.environ.get("MARSWALK_LOCAL_" + source_id.upper(), s["url"])
        _open[source_id] = Raster(RemoteBigTiff(url), s["unit"])
    return _open[source_id]


def cache_dir():
    d = os.environ.get("MARSWALK_CACHE", os.path.expanduser("~/.cache/marswalk"))
    os.makedirs(d, exist_ok=True)
    return d


def mission_json(name):
    """M20_waypoints.json / M20_traverse.json: MARS_DATA copy if present, else downloaded once into the cache."""
    legacy = os.path.join(os.environ.get("MARS_DATA", ""), name)
    if os.environ.get("MARS_DATA") and os.path.exists(legacy):
        return json.load(open(legacy))
    p = os.path.join(cache_dir(), name)
    if not os.path.exists(p):
        urllib.request.urlretrieve(MMGIS + name, p + ".part")
        os.replace(p + ".part", p)
    return json.load(open(p))


def find_waypoint(sol, site, drive):
    for f in mission_json("M20_waypoints.json")["features"]:
        p = f["properties"]
        if p["sol"] == sol and p["site"] == site and p["drive"] == drive:
            return p
    raise KeyError("no waypoint sol=%s site=%s drive=%s" % (sol, site, drive))


def use_hirise_site(entry):
    """Point the hirise_dtm_1m / hirise_ortho_25cm sources at one site of data/hirise_dtm_index.json."""
    from .catalog import BUCKET
    assert entry.get("dtm") and entry.get("ortho"), "site has no DTM/ortho"
    red = [k for k in entry["ortho"] if "_RED_A_" in k] or entry["ortho"]
    SOURCES["hirise_dtm_1m"] = dict(url="%s/%s" % (BUCKET, entry["dtm"]), unit="m", name="HiRISE DTM %s" % entry["id"],
                                    credit="NASA/USGS/University of Arizona HiRISE")
    SOURCES["hirise_ortho_25cm"] = dict(url="%s/%s" % (BUCKET, red[0]), unit="m", name="HiRISE orthophoto %s" % red[0].split("/")[-1],
                                        credit="NASA/USGS/University of Arizona HiRISE")
    _open.pop("hirise_dtm_1m", None)
    _open.pop("hirise_ortho_25cm", None)


CTX_QUADS = S3 + "/Mars/Mars_MRO_CTX_Equi_Mosaics_Robbins/%s/MC%02d_%s.16bit.tif"
CTX_CREDIT = "NASA/JPL/MSSS CTX; Robbins equirectangular quad mosaics (hosted by USGS Astrogeology)"


def ctx_quad_id(lon, lat):
    """Robbins CTX quad MC08..MC23 covering lon/lat (45 deg wide, +-30 deg lat), or None."""
    if abs(lat) >= 30:
        return None
    return (8 if lat >= 0 else 16) + int(((lon + 180) % 360) // 45)


def ctx_raster(quad, res):
    """res '100mpp' or '6mpp'."""
    key = "ctx_%s_%d" % (res, quad)
    if key not in _open:
        _open[key] = ClonRaster(RemoteBigTiff(CTX_QUADS % (res, quad, res)), "m")
    return _open[key]


def ctx_source(res):
    return {"id": "ctx_robbins_" + res, "name": "CTX global quad mosaics, " + res.replace("mpp", " m"),
            "credit": CTX_CREDIT, "url": CTX_QUADS.split("%s")[0]}

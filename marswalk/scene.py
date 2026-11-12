"""scene.json: the contract between the generator, the viewers and any layer a teammate adds."""
import datetime, json, os
from . import __version__
from .geo import R

SCHEMA = 1


def make_manifest(wp, entries, extra=None):
    rasters = [e for e in entries if e["kind"] != "polylines"]
    return {
        "schema": SCHEMA,
        "id": "m20_sol%d_site%d_drive%d" % (wp["sol"], wp["site"], wp["drive"]),
        "generator": {"name": "marswalk", "version": __version__,
                      "built_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
        "body": {"name": "Mars", "radius_m": R},
        "axes": "x east, z south, y up, ground metres, origin = waypoint; raster row 0 = north, grids centred on origin",
        "origin": {k: wp[k] for k in ("sol", "site", "drive", "lon", "lat", "roll", "pitch", "yaw") if k in wp},
        "layers": entries,
        **(extra or {}),
    }


def write_manifest(out, manifest):
    json.dump(manifest, open(os.path.join(out, "scene.json"), "w"), indent=1)


def validate(folder):
    """Return a list of problems (empty = valid)."""
    p = os.path.join(folder, "scene.json")
    if not os.path.exists(p):
        return ["scene.json missing"]
    m, bad = json.load(open(p)), []
    if m.get("schema") != SCHEMA:
        bad.append("schema %r != %d" % (m.get("schema"), SCHEMA))
    ids = set()
    for e in m.get("layers", []):
        if e["id"] in ids:
            bad.append("duplicate layer id " + e["id"])
        ids.add(e["id"])
        f = os.path.join(folder, e["file"])
        if not os.path.exists(f):
            bad.append("%s: file %s missing" % (e["id"], e["file"]))
        elif e.get("dtype") == "f32" and os.path.getsize(f) != 4 * e["samples"] ** 2:
            bad.append("%s: %s has %d bytes, expected %d" % (e["id"], e["file"], os.path.getsize(f), 4 * e["samples"] ** 2))
        if e.get("texture") and not os.path.exists(os.path.join(folder, e["texture"])):
            bad.append("%s: texture %s missing" % (e["id"], e["texture"]))
    return bad

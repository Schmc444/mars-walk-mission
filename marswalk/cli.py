import argparse, json, os, sys
from . import layers as L
from .scene import make_manifest, write_manifest, validate
from .sources import find_waypoint


def site_waypoint(a):
    """Pick an origin inside a HiRISE DTM: --lon/--lat if given, else the centre-most 91x91 m patch with valid data."""
    import numpy as np
    from .sources import use_hirise_site, raster
    from .geo import Site, sample_ground_grid
    idx = json.load(open(INDEX))
    e = next(x for x in idx["sites"] if x["id"] == a.site)
    use_hirise_site(e)
    cl, ct = (e["lon_w"] + e["lon_e"]) / 2, (e["lat_n"] + e["lat_s"]) / 2
    if a.lon is not None:
        cands = [(a.lon, a.lat)]
    else:
        cands = [(cl + i * (e["lon_e"] - e["lon_w"]) * 0.05, ct + j * (e["lat_n"] - e["lat_s"]) * 0.05)
                 for i in range(-8, 9) for j in range(-8, 9)]
        cands.sort(key=lambda c: abs(c[0] - cl) + abs(c[1] - ct))
    for lon, lat in cands:
        try:
            g, bad = sample_ground_grid(raster("hirise_dtm_1m"), Site(lon, lat), a.size / 2 + 5, 1.0, keep_nan=True)
        except Exception:
            continue
        if bad == 0:
            print("origin lon %.5f lat %.5f" % (lon, lat))
            return dict(id="hirise_%s_%.4f_%.4f" % (e["id"], lon, lat), label="%s  (%.3f, %.3f)" % (e["id"], lon, lat),
                        lon=lon, lat=lat, yaw=0.0)
    raise SystemExit("no valid DTM patch found; pass --lon/--lat explicitly")


def build(a):
    if a.site:
        wp = site_waypoint(a)
        out = a.out or "viewer-godot/scene_" + a.site
    else:
        wp = find_waypoint(a.sol, a.site_no, a.drive)
        out = a.out or "viewer-godot/scene_sol%d" % a.sol
    os.makedirs(out, exist_ok=True)
    ctx = L.Context(wp, out, a.size)
    want = a.layers.split(",") if a.layers else list(L.ORDER)
    done, entries = set(), []

    def run(lid):
        if lid in done:
            return
        for r in L.LAYERS[lid].requires:
            run(r)
        print("[%s]" % lid, flush=True)
        entries.extend(L.LAYERS[lid](ctx))
        done.add(lid)
    for lid in want:
        run(lid)
    write_manifest(out, make_manifest(wp, entries))
    problems = validate(out)
    print(out, "OK" if not problems else problems)
    return 1 if problems else 0


def adopt(a):
    """Write scene.json for a legacy patch folder (meta.json + farfield*.f32) so existing patches use the new contract."""
    d = a.folder
    meta = json.load(open(os.path.join(d, "meta.json")))
    wp = meta["waypoint"]
    cen = meta["center_elevation_m"]
    ent = [dict(id="terrain", title="Terrain (1 m)", kind="elevation", file="heightmap.f32", dtype="f32", samples=meta["samples"],
                step_m=meta["step_m"], half_m=meta["size_m"] / 2, unit="m", relative_to="origin elevation", legacy=True),
           dict(id="ortho", title="Orbital photo (25 cm)", kind="image", file="ortho.png", samples=meta["ortho_px"],
                step_m=meta["ortho_step_m"], half_m=meta["size_m"] / 2, legacy=True),
           dict(id="route", title="Driven route", kind="polylines", file="route_local.json", frame="ground_m", legacy=True)]
    for rid, base, skip, sub, low in (("ring_3km", "farfield", meta["size_m"] / 2 - 8.0, 3, 2.5),
                                      ("ring_6km", "farfield6", 2990.0, 3, 3.0), ("ring_80km", "farfield80", 5990.0, 2, 6.0)):
        if os.path.exists(os.path.join(d, base + ".f32")):
            fm = json.load(open(os.path.join(d, base + ".json")))
            e = dict(id=rid, title=rid, kind="elevation", role="ring", file=base + ".f32", dtype="f32", samples=fm["samples"],
                     step_m=fm["step_m"], half_m=fm["half_m"], unit="m", relative_to="origin elevation", min=fm["min"],
                     max=fm["max"], inner_skip_m=skip, view=dict(subsample=sub, lower_m=low), legacy=True)
            if os.path.exists(os.path.join(d, base + "_tex.png")):
                e["texture"] = base + "_tex.png"
            ent.append(e)
    m = make_manifest(wp, ent)
    m["origin"]["elevation_m"] = cen
    write_manifest(d, m)
    print(d, validate(d) or "OK")


def check(a):
    p = validate(a.folder)
    print("OK" if not p else "\n".join(p))
    return 1 if p else 0


INDEX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "hirise_dtm_index.json")


def index(a):
    from . import catalog
    json.dump(catalog.build_index(progress=lambda i, n: print(i, "/", n, flush=True)), open(INDEX, "w"), indent=0)


def find(a):
    from . import catalog
    for s in catalog.find(json.load(open(INDEX)), a.lon, a.lat, a.margin):
        print("%s  %.1f km2  %.2f m/px  lon %.3f..%.3f lat %.3f..%.3f" % (s["id"], s["area_km2"], s["px_m"], s["lon_w"], s["lon_e"], s["lat_s"], s["lat_n"]))


def main():
    ap = argparse.ArgumentParser(prog="marswalk", description="Generate walkable Mars scenes from orbital data.")
    sp = ap.add_subparsers(dest="cmd", required=True)
    b = sp.add_parser("build", help="build a scene for a rover waypoint")
    b.add_argument("sol", type=int, nargs="?"); b.add_argument("site_no", type=int, nargs="?"); b.add_argument("drive", type=int, nargs="?")
    b.add_argument("--site", help="HiRISE DTM id from data/hirise_dtm_index.json (instead of a rover waypoint)")
    b.add_argument("--lon", type=float); b.add_argument("--lat", type=float)
    b.add_argument("--out"); b.add_argument("--size", type=int, default=90, help="walkable patch size in m")
    b.add_argument("--layers", help="comma list; default all. See `marswalk layers`")
    b.set_defaults(fn=build)
    ad = sp.add_parser("adopt", help="write scene.json for an old-format patch folder"); ad.add_argument("folder"); ad.set_defaults(fn=adopt)
    c = sp.add_parser("validate", help="check a scene folder against its scene.json"); c.add_argument("folder"); c.set_defaults(fn=check)
    ix = sp.add_parser("index", help="rebuild data/hirise_dtm_index.json from the public HiRISE DTM bucket"); ix.set_defaults(fn=index)
    fd = sp.add_parser("find", help="list HiRISE DTMs covering a lon/lat")
    fd.add_argument("lon", type=float); fd.add_argument("lat", type=float); fd.add_argument("--margin", type=float, default=0.0)
    fd.set_defaults(fn=find)
    ls = sp.add_parser("layers", help="list available layers")
    ls.set_defaults(fn=lambda a: print("\n".join("%-10s requires %s" % (k, ",".join(L.LAYERS[k].requires) or "-") for k in L.ORDER)))
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)

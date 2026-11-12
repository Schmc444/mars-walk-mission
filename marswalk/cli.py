import argparse, json, os, sys
from . import layers as L
from .scene import make_manifest, write_manifest, validate
from .sources import find_waypoint


def build(a):
    wp = find_waypoint(a.sol, a.site, a.drive)
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


def main():
    ap = argparse.ArgumentParser(prog="marswalk", description="Generate walkable Mars scenes from orbital data.")
    sp = ap.add_subparsers(dest="cmd", required=True)
    b = sp.add_parser("build", help="build a scene for a rover waypoint")
    b.add_argument("sol", type=int); b.add_argument("site", type=int); b.add_argument("drive", type=int)
    b.add_argument("--out"); b.add_argument("--size", type=int, default=90, help="walkable patch size in m")
    b.add_argument("--layers", help="comma list; default all. See `marswalk layers`")
    b.set_defaults(fn=build)
    ad = sp.add_parser("adopt", help="write scene.json for an old-format patch folder"); ad.add_argument("folder"); ad.set_defaults(fn=adopt)
    c = sp.add_parser("validate", help="check a scene folder against its scene.json"); c.add_argument("folder"); c.set_defaults(fn=check)
    ls = sp.add_parser("layers", help="list available layers")
    ls.set_defaults(fn=lambda a: print("\n".join("%-10s requires %s" % (k, ",".join(L.LAYERS[k].requires) or "-") for k in L.ORDER)))
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)

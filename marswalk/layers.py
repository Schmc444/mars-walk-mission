"""Layer plugins. A layer reads sources, writes files into the scene folder and returns manifest entries.

To add a layer: write a function `def my_layer(ctx): ... return [entry, ...]`, decorate it with
`@layer("my_id", requires=("terrain",))`. Entries are plain dicts (see docs/SCENE_FORMAT.md). Layers share state through
`ctx.scene` (e.g. `ctx.scene["center_elevation_m"]`).
"""
import json, math, os
import numpy as np
from PIL import Image
from .geo import Site, sample_ground_grid
from .sources import SOURCES, raster, mission_json

LAYERS = {}
ORDER = []


def layer(layer_id, requires=()):
    def deco(fn):
        fn.layer_id, fn.requires = layer_id, requires
        LAYERS[layer_id] = fn
        ORDER.append(layer_id)
        return fn
    return deco


class Context:
    def __init__(self, wp, out, size_m=90):
        self.wp, self.out, self.size_m = wp, out, size_m
        self.site = Site(wp["lon"], wp["lat"])
        self.scene = {}

    def path(self, name):
        return os.path.join(self.out, name)


def src(source_id):
    s = SOURCES[source_id]
    return {"id": source_id, "name": s["name"], "credit": s["credit"], "url": s["url"]}


@layer("terrain")
def terrain(ctx):
    half = ctx.size_m / 2
    h, bad = sample_ground_grid(raster("hirise_dtm_1m"), ctx.site, half, 1.0)
    assert bad == 0, "nodata inside the walkable patch"
    c = ctx.size_m // 2
    cen = float(h[c, c])
    ctx.scene["center_elevation_m"] = cen
    (h - cen).astype("f4").tofile(ctx.path("heightmap.f32"))
    n = h.shape[0]
    return [dict(id="terrain", title="Terrain (1 m)", kind="elevation", file="heightmap.f32", dtype="f32", samples=n,
                 step_m=1.0, half_m=half, unit="m", relative_to="origin elevation", min=float(h.min() - cen),
                 max=float(h.max() - cen), source=src("hirise_dtm_1m"))]


@layer("ortho", requires=("terrain",))
def ortho(ctx):
    k = 4
    half = ctx.size_m / 2
    o, _ = sample_ground_grid(raster("hirise_ortho_25cm"), ctx.site, half, 1.0 / k)
    Image.fromarray(np.clip(o + 0.5, 0, 255).astype("u1")).save(ctx.path("ortho.png"))
    return [dict(id="ortho", title="Orbital photo (25 cm)", kind="image", file="ortho.png", samples=o.shape[0],
                 step_m=1.0 / k, half_m=half, source=src("hirise_ortho_25cm"))]


@layer("route")
def route(ctx):
    half = ctx.size_m / 2
    segs = []
    for f in mission_json("M20_traverse.json")["features"]:
        pts = [[round(v, 2) for v in ctx.site.to_ground(lon, lat)] for lon, lat, *_ in f["geometry"]["coordinates"]]
        if any(abs(p[0]) <= half and abs(p[1]) <= half for p in pts):
            segs.append({"sol": f["properties"]["sol"], "points": pts})
    json.dump(segs, open(ctx.path("route_local.json"), "w"))
    return [dict(id="route", title="Driven route", kind="polylines", file="route_local.json", frame="ground_m",
                 source={"id": "m20_traverse", "name": "Mars 2020 traverse (NASA/JPL MMGIS)", "credit": "NASA/JPL"})]


def _ring(ctx, rid, title, source, half_m, step_m, block, inner_skip_m, view):
    h, bad = sample_ground_grid(raster(source), ctx.site, half_m, step_m, block)
    h = (h - ctx.scene["center_elevation_m"]).astype("f4")
    h.tofile(ctx.path(rid + ".f32"))
    return [dict(id=rid, title=title, kind="elevation", role="ring", file=rid + ".f32", dtype="f32", samples=h.shape[0],
                 step_m=step_m, half_m=half_m, unit="m", relative_to="origin elevation", min=float(h.min()),
                 max=float(h.max()), inner_skip_m=inner_skip_m, view=view, source=src(source))]


@layer("ring_3km", requires=("terrain",))
def ring_3km(ctx):
    return _ring(ctx, "ring_3km", "Near field (3 km, 6 m)", "hirise_dtm_1m", 3000, 6, 6, ctx.size_m / 2 - 8.0,
                 dict(subsample=3, lower_m=2.5))


@layer("ring_6km", requires=("terrain",))
def ring_6km(ctx):
    return _ring(ctx, "ring_6km", "Mid field (6 km, 12 m)", "hirise_dtm_1m", 6000, 12, 12, 2990.0,
                 dict(subsample=3, lower_m=3.0))


@layer("ring_80km", requires=("terrain",))
def ring_80km(ctx):
    return _ring(ctx, "ring_80km", "Far field (80 km, 160 m)", "hrsc_mola_200m", 80000, 160, 1, 5990.0,
                 dict(subsample=2, lower_m=6.0))


@layer("slope", requires=("terrain",))
def slope(ctx):
    h = np.fromfile(ctx.path("heightmap.f32"), "f4").reshape(-1, int(round(ctx.size_m)) + 1)
    gy, gx = np.gradient(h, 1.0)
    deg = np.degrees(np.arctan(np.hypot(gx, gy))).astype("f4")
    deg.tofile(ctx.path("slope.f32"))
    return [dict(id="slope", title="Slope", kind="scalar", file="slope.f32", dtype="f32", samples=deg.shape[0],
                 step_m=1.0, half_m=ctx.size_m / 2, unit="deg", min=float(deg.min()), max=float(deg.max()),
                 hazard_deg=15.0, derived_from="terrain")]

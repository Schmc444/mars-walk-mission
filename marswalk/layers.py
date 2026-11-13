"""Layer plugins. A layer reads sources, writes files into the scene folder and returns manifest entries.

To add a layer: write a function `def my_layer(ctx): ... return [entry, ...]`, decorate it with
`@layer("my_id", requires=("terrain",))`. Entries are plain dicts (see docs/SCENE_FORMAT.md). Layers share state through
`ctx.scene` (e.g. `ctx.scene["center_elevation_m"]`).
"""
import json, math, os
import numpy as np
from PIL import Image
from .geo import Site, sample_ground_grid, sample_axes, block_mean
from .sources import SOURCES, raster, mission_json, ctx_quad_id, ctx_raster, ctx_source

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
    if raster("hirise_ortho_25cm").tif.dtype != "u1":
        lo, hi = np.percentile(o[o > 0], [1, 99.5]) if (o > 0).any() else (0, 1)
        o = (o - lo) / max(hi - lo, 1e-6) * 255
    Image.fromarray(np.clip(o + 0.5, 0, 255).astype("u1")).save(ctx.path("ortho.png"))
    return [dict(id="ortho", title="Orbital photo (25 cm)", kind="image", file="ortho.png", samples=o.shape[0],
                 step_m=1.0 / k, half_m=half, source=src("hirise_ortho_25cm"))]


@layer("route")
def route(ctx):
    half = ctx.size_m / 2
    segs = []
    if ctx.wp.get("sol") is None:
        json.dump(segs, open(ctx.path("route_local.json"), "w"))
        return [dict(id="route", title="Route (none for this site)", kind="polylines", file="route_local.json", frame="ground_m")]
    for f in mission_json("M20_traverse.json")["features"]:
        pts = [[round(v, 2) for v in ctx.site.to_ground(lon, lat)] for lon, lat, *_ in f["geometry"]["coordinates"]]
        if any(abs(p[0]) <= half and abs(p[1]) <= half for p in pts):
            segs.append({"sol": f["properties"]["sol"], "points": pts})
    json.dump(segs, open(ctx.path("route_local.json"), "w"))
    return [dict(id="route", title="Driven route", kind="polylines", file="route_local.json", frame="ground_m",
                 source={"id": "m20_traverse", "name": "Mars 2020 traverse (NASA/JPL MMGIS)", "credit": "NASA/JPL"})]


def _ctx_grid(site, E, S, res, block):
    """Grayscale CTX brightness on the ground axes (NaN where no quad covers it; quads exist for |lat| < 30)."""
    lon = site.lon + np.degrees(E / (3396190.0 * site.cos))
    lat = site.lat - np.degrees(S / 3396190.0)
    out = np.full((len(S), len(E)), np.nan, "f4")
    quads = {ctx_quad_id(lo, la) for lo in (lon[0], lon[-1], site.lon) for la in (lat[0], lat[-1], site.lat)}
    for q in sorted(x for x in quads if x is not None):
        g, _ = sample_axes(ctx_raster(q, res), site, E, S, block, nodata_below=-30000, keep_nan=True)
        out = np.where(np.isnan(out), g, out)
    return out


def _texture(ctx, rid, half_m, out_px, res, block, hirise=False):
    """Grayscale albedo texture for a ring: CTX everywhere it exists, HiRISE 25 cm (matched to CTX) where the site has it."""
    E = np.linspace(-half_m, half_m, out_px)
    base = _ctx_grid(ctx.site, E, E, res, block)
    srcs = []
    if not np.isnan(base).all():
        srcs.append(ctx_source(res))
    if hirise:
        ho = raster("hirise_ortho_25cm")
        step = E[1] - E[0]
        hb = max(1, int(round(step / 0.25)))
        hi = np.full_like(base, np.nan)
        rows = 250
        for r0 in range(0, out_px, rows):
            band, _ = sample_axes(ho, ctx.site, E, E[r0:r0 + rows], hb, nodata_below=0.5, keep_nan=True)
            hi[r0:r0 + rows] = band
        v = ~np.isnan(hi)
        if v.mean() > 0.001:
            srcs.append(dict(id="hirise_ortho_25cm", name=SOURCES["hirise_ortho_25cm"]["name"], credit=SOURCES["hirise_ortho_25cm"]["credit"], url=SOURCES["hirise_ortho_25cm"]["url"]))
            k = 4
            b4, h4 = block_mean(base, k), block_mean(np.where(v, hi, np.nan), k)
            m = ~np.isnan(b4) & ~np.isnan(h4)
            if m.sum() > 100 and h4[m].std() > 0:
                a = b4[m].std() / h4[m].std()
                hi = (hi - h4[m].mean()) * a + b4[m].mean()
            elif np.isnan(base).all():
                pass
            base = np.where(v, hi, base)
    if np.isnan(base).all():
        print("  no CTX/HiRISE brightness available for %s (outside +-30 deg lat?): ring left untextured" % rid)
        return None, []
    lo, hi_ = np.nanpercentile(base, [1, 99])
    t = np.clip((np.nan_to_num(base, nan=float(np.nanmedian(base))) - lo) / max(hi_ - lo, 1e-6), 0, 1)
    name = rid + "_tex.png"
    Image.fromarray((t * 255 + 0.5).astype("u1")).save(ctx.path(name))
    return name, srcs


def _gauss(a, sigma, mode="constant"):
    n = a.shape[0]
    pad = min(n, int(4 * sigma) + 1)
    ap = np.pad(a, pad, mode=mode)
    m = ap.shape[0]
    k = np.fft.fftfreq(m)
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (k[:, None] ** 2 + k[None, :] ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(ap) * g))[pad:pad + n, pad:pad + n]


def _erode(v, r):
    out = v.copy()
    for _ in range(r):
        o = out.copy()
        o[1:] &= out[:-1]; o[:-1] &= out[1:]; o[:, 1:] &= out[:, :-1]; o[:, :-1] &= out[:, 1:]
        out = o
    return out


def _offset_field(v, d):
    """Smooth field d = DTM - global DEM over mask v, extended into the gaps (normalised Gaussian convolution, fine to coarse)."""
    d = np.where(v, d, 0.0)
    out = np.full(v.shape, d[v].mean())
    for sigma in (400, 100, 25, 6):
        w = _gauss(v.astype(float), sigma)
        f = _gauss(d, sigma) / np.maximum(w, 1e-9)
        c = np.clip(w / 0.4, 0, 1)
        out = out * (1 - c) + f * c
    return out


def _fill_with_global(h, g):
    """Merge a gappy DTM with the smoothed global DEM, leaving no steps at the DTM border."""
    g = _gauss(np.nan_to_num(g, nan=float(np.nanmean(g))), 3, mode="edge")
    v = _erode(~np.isnan(h), 2)
    d = np.where(v, np.nan_to_num(h) - g, 0.0)
    off = _offset_field(v, d)
    dev = np.abs(d - _gauss(d, 8) / np.maximum(_gauss(v.astype(float), 8), 1e-9))
    v &= ~(v & (dev > 40))
    off = _offset_field(v, np.where(v, np.nan_to_num(h) - g, 0.0))
    w = np.clip(_gauss(v.astype(float), 3) * 1.6 - 0.3, 0, 1)
    base = g + off
    return w * np.where(np.isnan(h), base, h) + (1 - w) * base, off


def _ring(ctx, rid, title, source, half_m, step_m, block, inner_skip_m, view, tex=None):
    h, bad = sample_ground_grid(raster(source), ctx.site, half_m, step_m, block, keep_nan=True)
    if source == "hrsc_mola_200m":
        h = h + ctx.scene.get("gdem_offset_m", 0.0)
    elif bad:
        g, _ = sample_ground_grid(raster("hrsc_mola_200m"), ctx.site, half_m, step_m, 1, keep_nan=True)
        if bad < 1:
            h, d = _fill_with_global(h, g)
            n = h.shape[0] // 2
            ctx.scene.setdefault("gdem_offset_m", float(d[n, n]))
        else:
            h = g + ctx.scene.get("gdem_offset_m", 0.0)
        print("  %.0f%% of %s outside the DTM, filled from the 200 m global DEM (offset-matched to the DTM)" % (bad * 100, rid))
    h = (np.nan_to_num(h, nan=ctx.scene["center_elevation_m"]) - ctx.scene["center_elevation_m"]).astype("f4")
    h.tofile(ctx.path(rid + ".f32"))
    e = dict(id=rid, title=title, kind="elevation", role="ring", file=rid + ".f32", dtype="f32", samples=h.shape[0],
             step_m=step_m, half_m=half_m, unit="m", relative_to="origin elevation", min=float(h.min()),
             max=float(h.max()), inner_skip_m=inner_skip_m, view=view, source=src(source))
    if tex:
        name, srcs = _texture(ctx, rid, half_m, **tex)
        if name:
            e["texture"], e["texture_sources"] = name, srcs
    return [e]


@layer("ring_3km", requires=("terrain",))
def ring_3km(ctx):
    return _ring(ctx, "ring_3km", "Near field (3 km, 6 m)", "hirise_dtm_1m", 3000, 6, 6, ctx.size_m / 2 - 8.0,
                 dict(subsample=3, lower_m=2.5),
                 tex=dict(out_px=4000, res="6mpp", block=1, hirise=True))


@layer("ring_6km", requires=("terrain",))
def ring_6km(ctx):
    return _ring(ctx, "ring_6km", "Mid field (6 km, 12 m)", "hirise_dtm_1m", 6000, 12, 12, 2990.0,
                 dict(subsample=3, lower_m=3.0),
                 tex=dict(out_px=1000, res="6mpp", block=2))


@layer("ring_80km", requires=("terrain",))
def ring_80km(ctx):
    return _ring(ctx, "ring_80km", "Far field (80 km, 160 m)", "hrsc_mola_200m", 80000, 160, 1, 5990.0,
                 dict(subsample=2, lower_m=6.0),
                 tex=dict(out_px=1001, res="100mpp", block=2))


@layer("slope", requires=("terrain",))
def slope(ctx):
    h = np.fromfile(ctx.path("heightmap.f32"), "f4").reshape(-1, int(round(ctx.size_m)) + 1)
    gy, gx = np.gradient(h, 1.0)
    deg = np.degrees(np.arctan(np.hypot(gx, gy))).astype("f4")
    deg.tofile(ctx.path("slope.f32"))
    return [dict(id="slope", title="Slope", kind="scalar", file="slope.f32", dtype="f32", samples=deg.shape[0],
                 step_m=1.0, half_m=ctx.size_m / 2, unit="deg", min=float(deg.min()), max=float(deg.max()),
                 hazard_deg=15.0, derived_from="terrain")]

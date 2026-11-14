"""Escena "world": ensambla desde los tiles de `world.json` un grid recortado (rectángulo inicio-meta + margen) para el planificador.

Geometría (igual que viewer-godot/world.gd): el mundo es un mosaico en píxeles; el píxel (px, py) global está en
x = (px - origin.px[0])·spacing_x, z = (py - origin.px[1])·spacing_z. El tile (bx, by) cubre `block` píxeles y su archivo
terrain/tN/<bx>_<by>.f32 trae (block/N+1)² muestras (incluye el borde compartido este/sur). El grid del planificador es cuadrado
en METROS (paso 1, 5 o 20 m), así que se interpola bilinealmente en el espacio de píxeles, como `WorldStreamer.height_at`.

Elección de LOD (la más simple): t1 si el recorte tiene <= 250 000 celdas (~500 x 500 m); si no t5 si <= 1 600 000; si no t20 si <= 1 600 000; si no, error.
Datos faltantes (nodata): una celda fuera de los tiles, o en un tile con `nodata_frac` >= 0.5 en world.json (sus alturas fueron rellenadas),
queda intransitable. Con nodata parcial (< 0.5) no se sabe qué celdas son: se usan y se avisa en `warnings`.
"""
import json, math, os
import numpy as np
from PIL import Image

import geo

LODS = [(1, "t1", 501), (5, "t5", 101), (20, "t20", 26)]    # (paso m, carpeta, muestras por lado)
CELLS_T1, CELLS_MAX = 250_000, 1_600_000
NODATA_TILE = 0.5
SNAP_M = 100.0              # el recorte se alinea a múltiplos de 100 m (así se reutiliza al replanificar desde cerca)


class World:
    """world.json + caché perezosa de tiles. Una instancia por carpeta; se reutiliza entre peticiones."""
    def __init__(self, folder):
        self.folder = folder
        self.w = json.load(open(os.path.join(folder, "world.json")))
        self.block = int(self.w["block"])
        self.sx, self.sz = float(self.w["spacing_x"]), float(self.w["spacing_z"])
        self.opx, self.opy = [float(v) for v in self.w["origin"]["px"]]
        self.tiles = {(int(t["bx"]), int(t["by"])): float(t.get("nodata_frac", 0.0)) for t in self.w["tiles"]}
        self.georef = geo.WorldGeo(self.w)
        bxs, bys = [k[0] for k in self.tiles], [k[1] for k in self.tiles]
        # extensión (m) que cubren los tiles
        self.xmin, self.xmax = (min(bxs) * self.block - self.opx) * self.sx, ((max(bxs) + 1) * self.block - self.opx) * self.sx
        self.zmin, self.zmax = (min(bys) * self.block - self.opy) * self.sz, ((max(bys) + 1) * self.block - self.opy) * self.sz
        self._h, self._o, self._route = {}, {}, None

    def tile_at(self, x, z):
        return (int(math.floor((x / self.sx + self.opx) / self.block)), int(math.floor((z / self.sz + self.opy) / self.block)))

    def heights(self, lod_dir, n, k):
        key = (lod_dir, k)
        if key not in self._h:
            self._h[key] = np.fromfile(os.path.join(self.folder, "terrain", lod_dir, "%d_%d.f32" % k), "<f4").reshape(n, n)
        return self._h[key]

    def ortho(self, k, step):
        d = "o100" if step <= 2 else "o400"
        key = (d, k)
        if key not in self._o:
            p = os.path.join(self.folder, "ortho", d, "%d_%d.png" % k)
            self._o[key] = np.asarray(Image.open(p).convert("L")) if os.path.exists(p) else None
        return self._o[key]

    def route_points(self):
        """Huella del rover (route.json) como lista de (x, z), para la preferencia por terreno ya recorrido."""
        if self._route is None:
            p = os.path.join(self.folder, str(self.w.get("route", "route.json")))
            self._route = np.array([pt for s in json.load(open(p))["route"] for pt in s["xz"]], "f8") if os.path.exists(p) else np.zeros((0, 2))
        return self._route


def pick_lod(nx_m, nz_m):
    """(paso, carpeta, muestras) para un recorte de nx_m x nz_m metros, o None si es demasiado grande."""
    for step, d, n in LODS:
        cells = (nx_m / step + 1) * (nz_m / step + 1)
        if cells <= (CELLS_T1 if step == 1 else CELLS_MAX):
            return step, d, n
    return None


def build_crop(world, x_min, x_max, z_min, z_max, step_lod=None):
    """Ensambla el grid (dict compatible con mars_route.derive) para el rectángulo dado, ya alineado a SNAP_M y recortado a los tiles."""
    lod = pick_lod(x_max - x_min, z_max - z_min) if step_lod is None else next(l for l in LODS if l[0] == step_lod)
    if lod is None:
        raise geo.GeoError("recorte de %.1f x %.1f km demasiado grande (maximo %d celdas incluso a 20 m)" % (
            (x_max - x_min) / 1000, (z_max - z_min) / 1000, CELLS_MAX), "fuera_de_capa")
    step, d, n_s = lod
    nx, nz = int(round((x_max - x_min) / step)) + 1, int(round((z_max - z_min) / step)) + 1
    xs, zs = x_min + np.arange(nx) * step, z_min + np.arange(nz) * step
    pxs, pys = xs / world.sx + world.opx, zs / world.sz + world.opy
    bcol, brow = np.floor(pxs / world.block).astype(int), np.floor(pys / world.block).astype(int)
    h = np.full((nz, nx), np.nan)
    img = np.full((nz, nx), np.nan)
    nodata = np.ones((nz, nx), bool)
    partial = []
    st_px = float(step_lod_px(step, d, world))
    for bx in np.unique(bcol):
        cols = np.nonzero(bcol == bx)[0]
        for by in np.unique(brow):
            k = (int(bx), int(by))
            if k not in world.tiles:
                continue
            rows = np.nonzero(brow == by)[0]
            A = world.heights(d, n_s, k)
            fx, fz = pxs[cols] - bx * world.block, pys[rows] - by * world.block
            gx, gz = np.clip(fx / st_px, 0, n_s - 1.001), np.clip(fz / st_px, 0, n_s - 1.001)
            ix, iz = gx.astype(int), gz.astype(int)
            tx, tz = (gx - ix)[None, :], (gz - iz)[:, None]
            a = lambda r, c: A[np.ix_(r, c)]
            hh = (a(iz, ix) * (1 - tx) + a(iz, ix + 1) * tx) * (1 - tz) + (a(iz + 1, ix) * (1 - tx) + a(iz + 1, ix + 1) * tx) * tz
            h[np.ix_(rows, cols)] = hh
            frac = world.tiles[k]
            if frac < NODATA_TILE:
                nodata[np.ix_(rows, cols)] = False
                if frac > 0:
                    partial.append((k, frac))
            O = world.ortho(k, step)
            if O is not None:
                S = O.shape[0]
                oc, orr = np.clip((fx * S / world.block).astype(int), 0, S - 1), np.clip((fz * S / world.block).astype(int), 0, S - 1)
                o = O[np.ix_(orr, oc)].astype("f8") / 255.0
                o[O[np.ix_(orr, oc)] == 0] = np.nan                 # 0 = nodata en el ortho
                img[np.ix_(rows, cols)] = o
    if nodata.all():
        raise geo.GeoError("el recorte no tiene datos de terreno", "fuera_de_capa")
    h = np.where(np.isnan(h) | nodata, np.nanmean(h[~nodata]), h)       # relleno neutro: las celdas nodata se bloquean aparte
    have_img = np.isfinite(img) & ~nodata
    img_out = None
    if have_img.sum() > 0.5 * img.size:
        img = np.where(np.isfinite(img), img, np.median(img[have_img]))
        img_out = img
    g = dict(h=h, n=max(nx, nz), step=float(step), half=max(nx, nz) * step / 2, x0=float(x_min), z0=float(z_min), nodata=nodata,
             img=img_out, route=[], scene=None, georef=world.georef, kind="world", lod=d, partial_nodata=partial)
    g["route"] = []
    rp = world.route_points()
    if len(rp):
        m = (rp[:, 0] >= x_min - 3) & (rp[:, 0] <= x_max + 3) & (rp[:, 1] >= z_min - 3) & (rp[:, 1] <= z_max + 3)
        g["route"] = [rp[m].tolist()] if m.any() else []
    return g


def step_lod_px(step_m, lod_dir, world):
    """Paso de muestreo del LOD en píxeles del mosaico (t1 = 1 px, t5 = 5 px, t20 = 20 px)."""
    return {"t1": 1.0, "t5": 5.0, "t20": 20.0}[lod_dir]


def crop_box(world, pts, margin=None, step_lod=None):
    """Rectángulo mínimo que contiene `pts` [(x, z)...] + margen, alineado a SNAP_M y recortado a los tiles: (x_min, x_max, z_min, z_max, step_lod).

    Valida que cada punto caiga en un tile existente (error fuera_de_capa). margin por defecto: max(100 m, 10 % del tramo, tope 500 m).
    """
    for x, z in pts:
        if world.tile_at(x, z) not in world.tiles:
            raise geo.GeoError("punto fuera de los tiles del world: x=%.0f, z=%.0f (cubren x %.0f..%.0f, z %.0f..%.0f)" % (
                x, z, world.xmin, world.xmax, world.zmin, world.zmax), "fuera_de_capa")
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    span = max(max(xs) - min(xs), max(zs) - min(zs))
    mg = max(100.0, min(0.1 * span, 500.0)) if margin is None else margin
    sn = lambda v, f: f(v / SNAP_M) * SNAP_M
    return (max(sn(min(xs) - mg, math.floor), sn(world.xmin, math.ceil)), min(sn(max(xs) + mg, math.ceil), sn(world.xmax, math.floor)),
            max(sn(min(zs) - mg, math.floor), sn(world.zmin, math.ceil)), min(sn(max(zs) + mg, math.ceil), sn(world.zmax, math.floor)), step_lod)


def crop_for(world, pts, margin=None, step_lod=None):
    """crop_box + build_crop."""
    x0, x1, z0, z1, lod = crop_box(world, pts, margin, step_lod)
    return build_crop(world, x0, x1, z0, z1, lod)

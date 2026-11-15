"""Mars walking route planner (NASA Space Apps 2026 - Martian Map).

Finds the "best" walking route between two points on a scene grid built by marswalk
(heightmap.f32 + ortho.png, x = east, z = south, row 0 = north, heights relative to origin).

"Best" = least *effective time*: the seconds an astronaut in a suit needs to walk the route,
inflated by risk penalties (steep slopes, shadow in cold, poor visibility). One unit (seconds)
makes the cost easy to explain and lets the VR HUD show a real ETA.

Pipeline:
  1. layers   heightmap -> slope, roughness;  ortho -> brightness;  -> terrain class (proxy)
  2. cost     per directed edge a->b: walking time (Tobler, uphill != downhill) x penalties
  3. search   A* on an 8-connected grid with an admissible heuristic
  4. smooth   cost-aware string pulling (keep a shortcut only if it is not more expensive)
  5. export   points every 1 m with height, ETA, slope, terrain class and warnings

Only numpy + Pillow (already in the marswalk venv).
"""
import argparse, heapq, json, logging, math, os, sys, time
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # para importar los módulos hermanos desde cualquier carpeta
import route_config as cfg                  # supuestos (factores, pesos, 15°/25°): un solo lugar
import terrain_classes as tc                # códigos y fuentes de clase de terreno
import geo, waypoints, world_grid

log = logging.getLogger("mars_route")

# Alias de compatibilidad con la versión anterior (los valores viven en route_config.py)
TERRAIN = {k: (tc.NAMES[k], cfg.TERRAIN_SPEED[k]) for k in tc.NAMES}
SOFT_SLOPE, HARD_SLOPE = cfg.SOFT_SLOPE, cfg.HARD_SLOPE
CONDITIONS = cfg.CONDITIONS


# ---------------------------------------------------------------- 1. layers
def load_grid(folder, layer_id="terrain"):
    scene = json.load(open(os.path.join(folder, "scene.json")))
    e = next(l for l in scene["layers"] if l["id"] == layer_id)
    n, step, half = int(e["samples"]), float(e["step_m"]), float(e["half_m"])
    h = np.fromfile(os.path.join(folder, e["file"]), "<f4").reshape(n, n).astype("f8")
    tex = e.get("texture") or ("ortho.png" if layer_id == "terrain" else None)
    img = None
    if tex and os.path.exists(os.path.join(folder, tex)):
        im = Image.open(os.path.join(folder, tex)).convert("L").resize((n, n), Image.BILINEAR)
        img = np.asarray(im, "f8") / 255.0
    route = []
    rf = os.path.join(folder, "route_local.json")
    if os.path.exists(rf):
        route = [s["points"] for s in json.load(open(rf))]
    return dict(h=h, n=n, step=step, half=half, x0=-half, z0=-half, nodata=None, img=img, route=route, scene=scene)   # x0/z0: esquina noroeste (m); nodata: máscara opcional


def derive(g, sun_az=135.0, sun_el=35.0, terrain_source=None):
    h, s = g["h"], g["step"]
    dz_row, dx_col = np.gradient(h, s)            # d/drow (south), d/dcol (east)
    slope = np.degrees(np.arctan(np.hypot(dx_col, dz_row)))
    # roughness: residual of the height after removing the local 3x3 mean, scaled by grid step
    resid = h - tc.box3(h)
    rough = np.sqrt(tc.box3(resid ** 2)) / max(s, 1.0) * 10.0  # ~0 smooth, >1 rough
    # hillshade (self-shadow only): sun azimuth clockwise from north, elevation above horizon
    az, el = math.radians(sun_az), math.radians(sun_el)
    sun = np.array([math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)])  # east, south, up
    nrm = np.stack([-dx_col, -dz_row, np.ones_like(h)])
    nrm /= np.linalg.norm(nrm, axis=0)
    lit = np.clip(np.tensordot(sun, nrm, 1), 0, 1)
    shadow = 1.0 - lit / max(lit.max(), 1e-6)
    g.update(slope=slope, rough=rough, shadow=shadow)
    # clase de terreno: fuente intercambiable (archivo externo o proxy rugosidad + brillo); ver terrain_classes.py
    cls, info = tc.classify(g, terrain_source)
    g.update(cls=cls, terrain_info=info)
    # cells near the rover's driven route
    near = np.zeros_like(h, bool)
    if g["route"]:
        nr, nc = h.shape
        for pts in g["route"]:
            for x, z in pts:
                c, r = int(round((x - g["x0"]) / s)), int(round((z - g["z0"]) / s))
                if not (-3 < r < nr + 3 and -3 < c < nc + 3):
                    continue
                rr = max(1, int(round(2.0 / s)))
                near[max(0, r - rr):r + rr + 1, max(0, c - rr):c + rr + 1] = True
    g["near_route"] = near
    return g


# ---------------------------------------------------------------- 2. cost
def tobler_ms(grade):
    """Tobler's hiking function, m/s. Asymmetric: fastest on a slight downhill (grade -0.05)."""
    return 6.0 * np.exp(-3.5 * np.abs(grade + 0.05)) / 3.6


def build_cost(g, cond, risk=None):
    """Devuelve una COPIA de `g` con los arrays de costo para (condición, peso de riesgo). No modifica `g` (sin estado global).

    penalización = 1 + riesgo·(pendiente + rugosidad + terreno) + sombra      (× bono si va sobre la huella del rover)
    `riesgo` (--riesgo) sube el peso de pendiente, rocas y dunas frente a la distancia pura; 0 = solo tiempo de marcha.
    """
    risk = cfg.DEFAULT_RISK if risk is None else float(risk)
    c = cfg.CONDITIONS[cond]
    lut_v = np.zeros(max(tc.NAMES) + 1)
    lut_r = np.zeros_like(lut_v)
    for k in tc.NAMES:
        lut_v[k], lut_r[k] = cfg.TERRAIN_SPEED[k], cfg.TERRAIN_RISK[k]
    speed_cell = lut_v[g["cls"]] * cfg.SUIT_FACTOR * c["spd"] * c["vis"] ** 0.5
    over = np.clip((g["slope"] - c["soft"]) / (cfg.HARD_SLOPE - c["soft"]), 0, None)
    pen_slope = c["slope"] * over ** 2
    pen_rough = c["rough"] * np.clip(g["rough"] - 0.5, 0, None)
    pen_terr = c["terrain"] * lut_r[g["cls"]]
    pen = 1.0 + risk * (pen_slope + pen_rough + pen_terr) + c["shadow"] * g["shadow"]
    pen = np.where(g["near_route"], pen * c["track"], pen)   # preference only: does not change real speed / ETA
    blocked = g["slope"] >= cfg.HARD_SLOPE
    if g.get("nodata") is not None:
        blocked = blocked | g["nodata"]            # celdas sin datos (fuera de los tiles o rellenadas): intransitables
    cg = dict(g)
    cg.update(speed_cell=speed_cell, pen=pen, blocked=blocked, cond=cond, risk=risk)
    # heuristic needs the cheapest possible cost per metre: fastest speed and smallest penalty (track discount)
    cg["vmax"] = float(tobler_ms(-0.05)) * cfg.SUIT_FACTOR * c["spd"] * c["vis"] ** 0.5 * max(cfg.TERRAIN_SPEED.values()) / c["track"]
    return cg


def edge_cost(g, r0, c0, r1, c1):
    if g["blocked"][r1, c1]:
        return math.inf
    s = g["step"]
    dxy = s * math.hypot(r1 - r0, c1 - c0)
    dh = g["h"][r1, c1] - g["h"][r0, c0]
    grade = dh / dxy
    if math.degrees(math.atan(abs(grade))) >= cfg.HARD_SLOPE:
        return math.inf
    v = float(tobler_ms(grade)) * 0.5 * (g["speed_cell"][r0, c0] + g["speed_cell"][r1, c1])
    return math.hypot(dxy, dh) / v * 0.5 * (g["pen"][r0, c0] + g["pen"][r1, c1])


# ---------------------------------------------------------------- 3. search
NB = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]


def to_rc(g, x, z):
    s = g["step"]
    return int(round((z - g["z0"]) / s)), int(round((x - g["x0"]) / s))


def to_xz(g, r, c):
    return c * g["step"] + g["x0"], r * g["step"] + g["z0"]


def astar(g, start, goal, corridor=None):
    """A* de 8 vecinos. `corridor` (bool nr x nc, opcional): solo se expanden celdas dentro del corredor (planificación jerárquica)."""
    nr, nc = g["h"].shape
    sr, sc = start
    gr, gc = goal
    s, vmax = g["step"], g["vmax"]
    H = lambda r, c: s * math.hypot(r - gr, c - gc) / vmax  # admissible: no edge is faster than vmax
    best = np.full((nr, nc), np.inf)
    prev = -np.ones((nr, nc), "i8")
    best[sr, sc] = 0.0
    pq = [(H(sr, sc), 0.0, sr, sc)]
    expanded = 0
    while pq:
        f, d, r, c = heapq.heappop(pq)
        if d > best[r, c]:
            continue
        expanded += 1
        if (r, c) == (gr, gc):
            break
        for dr, dc in NB:
            rr, cc = r + dr, c + dc
            if 0 <= rr < nr and 0 <= cc < nc and (corridor is None or corridor[rr, cc]):
                nd = d + edge_cost(g, r, c, rr, cc)
                if nd < best[rr, cc]:
                    best[rr, cc] = nd
                    prev[rr, cc] = r * nc + c
                    heapq.heappush(pq, (nd + H(rr, cc), nd, rr, cc))
    if not math.isfinite(best[gr, gc]):
        return None, expanded
    path, k = [], gr * nc + gc
    while k >= 0:
        path.append(divmod(int(k), nc))
        k = prev[path[-1]]
    return path[::-1], expanded


def coarse_corridor(g, start, goal, k=4, width=3):
    """Planificación jerárquica: A* grueso (bloques de k x k celdas) y corredor fino alrededor de esa ruta.

    Devuelve (corredor bool nr x nc, nodos_expandidos) o (None, 0) si el nivel grueso no encuentra ruta (se usa la búsqueda completa).
    La ruta fina queda dentro del corredor (±width celdas gruesas), así que es casi óptima pero explora mucho menos.
    """
    nr, nc = g["h"].shape
    mr, mc = nr // k, nc // k
    if mr < 2 or mc < 2:
        return None, 0
    pool = lambda a: a[:mr * k, :mc * k].reshape(mr, k, mc, k).mean((1, 3))
    cg = dict(g)
    cg.update(h=pool(g["h"]), step=g["step"] * k, x0=g["x0"] + (k - 1) / 2 * g["step"], z0=g["z0"] + (k - 1) / 2 * g["step"],
              speed_cell=pool(g["speed_cell"]), pen=pool(g["pen"]), blocked=pool(g["blocked"].astype(float)) > 0.5)
    sx, sz = to_xz(g, *start)
    gx, gz = to_xz(g, *goal)
    s, t = to_rc(cg, sx, sz), to_rc(cg, gx, gz)
    s = (min(max(s[0], 0), mr - 1), min(max(s[1], 0), mc - 1))
    t = (min(max(t[0], 0), mr - 1), min(max(t[1], 0), mc - 1))
    cg["blocked"][s], cg["blocked"][t] = False, False
    path, exp = astar(cg, s, t)
    if path is None:
        return None, 0
    mask = np.zeros((mr, mc), bool)
    for r, c in path:
        mask[max(0, r - width):r + width + 1, max(0, c - width):c + width + 1] = True
    full = np.zeros((nr, nc), bool)
    full[:mr * k, :mc * k] = np.kron(mask, np.ones((k, k), bool))
    full[start], full[goal] = True, True
    return full, exp


def line_cost(g, a, b, sub=0.5):
    """Cost of walking straight from cell a to cell b, sampled every `sub` cells (nearest cell). Vectorizado con numpy."""
    (r0, c0), (r1, c1) = a, b
    k = max(1, int(math.ceil(math.hypot(r1 - r0, c1 - c0) / sub)))
    t = np.arange(1, k + 1) / k
    rf, cf = r0 + (r1 - r0) * t, c0 + (c1 - c0) * t
    rr, cc = np.rint(rf).astype(int), np.rint(cf).astype(int)
    if g["blocked"][rr, cc].any():
        return math.inf
    pr, pc = np.concatenate(([r0], rf[:-1])), np.concatenate(([c0], cf[:-1]))
    prr, pcc = np.rint(pr).astype(int), np.rint(pc).astype(int)
    s = g["step"]
    dxy = s * np.hypot(rf - pr, cf - pc)
    dh = g["h"][rr, cc] - g["h"][prr, pcc]
    grade = dh / np.maximum(dxy, 1e-6)
    if ((np.degrees(np.arctan(np.abs(grade))) >= cfg.HARD_SLOPE) & (dxy >= s * 0.99)).any():
        return math.inf
    v = tobler_ms(grade) * g["speed_cell"][rr, cc]
    return float((np.hypot(dxy, dh) / v * g["pen"][rr, cc]).sum())


SMOOTH_SPAN = 60   # nodos máximos que puede saltar un atajo (acota el costo en rutas largas; una ruta A* casi nunca tiene rectas mayores)


def smooth(g, path, tol=1.02):
    """String pulling: from each anchor jump to the farthest later node (hasta SMOOTH_SPAN nodos) whose straight line costs <= tol x the grid path."""
    if len(path) < 3:
        return path
    seg = [0.0] + [edge_cost(g, *path[i], *path[i + 1]) for i in range(len(path) - 1)]
    cum = np.cumsum(seg)
    out, i = [path[0]], 0
    while i < len(path) - 1:
        j = min(len(path) - 1, i + SMOOTH_SPAN)
        while j > i + 1 and line_cost(g, path[i], path[j]) > tol * (cum[j] - cum[i]):
            j -= 1
        out.append(path[j])
        i = j
    return out


# ---------------------------------------------------------------- 5. export
def bilinear(g, a, x, z):
    s = g["step"]
    nr, nc = a.shape
    fx = min(max((x - g["x0"]) / s, 0), nc - 1.001)
    fz = min(max((z - g["z0"]) / s, 0), nr - 1.001)
    ix, iz = int(fx), int(fz)
    tx, tz = fx - ix, fz - iz
    return ((a[iz, ix] * (1 - tx) + a[iz, ix + 1] * tx) * (1 - tz) + (a[iz + 1, ix] * (1 - tx) + a[iz + 1, ix + 1] * tx) * tz)


def chaikin(xz, it=2):
    for _ in range(it):
        out = [xz[0]]
        for (x0, z0), (x1, z1) in zip(xz[:-1], xz[1:]):
            out += [(0.75 * x0 + 0.25 * x1, 0.75 * z0 + 0.25 * z1), (0.25 * x0 + 0.75 * x1, 0.25 * z0 + 0.75 * z1)]
        out.append(xz[-1])
        xz = out
    return xz


def export(g, nodes, spacing=1.0):
    xz = chaikin([to_xz(g, r, c) for r, c in nodes])
    pts = []
    for (x0, z0), (x1, z1) in zip(xz[:-1], xz[1:]):
        k = max(1, int(math.ceil(math.hypot(x1 - x0, z1 - z0) / spacing)))
        pts += [(x0 + (x1 - x0) * i / k, z0 + (z1 - z0) * i / k) for i in range(k)]
    pts.append(xz[-1])
    out_pts, eta, slope, terr, warn = [], [0.0], [], [], []
    t = 0.0
    # world: la altura y la pendiente salen de los tiles (mismo LOD que la malla del visor) y no del grid remuestreado en metros,
    # que interpola dos veces (hasta ~0.4 m de error a 5 m) y suaviza las pendientes de la celda gruesa (a 5 m ocultaba pendientes de 25-30°).
    wd = g.get("world")
    px_, pz_ = np.array([p[0] for p in pts]), np.array([p[1] for p in pts])
    y_tile = wd.heights_at(px_, pz_, int(g["step"]) if g["step"] in (1, 5, 20) else 1) if wd is not None else None
    s_fine = wd.slopes_at(px_, pz_, 1) if wd is not None else None
    for i, (x, z) in enumerate(pts):
        y = float(bilinear(g, g["h"], x, z))
        if y_tile is not None and np.isfinite(y_tile[i]):
            y = float(y_tile[i])
        out_pts.append([round(x, 2), round(y, 3), round(z, 2)])
        r, c = to_rc(g, x, z)
        sl = float(g["slope"][r, c])
        if s_fine is not None and np.isfinite(s_fine[i]):
            sl = float(s_fine[i])
        slope.append(round(sl, 1))
        terr.append(int(g["cls"][r, c]))
        if i:
            x0, y0, z0 = out_pts[i - 1]
            dxy = math.hypot(x - x0, z - z0)
            grade = (y - y0) / max(dxy, 1e-6)
            v = float(tobler_ms(grade)) * float(g["speed_cell"][r, c])
            t += math.hypot(dxy, y - y0) / v
            eta.append(round(t, 1))
        if sl >= cfg.SOFT_SLOPE and (not warn or i - warn[-1]["i"] > 5):
            warn.append(dict(i=i, type="pendiente", msg="Pendiente %.0f° - paso corto, 3 puntos de apoyo" % sl))
        if terr[-1] == tc.BLOQUES and (not warn or i - warn[-1]["i"] > 5):
            warn.append(dict(i=i, type="rocoso", msg="Zona de bloques - mirar dónde pisa"))
        if terr[-1] == tc.ARENA_DUNA and (not warn or i - warn[-1]["i"] > 5) and (i == 0 or terr[i - 1] != tc.ARENA_DUNA):
            warn.append(dict(i=i, type="duna", msg="Tramo de duna / arena suelta - avanza despacio, el pie se hunde"))
    ys = [p[1] for p in out_pts]
    dy = np.diff(ys)
    length = sum(math.dist(a, b) for a, b in zip(out_pts[:-1], out_pts[1:]))
    straight = math.dist(out_pts[0], out_pts[-1])
    mix = {tc.NAMES[k]: round(terr.count(k) / len(terr), 2) for k in tc.NAMES if terr.count(k)}
    info = g.get("terrain_info", {})
    res = dict(
        schema=1, kind="guide_path", frame="ground_m (x east, y up, z south; y relative to origin)",
        conditions=g["cond"], risk_weight=g.get("risk"), start=out_pts[0], goal=out_pts[-1],
        summary=dict(length_m=round(length, 1), straight_m=round(straight, 1), detour_pct=round(100 * (length / max(straight, 1e-6) - 1), 1),
                     eta_s=round(t, 1), climb_m=round(float(dy[dy > 0].sum()), 2), descent_m=round(float(-dy[dy < 0].sum()), 2),
                     max_slope_deg=max(slope), terrain_mix=mix, dune_m=round(length * terr.count(tc.ARENA_DUNA) / len(terr), 1)),
        terrain_names={k: v for k, v in tc.NAMES.items()},
        terrain_source=dict(source=info.get("source"), is_proxy=info.get("is_proxy"), warning=info.get("warning")),
        points=out_pts, eta_s=eta, slope_deg=slope, terrain=terr, warnings=warn)
    try:   # lon/lat de cada punto, solo si la escena tiene georreferencia
        ref = geo.georef_of(g)
        res["lonlat"] = [[round(v, 7) for v in ref.local_to_lonlat(p[0], p[2])] for p in out_pts]
    except geo.GeoError:
        pass
    return res


# ---------------------------------------------------------------- preview image
def preview(g, results, out_png, scale=None):
    nr, nc = g["h"].shape
    scale = scale or max(1, 720 // max(nr, nc))
    base = g["img"] if g["img"] is not None else (g["h"] - g["h"].min()) / max(np.ptp(g["h"]), 1e-6)
    rgb = np.stack([base] * 3, -1) * 0.75
    tint = {tc.ROCA_FIRME: (0.15, 0.15, 0.15), tc.REGOLITO: (0, 0, 0), tc.ARENA_DUNA: (0.25, 0.18, 0.0), tc.BLOQUES: (0.25, 0.0, 0.25)}
    for k, t in tint.items():
        rgb[g["cls"] == k] += t
    rgb[g["slope"] >= cfg.SOFT_SLOPE] = rgb[g["slope"] >= cfg.SOFT_SLOPE] * 0.5 + np.array([0.5, 0.25, 0])
    rgb[g["blocked"]] = (0.8, 0.0, 0.0)
    im = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype("u1")).resize((nc * scale, nr * scale), Image.NEAREST)
    _draw_routes(g, im, results, scale)
    im.save(out_png)


def _draw_routes(g, im, results, scale):
    from PIL import ImageDraw
    d = ImageDraw.Draw(im)
    cols = {"normal": (0, 255, 120), "tormenta_polvo": (255, 210, 0), "frio_sombra": (90, 170, 255)}
    px = lambda x, z: ((x - g["x0"]) / g["step"] * scale + scale / 2, (z - g["z0"]) / g["step"] * scale + scale / 2)
    for name, res in results.items():
        pts = [px(p[0], p[2]) for p in res["points"]]
        d.line(pts, fill=cols.get(name, (255, 255, 255)), width=3)
    if results:
        r0 = next(iter(results.values()))
        for p, col in ((r0["start"], (255, 255, 255)), (r0["goal"], (255, 60, 60))):
            x, y = px(p[0], p[2])
            d.ellipse([x - 6, y - 6, x + 6, y + 6], outline=col, width=3)


def preview_classes(g, results, out_png, scale=None):
    """PNG solo con la matriz de clases de terreno (paleta de terrain_classes.COLORS) + leyenda + ruta, para revisar el clasificador."""
    from PIL import ImageDraw
    scale = scale or max(1, 720 // max(g["h"].shape))
    im = tc.class_image(g["cls"], scale).convert("RGB")
    if g.get("nodata") is not None and g["nodata"].any():     # sin datos: gris oscuro (no se confunde con "regolito")
        arr = np.asarray(im).copy()
        arr[np.kron(g["nodata"], np.ones((scale, scale), bool))] = (25, 25, 30)
        im = Image.fromarray(arr)
    _draw_routes(g, im, results, scale)
    leg = Image.new("RGB", (im.width, 22), (20, 20, 24))
    d = ImageDraw.Draw(leg)
    x = 6
    for k, name in tc.NAMES.items():
        d.rectangle([x, 5, x + 12, 17], fill=tc.COLORS[k])
        d.text((x + 17, 5), "%s %.0f%%" % (name, 100 * float((g["cls"] == k).mean())), fill=(230, 230, 230))
        x += 175
    out = Image.new("RGB", (im.width, im.height + 22))
    out.paste(im, (0, 0))
    out.paste(leg, (0, im.height))
    out.save(out_png)


def export_terrain(g, prefix):
    """Escribe <prefix>.u8 (n x n bytes, fila 0 = norte, un byte por clase) y <prefix>.json (metadatos) para el HUD de Godot."""
    info = g.get("terrain_info", {})
    g["cls"].astype("u1").tofile(prefix + ".u8")
    json.dump(dict(n=g["n"], nr=g["h"].shape[0], nc=g["h"].shape[1], x0=g["x0"], z0=g["z0"], step_m=g["step"], half_m=g["half"], source=info.get("source"), is_proxy=info.get("is_proxy"),
                   warning=info.get("warning"), names={str(k): v for k, v in tc.NAMES.items()},
                   short={str(k): v for k, v in tc.SHORT.items()}), open(prefix + ".json", "w"), ensure_ascii=False)
    return prefix + ".u8"


# ---------------------------------------------------------------- API: plan_route (sin estado global)
class PlanError(Exception):
    """Error de planificación con código estable (ver README, 'Integración con el mapa')."""
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


class RouteResult:
    """Resultado de plan_route. `route` es el guide_path (dict) cuando ok; si no, `error` y `error_code`.

    to_json() devuelve el sobre del contrato: {schema, ok, error, error_code, route, warnings, timing_ms}.
    """
    def __init__(self, ok, route=None, error=None, error_code=None, warnings=None, timing=None, cost_grid=None):
        self.ok, self.route, self.error, self.error_code = ok, route, error, error_code
        self.warnings, self.timing, self.cost_grid = warnings or [], timing or {}, cost_grid

    def to_json(self):
        return dict(schema=1, ok=self.ok, error=self.error, error_code=self.error_code, route=self.route,
                    warnings=self.warnings, timing_ms=self.timing)


def load_layers(folder, layer="terrain", sun=(135.0, 35.0), terrain_source=None, waypoints_path=None):
    """Carga y deriva las capas (pendiente, rugosidad, sombra, clase de terreno) UNA vez; reutilizar entre llamadas a plan_route."""
    t0 = time.perf_counter()
    if os.path.exists(os.path.join(folder, "world.json")):      # escena "world" (tiles): el grid se ensambla por petición
        if terrain_source not in (None, "proxy"):
            raise ValueError("terrain_map todavia no esta soportado en world (solo proxy)")
        w = world_grid.World(folder)
        log.info("world: %d tiles, x %.0f..%.0f m, z %.0f..%.0f m", len(w.tiles), w.xmin, w.xmax, w.zmin, w.zmax)
        return dict(kind="world", world=w, georef=w.georef, folder=folder, layer="world", sun=sun, waypoints_path=waypoints_path,
                    cost_cache={}, crops={})
    g = derive(load_grid(folder, layer), sun[0], sun[1], terrain_source)
    g.update(folder=folder, layer=layer, waypoints_path=waypoints_path, cost_cache={})
    info = g["terrain_info"]
    log.info("terreno: fuente=%s (%.0f ms de carga)", info["source"], (time.perf_counter() - t0) * 1000)
    if info.get("warning"):
        log.warning("terreno: %s", info["warning"])
    return g


def _resolve_point(layers, spec, what):
    """spec: (x, z) | {"x","z"} | {"lat","lon"} | {"waypoint": id_o_nombre}  ->  (x, z, avisos)"""
    if isinstance(spec, (tuple, list)) and len(spec) == 2:
        return float(spec[0]), float(spec[1]), []
    if not isinstance(spec, dict):
        raise PlanError("punto_invalido", "%s: se esperaba (x, z) o un objeto con x/z, lat/lon o waypoint" % what)
    try:
        if "waypoint" in spec:
            lat, lon, name = waypoints.resolve(spec["waypoint"], layers.get("waypoints_path"))
            x, z = geo.georef_of(layers).lonlat_to_local(lon, lat)
            return x, z, []
        if "lat" in spec and "lon" in spec:
            lat, lon = float(spec["lat"]), float(spec["lon"])
            if not (-90 <= lat <= 90 and -360 <= lon <= 360):
                raise PlanError("punto_invalido", "%s: lat/lon fuera de rango" % what)
            x, z = geo.georef_of(layers).lonlat_to_local(lon, lat)
            return x, z, []
        if "x" in spec and "z" in spec:
            return float(spec["x"]), float(spec["z"]), []
    except waypoints.WaypointError as e:
        raise PlanError("waypoint_invalido", "%s: %s" % (what, e))
    except geo.GeoError as e:
        raise PlanError(e.code, "%s: %s" % (what, e))
    except (TypeError, ValueError):
        raise PlanError("punto_invalido", "%s: valores no numericos" % what)
    raise PlanError("punto_invalido", "%s: falta x/z, lat/lon o waypoint" % what)


HIER_MIN_CELLS = 200_000    # por encima de esto (el anillo de 3 km tiene 1 000 000) se usa planificación jerárquica en modo "auto"
HIER_FACTOR, HIER_WIDTH = 4, 3


def world_crop(layers, pts, lod=None, margin=None):
    """Capas (recorte ya derivado: pendiente, rugosidad, sombra, clase de terreno) para el rectángulo de `pts` en una escena world.

    Se reutilizan entre peticiones si el rectángulo (alineado a 100 m) y el LOD son los mismos; guarda las 3 últimas.
    """
    w = layers["world"]
    try:
        box = world_grid.crop_box(w, pts, margin, lod)
    except geo.GeoError as e:
        raise PlanError(e.code, str(e))
    if box not in layers["crops"]:
        try:
            g = world_grid.build_crop(w, *box)
        except geo.GeoError as e:
            raise PlanError(e.code, str(e))
        g = derive(g, layers["sun"][0], layers["sun"][1], None)
        g.update(folder=layers["folder"], layer="world:" + g["lod"], waypoints_path=layers.get("waypoints_path"), cost_cache={})
        if len(layers["crops"]) >= 3:
            layers["crops"].pop(next(iter(layers["crops"])))
        layers["crops"][box] = g
        log.info("world: recorte %dx%d celdas de %.0f m (%s), fuente de terreno %s", g["h"].shape[1], g["h"].shape[0], g["step"], g["lod"], g["terrain_info"]["source"])
    return layers["crops"][box]


def plan_route(layers, start, goal, condition="normal", risk_weight=None, hierarchical="auto", snap_m=5.0, lod=None):
    """Planifica una ruta desde `start` a `goal` con capas ya cargadas (`load_layers`). Sin estado global; apta para llamar en cualquier momento.

    start/goal: (x, z) en metros locales, o {"x","z"}, {"lat","lon"}, {"waypoint": id}.
    risk_weight: peso de riesgo (None = cfg.DEFAULT_RISK; 0 = tiempo puro).
    hierarchical: "auto" | "on" | "off". snap_m: radio para mover un punto intransitable a la celda transitable más cercana (0 = estricto).
    lod: solo escenas world: fuerza el paso del terreno (1, 5 o 20 m); None = elegir según el tamaño del recorte.
    Devuelve RouteResult (nunca lanza por errores de usuario: ok=False con error_code).
    """
    t_all = time.perf_counter()
    tm, warns = {}, []
    try:
        if condition not in cfg.CONDITIONS:
            raise PlanError("condicion_invalida", "condicion '%s' desconocida (%s)" % (condition, ", ".join(cfg.CONDITIONS)))
        risk = cfg.DEFAULT_RISK if risk_weight is None else float(risk_weight)
        if risk < 0:
            raise PlanError("riesgo_invalido", "risk_weight debe ser >= 0")
        raw = []
        for what, spec in (("inicio", start), ("meta", goal)):
            x, z, w = _resolve_point(layers, spec, what)
            warns += w
            raw.append((x, z))
        if layers.get("kind") == "world":
            t0 = time.perf_counter()
            layers = world_crop(layers, raw, lod)
            tm["recorte_ms"] = (time.perf_counter() - t0) * 1000
            for k, frac in layers["partial_nodata"]:
                warns.append("el tile %d_%d tiene %.0f %% de alturas rellenadas (nodata parcial)" % (k[0], k[1], 100 * frac))
        t0 = time.perf_counter()
        key = (condition, round(risk, 6))
        cache = layers.setdefault("cost_cache", {})
        if key not in cache:
            if len(cache) >= 6:
                cache.pop(next(iter(cache)))
            cache[key] = build_cost(layers, condition, risk)
        g = cache[key]
        tm["costos_ms"] = (time.perf_counter() - t0) * 1000
        pts = []
        for what, (x, z) in zip(("inicio", "meta"), raw):
            try:
                x, z, aviso = geo.validate_point(g, x, z, snap_m, what)
            except geo.GeoError as e:
                raise PlanError(e.code, str(e))
            if aviso:
                warns.append(aviso)
            pts.append(to_rc(g, x, z))
        s, t = pts
        use_h = hierarchical == "on" or (hierarchical == "auto" and g["h"].size > HIER_MIN_CELLS)
        corridor, hier_exp = None, 0
        if use_h:
            t0 = time.perf_counter()
            corridor, hier_exp = coarse_corridor(g, s, t, HIER_FACTOR, HIER_WIDTH)
            tm["grueso_ms"] = (time.perf_counter() - t0) * 1000
            if corridor is None:
                warns.append("el nivel grueso no hallo ruta; se uso la busqueda completa")
        t0 = time.perf_counter()
        path, expanded = astar(g, s, t, corridor)
        tm["astar_ms"] = (time.perf_counter() - t0) * 1000
        if path is None:
            raise PlanError("sin_ruta", "no hay ruta transitable entre inicio y meta (bloqueada por pendientes >= %.0f°)" % cfg.HARD_SLOPE)
        t0 = time.perf_counter()
        nodes = smooth(g, path)
        tm["suavizado_ms"] = (time.perf_counter() - t0) * 1000
        t0 = time.perf_counter()
        res = export(g, nodes)
        tm["exportar_ms"] = (time.perf_counter() - t0) * 1000
        res["summary"]["grid"] = dict(layer=layers.get("layer"), step_m=g["step"], nodes_expanded=expanded, raw_nodes=len(path),
                                      hierarchical=bool(corridor is not None), coarse_nodes_expanded=hier_exp)
        res["warnings_plan"] = warns
        tm["nodos_expandidos"] = expanded
        tm["jerarquico"] = bool(corridor is not None)
        tm["total_ms"] = (time.perf_counter() - t_all) * 1000
        tm = {k: (round(v, 1) if isinstance(v, float) else v) for k, v in tm.items()}
        return RouteResult(True, res, warnings=warns, timing=tm, cost_grid=g)
    except PlanError as e:
        tm["total_ms"] = round((time.perf_counter() - t_all) * 1000, 1)
        return RouteResult(False, error=str(e), error_code=e.code, warnings=warns, timing=tm)


def run_request(req, layers_cache=None):
    """Contrato JSON (dict -> dict). Ver README, 'Integración con el mapa'. `layers_cache`: dict opcional para reutilizar capas."""
    cache = layers_cache if layers_cache is not None else {}
    try:
        folder, layer = req["scene"], req.get("layer", "terrain")
        ck = (folder, layer, req.get("terrain_map"))
        if ck not in cache:
            cache[ck] = load_layers(folder, layer, tuple(req.get("sun", (135.0, 35.0))), req.get("terrain_map"), req.get("waypoints"))
        res = plan_route(cache[ck], req.get("start", {"x": 0, "z": 0}), req["goal"], req.get("condition", "normal"),
                         req.get("risk_weight"), req.get("hierarchical", "auto"), float(req.get("snap_m", 5.0)), req.get("lod"))
        return res.to_json()
    except (KeyError, FileNotFoundError, ValueError, StopIteration) as e:
        code = "peticion_invalida" if isinstance(e, KeyError) else "escena_invalida"
        return RouteResult(False, error="%s: %s" % (code, e), error_code=code).to_json()


# ---------------------------------------------------------------- CLI
def plan(folder, start, goal, cond="normal", layer="terrain", sun_az=135.0, sun_el=35.0, risk=None, layers=None):
    """Versión compatible con la CLI anterior: (g, res) o SystemExit. Puntos (x, z) estrictos (sin 'snap')."""
    layers = layers or load_layers(folder, layer, (sun_az, sun_el))
    r = plan_route(layers, tuple(start) if not isinstance(start, dict) else start, tuple(goal) if not isinstance(goal, dict) else goal,
                   cond, risk, snap_m=0.0 if not isinstance(goal, dict) else 5.0)
    if not r.ok:
        raise SystemExit(r.error)
    return r.cost_grid, r.route


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("scene", help="scene folder (with scene.json)")
    ap.add_argument("--start", type=float, nargs=2, default=None, metavar=("X", "Z"), help="metres, x east z south")
    ap.add_argument("--start-latlon", type=float, nargs=2, default=None, metavar=("LAT", "LON"))
    ap.add_argument("--goal", type=float, nargs=2, default=None, metavar=("X", "Z"))
    ap.add_argument("--goal-latlon", type=float, nargs=2, default=None, metavar=("LAT", "LON"), help="destino en grados decimales")
    ap.add_argument("--waypoint", default=None, help="destino = punto guardado (id o nombre, ver waypoints.py)")
    ap.add_argument("--waypoints", default=None, help="archivo de puntos guardados (default viewer-godot/route/waypoints.json)")
    ap.add_argument("--cond", default="normal", choices=list(cfg.CONDITIONS) + ["all"])
    ap.add_argument("--riesgo", type=float, default=None, help="peso de riesgo (default %.1f): 0 = solo tiempo; mayor = evita más dunas/rocas/pendiente" % cfg.DEFAULT_RISK)
    ap.add_argument("--terrain-map", default=None, help="mapa de clases externo (.npy/.png/.f32/.u8); sin él se usa el proxy")
    ap.add_argument("--config", default=None, help="JSON que sobrescribe los supuestos de route_config.py")
    ap.add_argument("--hier", default="auto", choices=["auto", "on", "off"], help="planificación jerárquica (auto: capas > %d celdas)" % HIER_MIN_CELLS)
    ap.add_argument("--layer", default="terrain", help="terrain (1 m patch) or ring_3km (6 m, long routes)")
    ap.add_argument("--sun", type=float, nargs=2, default=(135.0, 35.0), metavar=("AZ", "EL"))
    ap.add_argument("--out", default=None, help="output json (default <scene>/guide_path.json)")
    ap.add_argument("--png", default=None, help="preview image")
    ap.add_argument("--png-clases", default=None, help="imagen solo con la matriz de clases de terreno (+ ruta) para revisar el clasificador")
    ap.add_argument("--export-terrain", default=None, metavar="PREFIJO", help="escribe PREFIJO.u8/.json con la matriz de clases (para el HUD de Godot)")
    ap.add_argument("--lod", type=int, default=None, choices=[1, 5, 20], help="solo world: fuerza el paso del terreno en m (default: segun el tamano del recorte)")
    ap.add_argument("--around", type=float, nargs=2, default=None, metavar=("X", "Z"), help="solo world, con --export-terrain: centro de la ventana")
    ap.add_argument("--radius", type=float, default=200.0, help="solo world, con --export-terrain: radio de la ventana en m (default 200)")
    ap.add_argument("--request", default=None, help="modo contrato: JSON de petición (ver README); escribe --result")
    ap.add_argument("--result", default=None, help="con --request: archivo de salida (default stdout)")
    a = ap.parse_args()
    if a.config:
        cfg.apply_overrides(a.config)
    if a.request:   # modo contrato: la escena viene en la petición; aquí `scene` se usa solo si falta
        req = json.load(open(a.request))
        req.setdefault("scene", a.scene)
        out = run_request(req)
        (open(a.result, "w") if a.result else sys.stdout).write(json.dumps(out, ensure_ascii=False))
        sys.exit(0 if out["ok"] else 2)

    layers = load_layers(a.scene, a.layer, tuple(a.sun), a.terrain_map, a.waypoints)
    if a.export_terrain:
        if layers.get("kind") == "world":      # el HUD de terreno usa una ventana t1 alrededor del jugador
            if not a.around:
                ap.error("en world, --export-terrain necesita --around X Z")
            try:
                layers = world_crop(layers, [tuple(a.around)], 1, a.radius)
            except PlanError as e:
                raise SystemExit("error [%s]: %s" % (e.code, e))
        print("->", export_terrain(layers, a.export_terrain))
        if not (a.goal or a.goal_latlon or a.waypoint):
            return
    spec = lambda xz, ll: ({"lat": ll[0], "lon": ll[1]} if ll else tuple(xz))
    if sum(bool(v) for v in (a.goal, a.goal_latlon, a.waypoint)) != 1:
        ap.error("indica exactamente un destino: --goal X Z, --goal-latlon LAT LON o --waypoint ID")
    start = spec(a.start or (0.0, 0.0), a.start_latlon)
    goal = {"waypoint": a.waypoint} if a.waypoint else spec(a.goal, a.goal_latlon)
    strict = 0.0 if isinstance(goal, tuple) and isinstance(start, tuple) else 5.0
    conds = list(cfg.CONDITIONS) if a.cond == "all" else [a.cond]
    results, g = {}, None
    for c in conds:
        r = plan_route(layers, start, goal, c, a.riesgo, a.hier, strict, a.lod)
        if not r.ok:
            raise SystemExit("error [%s]: %s" % (r.error_code, r.error))
        for w in r.warnings:
            log.warning("aviso: %s", w)
        results[c], g = r.route, r.cost_grid
        sm = r.route["summary"]
        print("%-15s %6.1f m (recta %.1f, +%.0f%%)  ETA %5.0f s  sube %.1f m  pend.max %.0f°  duna %.0f m  %s" % (
            c, sm["length_m"], sm["straight_m"], sm["detour_pct"], sm["eta_s"], sm["climb_m"], sm["max_slope_deg"], sm["dune_m"], sm["terrain_mix"]))
        print("                tiempo de planificacion: %.0f ms (A* %.0f ms%s, %d nodos)" % (
            r.timing["total_ms"], r.timing["astar_ms"], ", grueso %.0f ms" % r.timing["grueso_ms"] if "grueso_ms" in r.timing else "", r.timing["nodos_expandidos"]))
    out = a.out or os.path.join(a.scene, "guide_path.json")
    json.dump(results[conds[0]] if len(conds) == 1 else results, open(out, "w"), ensure_ascii=False)
    print("->", out)
    if a.png:
        preview(g, results, a.png)
        print("->", a.png)
    if a.png_clases:
        preview_classes(g, results, a.png_clases)
        print("->", a.png_clases)


if __name__ == "__main__":
    main()

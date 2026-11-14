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
import argparse, heapq, json, math, os
import numpy as np
from PIL import Image

# ---------------------------------------------------------------- assumptions (tune these)
TERRAIN = {  # id: (name, speed factor). Speed factor multiplies walking speed.
    0: ("roca firme", 1.00),
    1: ("regolito", 0.90),
    2: ("arena / ondulas", 0.60),
    3: ("bloques / rocoso", 0.50),
}
SUIT_FACTOR = 0.55      # EVA suit vs. Earth hiker (Apollo-era walking was ~0.5-1 m/s)
SOFT_SLOPE = 15.0       # deg: penalties start (same as the viewer HAZARD_DEG)
HARD_SLOPE = 25.0       # deg: impassable on foot

CONDITIONS = {
    # vis: visibility (0-1)   spd: speed factor   soft: slope (deg) where penalties start
    # shadow/rough/slope: penalty weights          track: speed bonus on the rover's scouted route
    "normal":         dict(vis=1.00, spd=1.00, soft=15.0, shadow=0.0, rough=0.5, slope=2.0, track=0.85),
    "tormenta_polvo": dict(vis=0.55, spd=0.85, soft=8.0,  shadow=0.0, rough=2.5, slope=4.0, track=0.55),
    "frio_sombra":    dict(vis=0.90, spd=0.90, soft=15.0, shadow=1.5, rough=0.5, slope=2.0, track=0.85),
}


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
    return dict(h=h, n=n, step=step, half=half, img=img, route=route, scene=scene)


def box3(a):
    p = np.pad(a, 1, mode="edge")
    return sum(p[1 + di:1 + di + a.shape[0], 1 + dj:1 + dj + a.shape[1]] for di in (-1, 0, 1) for dj in (-1, 0, 1)) / 9.0


def derive(g, sun_az=135.0, sun_el=35.0):
    h, s = g["h"], g["step"]
    dz_row, dx_col = np.gradient(h, s)            # d/drow (south), d/dcol (east)
    slope = np.degrees(np.arctan(np.hypot(dx_col, dz_row)))
    # roughness: residual of the height after removing the local 3x3 mean, scaled by grid step
    resid = h - box3(h)
    rough = np.sqrt(box3(resid ** 2)) / max(s, 1.0) * 10.0  # ~0 smooth, >1 rough
    # hillshade (self-shadow only): sun azimuth clockwise from north, elevation above horizon
    az, el = math.radians(sun_az), math.radians(sun_el)
    sun = np.array([math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)])  # east, south, up
    nrm = np.stack([-dx_col, -dz_row, np.ones_like(h)])
    nrm /= np.linalg.norm(nrm, axis=0)
    lit = np.clip(np.tensordot(sun, nrm, 1), 0, 1)
    shadow = 1.0 - lit / max(lit.max(), 1e-6)
    # terrain class proxy from DEM roughness + orbital brightness (no geologic map in the scene yet)
    cls = np.ones_like(h, "i4")                         # regolito
    if g["img"] is not None:
        b = g["img"]
        lo, hi = np.percentile(b, [20, 75])
        cls[(b > hi) & (rough < 0.6)] = 0               # bright and smooth -> exposed bedrock
        cls[(b < lo) & (rough < 0.8)] = 2               # dark and smooth -> sand / ripples
    cls[rough > 0.35] = 3                               # rough (>3.5 cm RMS per m) -> blocky
    g.update(slope=slope, rough=rough, shadow=shadow, cls=cls)
    # cells near the rover's driven route
    near = np.zeros_like(h, bool)
    if g["route"]:
        n, half = g["n"], g["half"]
        for pts in g["route"]:
            for x, z in pts:
                c, r = int(round((x + half) / s)), int(round((z + half) / s))
                rr = max(1, int(round(2.0 / s)))
                near[max(0, r - rr):r + rr + 1, max(0, c - rr):c + rr + 1] = True
    g["near_route"] = near
    return g


# ---------------------------------------------------------------- 2. cost
def tobler_ms(grade):
    """Tobler's hiking function, m/s. Asymmetric: fastest on a slight downhill (grade -0.05)."""
    return 6.0 * np.exp(-3.5 * np.abs(grade + 0.05)) / 3.6


def build_cost(g, cond):
    c = CONDITIONS[cond]
    speed_cell = np.vectorize(lambda k: TERRAIN[k][1])(g["cls"]) * SUIT_FACTOR * c["spd"] * c["vis"] ** 0.5
    over = np.clip((g["slope"] - c["soft"]) / (HARD_SLOPE - c["soft"]), 0, None)
    pen = 1.0 + c["slope"] * over ** 2 + c["rough"] * np.clip(g["rough"] - 0.5, 0, None) + c["shadow"] * g["shadow"]
    pen = np.where(g["near_route"], pen * c["track"], pen)   # preference only: does not change real speed / ETA
    blocked = g["slope"] >= HARD_SLOPE
    g.update(speed_cell=speed_cell, pen=pen, blocked=blocked, cond=cond)
    # heuristic needs the cheapest possible cost per metre: fastest speed and smallest penalty (track discount)
    vmax = float(tobler_ms(-0.05)) * SUIT_FACTOR * c["spd"] * c["vis"] ** 0.5 * max(f for _, f in TERRAIN.values()) / c["track"]
    g["vmax"] = vmax
    return g


def edge_cost(g, r0, c0, r1, c1):
    if g["blocked"][r1, c1]:
        return math.inf
    s = g["step"]
    dxy = s * math.hypot(r1 - r0, c1 - c0)
    dh = g["h"][r1, c1] - g["h"][r0, c0]
    grade = dh / dxy
    if math.degrees(math.atan(abs(grade))) >= HARD_SLOPE:
        return math.inf
    v = float(tobler_ms(grade)) * 0.5 * (g["speed_cell"][r0, c0] + g["speed_cell"][r1, c1])
    return math.hypot(dxy, dh) / v * 0.5 * (g["pen"][r0, c0] + g["pen"][r1, c1])


# ---------------------------------------------------------------- 3. search
NB = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]


def to_rc(g, x, z):
    s, half = g["step"], g["half"]
    return int(round((z + half) / s)), int(round((x + half) / s))


def to_xz(g, r, c):
    return c * g["step"] - g["half"], r * g["step"] - g["half"]


def astar(g, start, goal):
    n = g["n"]
    sr, sc = start
    gr, gc = goal
    s, vmax = g["step"], g["vmax"]
    H = lambda r, c: s * math.hypot(r - gr, c - gc) / vmax  # admissible: no edge is faster than vmax
    best = np.full((n, n), np.inf)
    prev = -np.ones((n, n), "i8")
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
            if 0 <= rr < n and 0 <= cc < n:
                nd = d + edge_cost(g, r, c, rr, cc)
                if nd < best[rr, cc]:
                    best[rr, cc] = nd
                    prev[rr, cc] = r * n + c
                    heapq.heappush(pq, (nd + H(rr, cc), nd, rr, cc))
    if not math.isfinite(best[gr, gc]):
        return None, expanded
    path, k = [], gr * n + gc
    while k >= 0:
        path.append(divmod(int(k), n))
        k = prev[path[-1]]
    return path[::-1], expanded


# ---------------------------------------------------------------- 4. smooth
def line_cost(g, a, b, sub=0.5):
    """Cost of walking straight from cell a to cell b, sampled every `sub` cells (bilinear-free, nearest cell)."""
    (r0, c0), (r1, c1) = a, b
    k = max(1, int(math.ceil(math.hypot(r1 - r0, c1 - c0) / sub)))
    tot, pr, pc = 0.0, r0, c0
    for i in range(1, k + 1):
        t = i / k
        rf, cf = r0 + (r1 - r0) * t, c0 + (c1 - c0) * t
        rr, cc = int(round(rf)), int(round(cf))
        if g["blocked"][rr, cc]:
            return math.inf
        s = g["step"]
        dxy = s * math.hypot(rf - pr, cf - pc)
        dh = g["h"][rr, cc] - g["h"][int(round(pr)), int(round(pc))]
        grade = dh / max(dxy, 1e-6)
        if math.degrees(math.atan(abs(grade))) >= HARD_SLOPE and dxy >= s * 0.99:
            return math.inf
        v = float(tobler_ms(grade)) * g["speed_cell"][rr, cc]
        tot += math.hypot(dxy, dh) / v * g["pen"][rr, cc]
        pr, pc = rf, cf
    return tot


def smooth(g, path, tol=1.02):
    """String pulling: from each anchor jump to the farthest later node whose straight line costs <= tol x the grid path."""
    if len(path) < 3:
        return path
    seg = [0.0] + [edge_cost(g, *path[i], *path[i + 1]) for i in range(len(path) - 1)]
    cum = np.cumsum(seg)
    out, i = [path[0]], 0
    while i < len(path) - 1:
        j = len(path) - 1
        while j > i + 1 and line_cost(g, path[i], path[j]) > tol * (cum[j] - cum[i]):
            j -= 1
        out.append(path[j])
        i = j
    return out


# ---------------------------------------------------------------- 5. export
def bilinear(g, a, x, z):
    s, half, n = g["step"], g["half"], g["n"]
    fx = min(max((x + half) / s, 0), n - 1.001)
    fz = min(max((z + half) / s, 0), n - 1.001)
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
    for i, (x, z) in enumerate(pts):
        y = float(bilinear(g, g["h"], x, z))
        out_pts.append([round(x, 2), round(y, 3), round(z, 2)])
        r, c = to_rc(g, x, z)
        sl = float(g["slope"][r, c])
        slope.append(round(sl, 1))
        terr.append(int(g["cls"][r, c]))
        if i:
            x0, y0, z0 = out_pts[i - 1]
            dxy = math.hypot(x - x0, z - z0)
            grade = (y - y0) / max(dxy, 1e-6)
            v = float(tobler_ms(grade)) * float(g["speed_cell"][r, c])
            t += math.hypot(dxy, y - y0) / v
            eta.append(round(t, 1))
        if sl >= SOFT_SLOPE and (not warn or i - warn[-1]["i"] > 5):
            warn.append(dict(i=i, type="pendiente", msg="Pendiente %.0f° - paso corto, 3 puntos de apoyo" % sl))
        if g["cls"][r, c] == 3 and (not warn or i - warn[-1]["i"] > 5):
            warn.append(dict(i=i, type="rocoso", msg="Zona de bloques - mirar dónde pisa"))
    ys = [p[1] for p in out_pts]
    dy = np.diff(ys)
    length = sum(math.dist(a, b) for a, b in zip(out_pts[:-1], out_pts[1:]))
    straight = math.dist(out_pts[0], out_pts[-1])
    mix = {TERRAIN[k][0]: round(terr.count(k) / len(terr), 2) for k in TERRAIN if terr.count(k)}
    return dict(
        schema=1, kind="guide_path", frame="ground_m (x east, y up, z south; y relative to origin)",
        conditions=g["cond"], start=out_pts[0], goal=out_pts[-1],
        summary=dict(length_m=round(length, 1), straight_m=round(straight, 1), detour_pct=round(100 * (length / max(straight, 1e-6) - 1), 1),
                     eta_s=round(t, 1), climb_m=round(float(dy[dy > 0].sum()), 2), descent_m=round(float(-dy[dy < 0].sum()), 2),
                     max_slope_deg=max(slope), terrain_mix=mix),
        terrain_names={k: v[0] for k, v in TERRAIN.items()},
        points=out_pts, eta_s=eta, slope_deg=slope, terrain=terr, warnings=warn)


# ---------------------------------------------------------------- preview image
def preview(g, results, out_png, scale=None):
    n = g["n"]
    scale = scale or max(1, 720 // n)
    base = g["img"] if g["img"] is not None else (g["h"] - g["h"].min()) / max(np.ptp(g["h"]), 1e-6)
    rgb = np.stack([base] * 3, -1) * 0.75
    tint = {0: (0.15, 0.15, 0.15), 1: (0, 0, 0), 2: (0.25, 0.18, 0.0), 3: (0.25, 0.0, 0.25)}
    for k, t in tint.items():
        rgb[g["cls"] == k] += t
    rgb[g["slope"] >= SOFT_SLOPE] = rgb[g["slope"] >= SOFT_SLOPE] * 0.5 + np.array([0.5, 0.25, 0])
    rgb[g["blocked"]] = (0.8, 0.0, 0.0)
    im = Image.fromarray((np.clip(rgb, 0, 1) * 255).astype("u1")).resize((n * scale, n * scale), Image.NEAREST)
    from PIL import ImageDraw
    d = ImageDraw.Draw(im)
    cols = {"normal": (0, 255, 120), "tormenta_polvo": (255, 210, 0), "frio_sombra": (90, 170, 255)}
    px = lambda x, z: ((x + g["half"]) / g["step"] * scale + scale / 2, (z + g["half"]) / g["step"] * scale + scale / 2)
    for name, res in results.items():
        pts = [px(p[0], p[2]) for p in res["points"]]
        d.line(pts, fill=cols.get(name, (255, 255, 255)), width=3)
    if results:
        r0 = next(iter(results.values()))
        for p, col in ((r0["start"], (255, 255, 255)), (r0["goal"], (255, 60, 60))):
            x, y = px(p[0], p[2])
            d.ellipse([x - 6, y - 6, x + 6, y + 6], outline=col, width=3)
    im.save(out_png)


# ---------------------------------------------------------------- CLI
def plan(folder, start, goal, cond="normal", layer="terrain", sun_az=135.0, sun_el=35.0):
    g = derive(load_grid(folder, layer), sun_az, sun_el)
    build_cost(g, cond)
    s, t = to_rc(g, *start), to_rc(g, *goal)
    for name, (r, c) in (("start", s), ("goal", t)):
        if not (0 <= r < g["n"] and 0 <= c < g["n"]):
            raise SystemExit("%s outside the grid (half = %.0f m)" % (name, g["half"]))
        if g["blocked"][r, c]:
            raise SystemExit("%s is on a slope >= %.0f deg" % (name, HARD_SLOPE))
    path, expanded = astar(g, s, t)
    if path is None:
        raise SystemExit("no walkable route (everything blocked by slopes >= %.0f deg)" % HARD_SLOPE)
    res = export(g, smooth(g, path))
    res["summary"]["grid"] = dict(layer=layer, step_m=g["step"], nodes_expanded=expanded, raw_nodes=len(path))
    return g, res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("scene", help="scene folder (with scene.json)")
    ap.add_argument("--start", type=float, nargs=2, default=None, metavar=("X", "Z"), help="metres, x east z south")
    ap.add_argument("--goal", type=float, nargs=2, required=True, metavar=("X", "Z"))
    ap.add_argument("--cond", default="normal", choices=list(CONDITIONS) + ["all"])
    ap.add_argument("--layer", default="terrain", help="terrain (1 m patch) or ring_3km (6 m, long routes)")
    ap.add_argument("--sun", type=float, nargs=2, default=(135.0, 35.0), metavar=("AZ", "EL"))
    ap.add_argument("--out", default=None, help="output json (default <scene>/guide_path.json)")
    ap.add_argument("--png", default=None, help="preview image")
    a = ap.parse_args()
    start = tuple(a.start) if a.start else (0.0, 0.0)
    conds = list(CONDITIONS) if a.cond == "all" else [a.cond]
    results = {}
    for c in conds:
        g, res = plan(a.scene, start, tuple(a.goal), c, a.layer, *a.sun)
        results[c] = res
        sm = res["summary"]
        print("%-15s %6.1f m (recta %.1f, +%.0f%%)  ETA %5.0f s  sube %.1f m  pend.max %.0f°  %s" % (
            c, sm["length_m"], sm["straight_m"], sm["detour_pct"], sm["eta_s"], sm["climb_m"], sm["max_slope_deg"], sm["terrain_mix"]))
    out = a.out or os.path.join(a.scene, "guide_path.json")
    json.dump(results[conds[0]] if len(conds) == 1 else results, open(out, "w"), ensure_ascii=False)
    print("->", out)
    if a.png:
        preview(g, results, a.png)
        print("->", a.png)


if __name__ == "__main__":
    main()

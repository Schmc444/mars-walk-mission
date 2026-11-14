import json, os, sys
import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "route-planner"))


def make_scene(folder, n=61, step=1.0, h=None, origin=True, cls=None):
    """Escena sintética mínima (scene.json + heightmap.f32 [+ clases .npy]) para probar sin datos reales."""
    os.makedirs(folder, exist_ok=True)
    h = np.zeros((n, n), "<f4") if h is None else h.astype("<f4")
    h.tofile(os.path.join(folder, "heightmap.f32"))
    scene = {"layers": [{"id": "terrain", "file": "heightmap.f32", "samples": n, "step_m": step, "half_m": (n - 1) / 2 * step}]}
    if origin:
        scene["origin"] = {"lon": 77.36867979, "lat": 18.48255996}
    json.dump(scene, open(os.path.join(folder, "scene.json"), "w"))
    if cls is not None:
        np.save(os.path.join(folder, "clases.npy"), cls)
    return str(folder)


@pytest.fixture
def scene_factory(tmp_path):
    def f(**kw):
        return make_scene(tmp_path / "escena", **kw)
    return f


def make_world(folder, block=100, tiles=((0, 0), (1, 0), (0, 1), (1, 1)), sx=0.9, nodata=None, plane=(0.01, 0.02), blocked_tiles=()):
    """World sintético mínimo (world.json + terrain/t1,t5,t20 + ortho + route.json). La altura es un plano en PÍXELES del mosaico:
    h = a·px + b·py, así que cualquier celda del recorte debe valer exactamente a·(x/sx + opx) + b·(z/sz + opy)."""
    opx, opy = 37.0, 21.0
    nodata = nodata or {}
    w = {"schema": 1, "kind": "tiled_world", "body": {"radius_m": 3396190.0}, "block": block, "spacing_x": sx, "spacing_z": 1.0,
         "origin": {"lon": 77.45, "lat": 18.44, "px": [opx, opy], "mosaic_x0": 4577366.0, "mosaic_y0": 1106618.0, "lat0": 18.4666},
         "tiles": [{"bx": bx, "by": by, "nodata_frac": nodata.get((bx, by), 0.0)} for bx, by in tiles], "route": "route.json"}
    os.makedirs(folder, exist_ok=True)
    json.dump(w, open(os.path.join(folder, "world.json"), "w"))
    json.dump({"route": [{"sol": 1, "xz": [[0.0, 0.0], [10.0, 5.0]]}]}, open(os.path.join(folder, "route.json"), "w"))
    from PIL import Image
    a, b = plane
    for lod, step in (("t1", 1), ("t5", 5), ("t20", 20)):
        os.makedirs(os.path.join(folder, "terrain", lod), exist_ok=True)
        n = block // step + 1
        for bx, by in tiles:
            px = bx * block + np.arange(n) * step
            py = by * block + np.arange(n) * step
            (a * px[None, :] + b * py[:, None]).astype("<f4").tofile(os.path.join(folder, "terrain", lod, "%d_%d.f32" % (bx, by)))
    for lod, size in (("o100", block), ("o400", max(block // 4, 2))):
        os.makedirs(os.path.join(folder, "ortho", lod), exist_ok=True)
        for bx, by in tiles:
            Image.fromarray(np.full((size, size), 128, "u1")).save(os.path.join(folder, "ortho", lod, "%d_%d.png" % (bx, by)))
    return str(folder), w


def world_xz(w, px, py):
    """Píxel global del mosaico -> metros del frame world."""
    return (px - w["origin"]["px"][0]) * w["spacing_x"], (py - w["origin"]["px"][1]) * w["spacing_z"]

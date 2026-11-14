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

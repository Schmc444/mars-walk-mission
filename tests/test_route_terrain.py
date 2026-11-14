import numpy as np, pytest
import terrain_classes as tc
import mars_route as m


def _g(n=40, img=None, rough=None):
    return dict(h=np.zeros((n, n)), n=n, img=img, rough=np.zeros((n, n)) if rough is None else rough)


def test_proxy_franja_oscura_es_duna():
    n = 40
    rng = np.random.default_rng(1)
    img = 0.5 + rng.normal(0, 0.005, (n, n))
    img[:, 17:23] = 0.1                                  # franja oscura y lisa (15 % de la capa)
    cls, info = tc.classify(_g(n, img))
    assert info["is_proxy"] and "PROXY" in info["warning"]
    assert (cls[:, 18:22] == tc.ARENA_DUNA).all()        # el centro de la franja es duna
    assert (cls[:, :12] != tc.ARENA_DUNA).all() and (cls[:, 28:] != tc.ARENA_DUNA).all()


def test_proxy_rugoso_es_bloques():
    n = 30
    rough = np.zeros((n, n)); rough[10:20, 10:20] = 1.0
    cls, _ = tc.classify(_g(n, None, rough))
    assert (cls[12:18, 12:18] == tc.BLOQUES).all() and cls[0, 0] == tc.REGOLITO


def test_fuente_archivo_npy_png_y_remuestreo(tmp_path):
    n = 40
    a = np.zeros((20, 20), "u1"); a[:, 8:12] = tc.ARENA_DUNA
    np.save(tmp_path / "c.npy", a)
    cls, info = tc.classify(_g(n), tmp_path / "c.npy")   # 20x20 -> 40x40 por vecino más cercano
    assert cls.shape == (n, n) and not info["is_proxy"] and info["warning"] is None
    assert (cls[:, 16:24] == tc.ARENA_DUNA).all() and (cls[:, :16] == tc.ROCA_FIRME).all()
    from PIL import Image
    Image.fromarray(np.kron(a, np.ones((2, 2), "u1"))).save(tmp_path / "c.png")
    cls2, _ = tc.classify(_g(n), tmp_path / "c.png")
    assert (cls2 == cls).all()


def test_fuente_archivo_codigos_externos_y_errores(tmp_path):
    a = np.full((10, 10), 7, "u1"); a[:, :5] = 9
    np.save(tmp_path / "x.npy", a)
    with pytest.raises(ValueError, match="fuera de"):
        tc.classify(_g(10), tmp_path / "x.npy")
    import json
    json.dump({"codes": {"7": tc.REGOLITO, "9": tc.ARENA_DUNA}}, open(str(tmp_path / "x.npy") + ".json", "w"))
    cls, _ = tc.classify(_g(10), tmp_path / "x.npy")
    assert (cls[:, :5] == tc.ARENA_DUNA).all() and (cls[:, 5:] == tc.REGOLITO).all()
    with pytest.raises(ValueError, match="no soportado"):
        tc.classify(_g(10), tmp_path / "x.tif")


def _franja(n, z_fin):
    """Matriz de clases: franja de duna (columnas 28-35) desde el norte hasta la fila z_fin (None = todo el alto)."""
    cls = np.full((n, n), tc.ROCA_FIRME, "u1")
    cls[:z_fin, 28:36] = tc.ARENA_DUNA
    return cls


def test_ruta_evita_la_duna_si_hay_desvio(scene_factory):
    n = 61
    folder = scene_factory(n=n, cls=_franja(n, 45))      # hueco al sur: filas 45+ (z >= 15)
    L = m.load_layers(folder, terrain_source=folder + "/clases.npy")
    r = m.plan_route(L, (-25, 0), (25, 0), risk_weight=1.0)
    assert r.ok and r.route["summary"]["detour_pct"] > 10          # dio el rodeo por el hueco
    # el suavizado (Chaikin) puede rozar la esquina de la franja (~3 m); cruzarla entera serían 8 m
    assert r.route["summary"]["dune_m"] <= 4
    assert max(abs(p[0] + 1) for p, t in zip(r.route["points"], r.route["terrain"]) if t == tc.ARENA_DUNA) < 6
    r0 = m.plan_route(L, (-25, 0), (25, 0), risk_weight=0.0)   # sin peso de riesgo, cruza la franja y sale más corta
    assert r0.route["summary"]["dune_m"] >= 8 and r0.route["summary"]["length_m"] < r.route["summary"]["length_m"]


def test_ruta_cruza_la_duna_si_no_hay_alternativa(scene_factory):
    n = 61
    folder = scene_factory(n=n, cls=_franja(n, None))
    L = m.load_layers(folder, terrain_source=folder + "/clases.npy")
    r = m.plan_route(L, (-25, 0), (25, 0), risk_weight=1.0)
    assert r.ok and r.route["summary"]["dune_m"] >= 6
    assert r.route["terrain_source"]["is_proxy"] is False
    assert any(w["type"] == "duna" for w in r.route["warnings"])


def test_replanificacion_desde_otra_posicion_reutiliza_capas(scene_factory):
    folder = scene_factory(n=61)
    L = m.load_layers(folder)
    a = m.plan_route(L, (-25, 0), (25, 0))
    b = m.plan_route(L, (0, -20), (25, 0))               # nueva posición actual, mismo destino
    assert a.ok and b.ok and a.route["start"][:3:2] != b.route["start"][:3:2]
    assert b.route["start"][0] == 0 and b.route["goal"][0] == 25
    assert len(L["cost_cache"]) == 1                      # los costos se calcularon una sola vez
    m.plan_route(L, (0, -20), (25, 0), risk_weight=2.0)
    assert len(L["cost_cache"]) == 2
    assert b.timing["total_ms"] < 5000

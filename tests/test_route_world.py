import math, os, numpy as np, pytest
import geo, world_grid as wg, mars_route as m
from conftest import make_world, world_xz

REAL_WORLD = os.environ.get("MARS_WORLD", os.path.join(os.path.dirname(__file__), "..", "..", "mars-route-walker-main", "world"))
needs_real = pytest.mark.skipif(not os.path.exists(os.path.join(REAL_WORLD, "world.json")), reason="no hay world real (MARS_WORLD)")

# Valores calculados con WorldStreamer.lonlat_to_world de viewer-godot/world.gd sobre el world.json real (Godot 4.7.2, float32)
REAL_ORIGIN = {"origin": {"lon": 77.4508857, "lat": 18.4446272, "px": [13511.822779662907, 13318.301789853489],
                          "mosaic_x0": 4577366.0, "mosaic_y0": 1106618.0}, "spacing_x": 0.9485082082232005, "spacing_z": 1.0,
               "body": {"radius_m": 3396190.0}}
GODOT = [((77.322539, 18.497263), (-7215.977051, -3119.971191)), ((77.4508857, 18.4446272), (0.0, 0.0)), ((77.4, 18.5), (-2860.923096, -3282.206055))]


def test_worldgeo_coincide_con_worldstreamer_y_vuelve():
    g = geo.WorldGeo(REAL_ORIGIN)
    for (lon, lat), (x, z) in GODOT:
        gx, gz = g.lonlat_to_local(lon, lat)
        assert abs(gx - x) < 2e-3 and abs(gz - z) < 2e-3
        lon2, lat2 = g.local_to_lonlat(gx, gz)
        assert abs(lon2 - lon) < 1e-9 and abs(lat2 - lat) < 1e-9


def test_ensamblado_con_borde_compartido_y_spacing_x(tmp_path):
    folder, w = make_world(tmp_path / "w")
    W = wg.World(folder)
    x_min, z_min = world_xz(w, 60, 30)          # cruza el borde entre tiles (px = 100 y py = 100)
    x_max, z_max = world_xz(w, 140, 170)
    for lod in (1, 5):
        g = wg.build_crop(W, x_min, x_max, z_min, z_max, lod)
        zs, xs = np.meshgrid(g["z0"] + np.arange(g["h"].shape[0]) * g["step"], g["x0"] + np.arange(g["h"].shape[1]) * g["step"], indexing="ij")
        esperado = 0.01 * (xs / 0.9 + 37.0) + 0.02 * (zs / 1.0 + 21.0)
        assert not g["nodata"].any()
        assert np.abs(g["h"] - esperado).max() < 1e-3, "lod %d" % lod             # plano exacto aun cruzando bordes
    assert 0.9 * 1.0 != 1.0 and abs(w["spacing_x"] - 0.9) < 1e-12


def test_nodata_fuera_de_tiles_y_tile_relleno(tmp_path):
    folder, w = make_world(tmp_path / "w", tiles=((0, 0), (1, 0), (0, 1)), nodata={(1, 0): 0.8, (0, 1): 0.2})
    W = wg.World(folder)
    x_min, z_min = world_xz(w, 10, 10)
    x_max, z_max = world_xz(w, 190, 190)
    g = wg.build_crop(W, x_min, x_max, z_min, z_max, 5)
    nd = g["nodata"]
    assert nd[-1, -1]                         # tile (1,1) no existe
    assert nd[2, -3]                          # tile (1,0): 80 % rellenado -> intransitable
    assert not nd[-3, 2]                      # tile (0,1): 20 % -> se usa
    assert [k for k, _ in g["partial_nodata"]] == [(0, 1)]


def test_ruta_corta_t1_y_larga_t5_y_errores(tmp_path):
    folder, w = make_world(tmp_path / "w", block=200, tiles=[(bx, by) for bx in range(3) for by in range(3)], plane=(0.001, 0.001))
    L = m.load_layers(folder)
    x0, z0 = world_xz(w, 50, 50)
    r = m.plan_route(L, (x0, z0), (x0 + 40, z0 + 30))
    assert r.ok and r.route["summary"]["grid"]["layer"] == "world:t1" and r.route["summary"]["grid"]["step_m"] == 1.0
    assert abs(r.route["summary"]["length_m"] - 50) < 3
    x1, z1 = world_xz(w, 570, 570)
    r5 = m.plan_route(L, (x0, z0), (x1, z1), lod=5)                      # ruta larga con t5
    assert r5.ok and r5.route["summary"]["grid"]["layer"] == "world:t5"
    assert abs(r5.route["goal"][0] - x1) < 6 and abs(r5.route["goal"][2] - z1) < 6
    assert r5.route["summary"]["length_m"] > 400
    # lat/lon <-> world con la georreferencia del world sintético
    lon, lat = L["georef"].local_to_lonlat(x0 + 20, z0 + 10)
    rl = m.plan_route(L, (x0, z0), {"lat": lat, "lon": lon})
    assert rl.ok and abs(rl.route["goal"][0] - (x0 + 20)) < 1.5 and len(rl.route["lonlat"]) == len(rl.route["points"])
    fuera = m.plan_route(L, (x0, z0), (x0 + 99999, z0))
    assert not fuera.ok and fuera.error_code == "fuera_de_capa" and "tiles" in fuera.error
    # replanificación desde otro punto: reutiliza el recorte si es el mismo rectángulo
    n_crops = len(L["crops"])
    m.plan_route(L, (x0 + 5, z0 + 5), (x0 + 40, z0 + 30))
    assert len(L["crops"]) <= n_crops + 1


def test_world_nodata_intransitable_y_terrain_map_no_soportado(tmp_path):
    folder, w = make_world(tmp_path / "w", tiles=((0, 0), (1, 0)), nodata={(1, 0): 1.0})
    L = m.load_layers(folder)
    a = world_xz(w, 20, 20)
    b = world_xz(w, 150, 20)                         # dentro del tile existente pero sin datos
    r = m.plan_route(L, a, b, snap_m=0.0)
    assert not r.ok and r.error_code == "intransitable"
    with pytest.raises(ValueError, match="world"):
        m.load_layers(folder, terrain_source="algo.npy")
    out = m.run_request({"scene": folder, "start": {"x": a[0], "z": a[1]}, "goal": {"x": a[0] + 10, "z": a[1] + 10}})
    assert out["ok"] and out["route"]["lonlat"]


@needs_real
def test_world_real_ingenuity_y_tiles_completos():
    import json
    w = json.load(open(os.path.join(REAL_WORLD, "world.json")))
    for t in w["tiles"]:
        for lod in ("t1", "t5", "t20"):
            assert os.path.exists(os.path.join(REAL_WORLD, "terrain", lod, "%d_%d.f32" % (t["bx"], t["by"])))
    L = m.load_layers(REAL_WORLD)
    r = m.plan_route(L, (0, 0), (40, 40))
    assert r.ok and r.route["summary"]["grid"]["layer"] == "world:t1"
    r = m.plan_route(L, (0, 0), {"waypoint": "ingenuity"})                   # ruta larga: t5 + jerárquica
    assert r.ok and r.route["summary"]["grid"]["layer"] == "world:t5" and r.route["summary"]["grid"]["hierarchical"]
    assert abs(r.route["goal"][0] + 7216) < 6 and abs(r.route["goal"][2] + 3120) < 6
    assert r.route["summary"]["length_m"] > 7800 and r.timing["total_ms"] < 60000
    lejos = m.plan_route(L, (0, 0), (50000, 0))
    assert not lejos.ok and lejos.error_code == "fuera_de_capa"


def test_world_altura_y_pendiente_salen_de_los_tiles(tmp_path):
    """Auditoría B3/B4: la y del JSON debe ser la del tile (como WorldStreamer.height_at) y la pendiente la local de 1 m.
    Antes se interpolaba dos veces (tile -> grid en metros -> punto) y la pendiente era la de la celda gruesa."""
    folder, w = make_world(tmp_path / "w", block=200, tiles=[(bx, by) for bx in range(3) for by in range(3)], plane=(0.002, 0.002), bump=0.8)
    L = m.load_layers(folder)
    W = L["world"]
    a = world_xz(w, 60, 60)
    b = world_xz(w, 520, 480)
    r = m.plan_route(L, a, b, lod=5, risk_weight=0.0, snap_m=60)
    assert r.ok and r.route["summary"]["grid"]["step_m"] == 5.0
    P = np.array(r.route["points"])
    y_tile = W.heights_at(P[:, 0], P[:, 2], 5)
    assert np.abs(P[:, 1] - y_tile).max() < 2e-3                            # igual que la superficie t5 del visor
    g = r.cost_grid
    y_grid = np.array([m.bilinear(g, g["h"], x, z) for x, z in P[:, [0, 2]]])
    assert np.abs(y_grid - y_tile).max() > 0.05                             # el método viejo sí fallaba (el test es significativo)
    s_fine = W.slopes_at(P[:, 0], P[:, 2], 1)
    assert np.abs(np.array(r.route["slope_deg"]) - np.round(s_fine, 1)).max() < 0.11
    assert np.abs(np.array([g["slope"][m.to_rc(g, x, z)] for x, z in P[:, [0, 2]]]) - s_fine).max() > 3   # la celda de 5 m ocultaba la pendiente real

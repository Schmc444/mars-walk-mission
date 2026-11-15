import json, math, numpy as np, pytest
import geo, waypoints, mars_route as m
from marswalk.geo import Site


def test_latlon_ida_y_vuelta_y_coincide_con_marswalk():
    ref = geo.GeoRef(77.36867979, 18.48255996)
    lon, lat = 77.3687 + 0.0004, 18.4826 - 0.0003
    x, z = ref.lonlat_to_local(lon, lat)
    lon2, lat2 = ref.local_to_lonlat(x, z)
    assert abs(lon2 - lon) < 1e-9 and abs(lat2 - lat) < 1e-9
    sx, sz = Site(77.36867979, 18.48255996).to_ground(lon, lat)
    assert abs(x - sx) < 1e-6 and abs(z - sz) < 1e-6
    assert ref.lonlat_to_local(77.36867979, 18.48255996) == (0.0, 0.0)


def test_parse_latlon():
    assert geo.parse_latlon("18.4826, 77.3687") == (18.4826, 77.3687)
    assert geo.parse_latlon("18.4826 77.3687") == (18.4826, 77.3687)
    for bad in ("hola", "18.4", "91, 10", "10, 400", "a, b"):
        with pytest.raises(geo.GeoError):
            geo.parse_latlon(bad)


def test_sin_georreferencia_no_inventa(scene_factory):
    folder = scene_factory(origin=False)
    with pytest.raises(geo.GeoError) as e:
        geo.GeoRef.from_scene(folder)
    assert e.value.code == "sin_georreferencia"
    L = m.load_layers(folder)
    r = m.plan_route(L, (0, 0), {"lat": 18.48, "lon": 77.36})
    assert not r.ok and r.error_code == "sin_georreferencia"


def test_punto_fuera_de_la_capa_y_destino_latlon(scene_factory):
    folder = scene_factory(n=61)
    L = m.load_layers(folder)
    ref = geo.GeoRef.from_scene(L["scene"])
    lon, lat = ref.local_to_lonlat(20.0, 10.0)
    r = m.plan_route(L, {"lat": 18.48255996, "lon": 77.36867979}, {"lat": lat, "lon": lon})
    assert r.ok and abs(r.route["goal"][0] - 20) < 0.6 and abs(r.route["goal"][2] - 10) < 0.6
    assert len(r.route["lonlat"]) == len(r.route["points"])
    lon, lat = ref.local_to_lonlat(500.0, 0.0)           # a 500 m: fuera de ±30 m
    r = m.plan_route(L, (0, 0), {"lat": lat, "lon": lon})
    assert not r.ok and r.error_code == "fuera_de_capa"


def test_punto_intransitable_se_mueve_a_la_celda_cercana(scene_factory):
    n = 61
    h = np.zeros((n, n))
    h[20:41, 38:40] = 40.0                                       # muro empinado de 2 celdas: queda bloqueado (cols 37-40)
    folder = scene_factory(n=n, h=h)
    L = m.load_layers(folder)
    g = m.build_cost(L, "normal")
    assert g["blocked"][30, 38] and not g["blocked"][30, 30] and not g["blocked"][30, 35]
    x, z, aviso = geo.validate_point(g, 8.0, 0.0, snap_m=5.0, what="meta")   # (x=8, z=0) -> celda (30, 38)
    assert aviso and "transitable mas cercana" in aviso and not g["blocked"][geo.local_to_cell(g, x, z)]
    with pytest.raises(geo.GeoError) as e:
        geo.validate_point(g, 8.0, 0.0, snap_m=0.0)
    assert e.value.code == "intransitable"
    r = m.plan_route(L, (-20, 0), (8, 0))
    assert r.ok and r.warnings                                   # avisa cuál celda usó


def test_waypoints_cargar_guardar_borrar(tmp_path):
    p = str(tmp_path / "w.json")
    assert waypoints.load(p) == []
    waypoints.add("base", "Base Alfa", 18.48, 77.36, "prueba", path=p)
    waypoints.add("rescate", "Punto de rescate", 18.49, 77.37, path=p)
    assert [w["id"] for w in waypoints.load(p)] == ["base", "rescate"]
    assert waypoints.resolve("BASE", p) == (18.48, 77.36, "Base Alfa")
    assert waypoints.resolve("punto de rescate", p)[0] == 18.49           # por nombre
    waypoints.add("base", "Base Alfa", 18.5, 77.4, path=p)                # mismo id: reemplaza
    assert len(waypoints.load(p)) == 2 and waypoints.resolve("base", p)[0] == 18.5
    waypoints.remove("base", p)
    assert [w["id"] for w in waypoints.load(p)] == ["rescate"]
    with pytest.raises(waypoints.WaypointError):
        waypoints.find("base", p)
    with pytest.raises(waypoints.WaypointError):
        waypoints.add("x", "x", 95, 10, path=p)


def test_waypoints_del_repo_placeholders_sin_coordenadas_inventadas():
    wps = waypoints.load()
    ph = [w for w in wps if w.get("placeholder")]
    assert ph and all(w["lat"] is None and w["lon"] is None for w in ph)
    with pytest.raises(waypoints.WaypointError, match="placeholder"):
        waypoints.resolve(ph[0]["id"])


def test_contrato_json(scene_factory, tmp_path):
    folder = scene_factory(n=61)
    wp = str(tmp_path / "w.json")
    ref = geo.GeoRef.from_scene(folder)
    lon, lat = ref.local_to_lonlat(15.0, -5.0)
    waypoints.add("meta", "Meta", lat, lon, path=wp)
    out = m.run_request({"scene": folder, "start": {"x": -10, "z": 0}, "goal": {"waypoint": "meta"}, "waypoints": wp, "condition": "normal", "risk_weight": 1.5})
    assert out["ok"] and out["schema"] == 1 and out["route"]["risk_weight"] == 1.5 and "total_ms" in out["timing_ms"]
    json.dumps(out)                                                       # serializable
    bad = m.run_request({"scene": folder, "goal": {"lat": 18.48, "lon": 99.0}})
    assert not bad["ok"] and bad["error_code"] == "fuera_de_capa" and bad["route"] is None
    assert m.run_request({"scene": folder})["error_code"] == "peticion_invalida"
    assert m.run_request({"scene": folder, "goal": {"waypoint": "nada"}, "waypoints": wp})["error_code"] == "waypoint_invalido"

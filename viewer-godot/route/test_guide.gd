extends SceneTree
## Precisión de GuidePath (auditoría de cálculos). Sin escena ni datos reales:
##   godot --headless --path viewer-godot --script res://route/test_guide.gd
## GUIDE_SCRIPT=res://ruta/otro.gd permite probar otra versión del script. Sale con código 0 si todo pasa.
var fails := 0


func check(c: bool, what: String) -> void:
	print(("OK    " if c else "FALLO ") + what)
	if not c:
		fails += 1


func _make_route(path: String) -> void:
	# Ruta curva con espaciado irregular (0.06-1.0 m, como la que deja Chaikin) y 1.4 s/m de ETA
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pts := []
	var eta := []
	var x := 0.0
	var z := 0.0
	var t := 0.0
	var ang := 0.3
	for i in 200:
		var step := rng.randf_range(0.06, 1.0)
		ang += 0.01
		x += cos(ang) * step
		z += sin(ang) * step
		t += step * 1.4
		pts.append([x, 0.1 * x, z])
		eta.append(t)
	var d := {"points": pts, "eta_s": eta, "slope_deg": pts.map(func(_p): return 3.0), "terrain": pts.map(func(_p): return 1),
		"terrain_names": {"1": "regolito"}, "warnings": [], "summary": {}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var script_path := OS.get_environment("GUIDE_SCRIPT") if OS.get_environment("GUIDE_SCRIPT") != "" else "res://route/guide_path.gd"
	var G: Node = load(script_path).new()
	G.json_path = ""
	root.add_child(G)
	var jp := ProjectSettings.globalize_path("user://test_route.json")
	_make_route(jp)
	check(G.set_route(jp), "set_route carga la ruta de prueba (%d puntos)" % G.pts.size())
	var total: float = G.cum[G.cum.size() - 1]
	var eta_total: float = G.eta[G.eta.size() - 1]

	# 1. distancia restante y ETA a lo largo de la ruta, paso 0.1 m
	var max_err := 0.0
	var max_eta_err := 0.0
	var max_jump := 0.0
	var prev := -1.0
	var s := 0.5
	while s < total - 2.0:
		var i: int = G._point_at(s)
		var a: Vector3 = G.pts[maxi(i - 1, 0)]
		var b: Vector3 = G.pts[i]
		var seg: float = G.cum[i] - G.cum[maxi(i - 1, 0)]
		var tt: float = 0.0 if seg < 1e-6 else (s - G.cum[maxi(i - 1, 0)]) / seg
		var st: Dictionary = G.update_player(a.lerp(b, tt), Basis.IDENTITY)
		max_err = maxf(max_err, absf(st["remaining_m"] - (total - s)))
		var eta_true: float = eta_total - lerpf(G.eta[maxi(i - 1, 0)], G.eta[i], tt)
		max_eta_err = maxf(max_eta_err, absf(st["eta_s"] - eta_true))
		if prev >= 0.0:
			max_jump = maxf(max_jump, absf((prev - st["remaining_m"]) - 0.1))
		prev = st["remaining_m"]
		s += 0.1
	check(max_err < 0.02, "distancia restante exacta sobre la ruta: error max %.3f m (antes ~0.5 m)" % max_err)
	check(max_eta_err < 0.05, "ETA restante exacto sobre la ruta: error max %.3f s" % max_eta_err)
	check(max_jump < 0.05, "la distancia restante avanza suave (salto max %.3f m respecto al avance real; antes ~0.9 m)" % max_jump)

	# 2. umbral de salida de ruta: jugador a 2.98 m REALES de la ruta (a mitad de un tramo) no debe avisar
	var mid := 100
	var a2: Vector3 = G.pts[mid]
	var b2: Vector3 = G.pts[mid + 1]
	var dir := Vector3(b2.x - a2.x, 0, b2.z - a2.z).normalized()
	var nrm := Vector3(-dir.z, 0, dir.x)
	var p_mid: Vector3 = a2.lerp(b2, 0.5)
	var st_in: Dictionary = G.update_player(p_mid + nrm * 2.98, Basis.IDENTITY)
	var st_out: Dictionary = G.update_player(p_mid + nrm * 3.02, Basis.IDENTITY)
	check(absf(st_in["off_route_m"] - 2.98) < 0.01 and st_in["off_route_m"] <= G.off_route_warn, "a 2.98 m reales mide %.3f m: sin aviso" % st_in["off_route_m"])
	check(st_out["off_route_m"] > G.off_route_warn, "a 3.02 m reales avisa (%.3f m)" % st_out["off_route_m"])

	# 3. VR: la flecha y la distancia usan la cámara, no el XROrigin3D
	var cam_pos := Vector3(G.pts[50].x + 1.5, 1.7, G.pts[50].z - 0.5)    # el jugador se movió 1.5 m dentro del cuarto
	G.update_player(Vector3(cam_pos.x, 0.0, cam_pos.z), Basis.IDENTITY, cam_pos)
	var ap: Vector3 = G._arrow.global_position
	check(Vector2(ap.x - cam_pos.x, ap.z - cam_pos.z).length() < 1.01 and absf(ap.y - (cam_pos.y - 0.5)) < 0.01, "la flecha se ubica 1 m delante de la cámara real (y %.2f)" % ap.y)

	# 4. alturas: al cambiar la altura del visor (streaming t5->t1) los chevrons cercanos se re-pegan
	G.height_fn = func(_x, _z): return 5.0
	var n: int = G.refresh_heights(G.pts[50], 30.0)
	var near_ok := n > 0
	var far_untouched := true
	for k in G._chev_pt.size():
		var i: int = G._chev_pt[k]
		var near: bool = absf(G.pts[i].x - G.pts[50].x) <= 30.0 and absf(G.pts[i].z - G.pts[50].z) <= 30.0
		if near:
			near_ok = near_ok and absf(G.pts[i].y - 5.0) < 1e-6
		else:
			far_untouched = far_untouched and absf(G.pts[i].y - 5.0) > 1e-6
	check(near_ok and far_untouched, "refresh_heights re-pega %d chevrons cercanos (y=5) y no toca los lejanos (en headless el MultiMesh no guarda transformaciones: se verifica pts[].y)" % n)
	print("RESULTADO: %s (%d fallos)" % ["TODO OK" if fails == 0 else "HAY FALLOS", fails])
	quit(0 if fails == 0 else 1)

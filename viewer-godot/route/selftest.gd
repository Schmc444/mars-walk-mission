extends SceneTree
## Prueba en modo headless del ingreso de destino, puntos guardados y recarga de ruta:
##   godot --headless --path viewer-godot --script res://route/selftest.gd -- --patch=patch_793
## Imprime "OK ..." / "FALLO ..." por comprobación y termina con código 0 (todo bien) o 1.

var fails := 0
var ui: Node
var guide: Node
var ready_count := 0
var failed_msgs: Array = []
var dest_events: Array = []


func check(cond: bool, what: String) -> void:
	print(("OK    " if cond else "FALLO ") + what)
	if not cond:
		fails += 1


func _initialize() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)


func _wait_route(timeout_s := 60.0) -> bool:
	var t0 := Time.get_ticks_msec()
	var n := ready_count + failed_msgs.size()
	while ready_count + failed_msgs.size() == n and Time.get_ticks_msec() - t0 < timeout_s * 1000.0:
		await process_frame
	return ready_count + failed_msgs.size() > n


func _run(main: Node) -> void:
	await process_frame
	ui = main.get_node_or_null("RouteUI")
	guide = main.get_node_or_null("GuidePath")
	check(ui != null and guide != null, "RouteUI y GuidePath creados en main")
	if ui == null:
		quit(1)
		return
	ui.route_ready.connect(func(_p): ready_count += 1)
	ui.route_failed.connect(func(m): failed_msgs.append(m))
	ui.destination_selected.connect(func(lat, lon, nombre): dest_events.append([lat, lon, nombre]))

	# 1. validación de formato en pantalla
	for bad in ["hola", "18.4", "91, 10", "10, 400", ""]:
		check(ui.submit_text(bad) != "", "formato inválido rechazado: '%s' -> %s" % [bad, ui.submit_text(bad)])
	check(dest_events.is_empty(), "ningún destino emitido con entradas inválidas")

	# 2. georreferencia ida y vuelta
	var ll: Array = ui.local_to_latlon(12.0, -7.0)
	var xz: Vector2 = ui.latlon_to_local(ll[0], ll[1])
	check(absf(xz.x - 12.0) < 1e-3 and absf(xz.y + 7.0) < 1e-3, "lat/lon <-> metros ida y vuelta (%.6f, %.6f)" % [ll[0], ll[1]])

	# 3. terreno bajo el jugador (el mapa lo escribe el planificador la primera vez)
	var t0 := Time.get_ticks_msec()
	while ui.terrain_cls.is_empty() and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
		ui._load_terrain_map()
	check(not ui.terrain_cls.is_empty(), "mapa de clases cargado (%d celdas, fuente %s)" % [ui.terrain_cls.size(), ui.terrain_meta.get("source", "?")])
	check(ui.terrain_name_at(0, 0) in ["roca firme", "regolito", "duna", "bloques"], "HUD: Terreno bajo el jugador = %s" % ui.terrain_name_at(0, 0))
	check(ui.hud_lines(Vector3.ZERO).contains("Terreno: "), "hud_lines incluye 'Terreno: ...'")

	# 4. destino por lat/lon escrito -> señal única -> ruta dibujada
	var goal: Array = ui.local_to_latlon(30.0, 25.0)
	check(ui.submit_text("%.7f, %.7f" % [goal[0], goal[1]]) == "", "lat/lon válido aceptado")
	check(dest_events.size() == 1, "se emitió destination_selected una vez")
	check(ui.hud_lines(Vector3.ZERO).contains("Calculando"), "HUD muestra 'Calculando…' mientras el planificador corre")
	check(await _wait_route(), "el planificador respondió")
	check(ready_count == 1 and guide.has_route(), "ruta cargada en GuidePath (%d puntos)" % guide.pts.size())
	var n1: int = guide.pts.size()
	var goal1: Vector3 = guide.pts[guide.pts.size() - 1]
	check(absf(goal1.x - 30.0) < 1.0 and absf(goal1.z - 25.0) < 1.0, "la meta de la ruta cae en el destino (%.1f, %.1f)" % [goal1.x, goal1.z])
	var has_terrain_field: bool = guide.data.has("terrain") and guide.data.has("terrain_source")
	check(has_terrain_field, "la ruta trae clase de terreno por punto y la fuente (%s)" % str(guide.data.get("terrain_source", {}).get("source")))

	# 5. punto guardado -> misma señal; placeholder rechazado con mensaje
	var err: String = ui.select_waypoint("base")
	check(err.contains("placeholder"), "placeholder 'base' rechazado: " + err)
	check(ui.select_waypoint("nada") != "", "punto inexistente rechazado")
	check(ui.select_waypoint("1") == "", "punto guardado #1 (origen_escena) aceptado")
	check(dest_events.size() == 2 and dest_events[1][2].begins_with("Origen"), "misma señal para punto guardado: %s" % str(dest_events[1]))
	check(await _wait_route(), "ruta al punto guardado calculada")

	# 6. recarga en ejecución: no se acumulan nodos y la ruta cambia
	check(guide.pts.size() != n1 or guide.pts[guide.pts.size() - 1].distance_to(goal1) > 1.0, "set_route reemplazó la ruta anterior")
	await process_frame
	await process_frame
	var kids: int = guide.get_child_count()
	check(kids <= 5, "GuidePath no acumula nodos tras recargar (hijos: %d)" % kids)

	# 7. replanificación desde otra posición (R) hacia el último destino
	main.origin.position = Vector3(-20, main.height_at(-20, -20), -20)
	ui.replan()
	check(await _wait_route(), "replanificación desde otra posición")
	check(absf(guide.pts[0].x + 20) < 3.0 and absf(guide.pts[0].z + 20) < 3.0, "la nueva ruta parte de la posición actual (%.1f, %.1f)" % [guide.pts[0].x, guide.pts[0].z])

	# 8. destino inalcanzable: error claro en pantalla
	var far: Array = ui.local_to_latlon(5000.0, 0.0)
	ui.submit_text("%.6f, %.6f" % [far[0], far[1]])
	check(await _wait_route(), "respuesta para destino fuera de la capa")
	check(failed_msgs.size() == 1 and failed_msgs[0].contains("fuera de la capa"), "error claro: " + (failed_msgs[0] if failed_msgs.size() else "(ninguno)"))

	# 9. posición del jugador por la misma vía
	var got: Array = []
	ui.player_position_changed.connect(func(a, b): got.append([a, b]))
	ui.tick(Vector3(3, 0, 4), Basis.IDENTITY, 1.0)
	check(got.size() == 1 and absf(got[0][0] - ui.local_to_latlon(3, 4)[0]) < 1e-9, "player_position_changed emitida con lat/lon del jugador")
	ui.set_start(18.48, 77.36)
	check(ui._start_override != null, "set_start acepta la posición del mapa")

	print("RESULTADO: %s (%d fallos)" % ["TODO OK" if fails == 0 else "HAY FALLOS", fails])
	quit(0 if fails == 0 else 1)

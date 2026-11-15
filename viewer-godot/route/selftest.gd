extends SceneTree
## Prueba en modo headless del ingreso de destino, puntos guardados y recarga de ruta:
##   godot --headless --path viewer-godot --script res://route/selftest.gd -- --patch=patch_793
##   godot --headless --path viewer-godot --script res://route/selftest.gd -- --world=/ruta/al/world --norings
## Con --world= prueba el modo world (incluye Ingenuity como destino); si no, el modo parche.
## Imprime "OK ..." / "FALLO ..." por comprobación y termina con código 0 (todo bien) o 1.

var fails := 0
var ui: Node
var guide: Node
var ready_count := 0
var failed_msgs: Array = []
var dest_events: Array = []
var world_mode := false


func check(cond: bool, what: String) -> void:
	print(("OK    " if cond else "FALLO ") + what)
	if not cond:
		fails += 1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--world="):
			world_mode = true
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
	while ui.terrain_cls.is_empty() and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
		if world_mode:
			ui.tick(main.origin.position, Basis.IDENTITY, 0.016)    # en world la ventana se pide desde tick()
		else:
			ui._load_terrain_map()
		if not world_mode and ui._terrain_pid > 0 and not OS.is_process_running(ui._terrain_pid):
			ui.tick(main.origin.position, Basis.IDENTITY, 0.016)
	check(not ui.terrain_cls.is_empty(), "mapa de clases cargado (%d celdas, fuente %s)" % [ui.terrain_cls.size(), ui.terrain_meta.get("source", "?")])
	check(ui.terrain_name_at(0, 0) in ["roca firme", "regolito", "duna", "bloques"], "HUD: Terreno bajo el jugador = %s" % ui.terrain_name_at(0, 0))
	check(ui.hud_lines(Vector3.ZERO).contains("Terreno: "), "hud_lines incluye 'Terreno: ...'")

	# 4. destino por lat/lon escrito -> señal única -> ruta dibujada
	var gx := 300.0 if world_mode else 30.0
	var gz := -200.0 if world_mode else 25.0
	if world_mode:                     # la georreferencia debe coincidir con WorldStreamer.lonlat_to_world
		var wl: Array = ui.local_to_latlon(gx, gz)
		var ww: Vector2 = main.W.lonlat_to_world(wl[1], wl[0])
		check(absf(ww.x - gx) < 0.01 and absf(ww.y - gz) < 0.01, "lat/lon coincide con WorldStreamer (%.4f, %.4f)" % [ww.x, ww.y])
	var goal: Array = ui.local_to_latlon(gx, gz)
	check(ui.submit_text("%.7f, %.7f" % [goal[0], goal[1]]) == "", "lat/lon válido aceptado")
	check(dest_events.size() == 1, "se emitió destination_selected una vez")
	check(ui.hud_lines(Vector3.ZERO).contains("Calculando"), "HUD muestra 'Calculando…' mientras el planificador corre")
	check(await _wait_route(120.0), "el planificador respondió")
	check(ready_count == 1 and guide.has_route(), "ruta cargada en GuidePath (%d puntos)" % guide.pts.size())
	var n1: int = guide.pts.size()
	var goal1: Vector3 = guide.pts[guide.pts.size() - 1]
	check(absf(goal1.x - gx) < 6.0 and absf(goal1.z - gz) < 6.0, "la meta de la ruta cae en el destino (%.1f, %.1f)" % [goal1.x, goal1.z])
	var has_terrain_field: bool = guide.data.has("terrain") and guide.data.has("terrain_source")
	check(has_terrain_field, "la ruta trae clase de terreno por punto y la fuente (%s)" % str(guide.data.get("terrain_source", {}).get("source")))

	# 5. punto guardado -> misma señal; placeholder rechazado con mensaje
	var err: String = ui.select_waypoint("base")
	check(err.contains("placeholder"), "placeholder 'base' rechazado: " + err)
	check(ui.select_waypoint("nada") != "", "punto inexistente rechazado")
	var wp_key := "ingenuity" if world_mode else "1"
	check(ui.select_waypoint(wp_key) == "", "punto guardado '%s' aceptado" % wp_key)
	check(dest_events.size() == 2, "misma señal para punto guardado: %s" % str(dest_events[1]))
	check(await _wait_route(180.0), "ruta al punto guardado calculada")
	if world_mode:
		var ing: Vector2 = main.W.lonlat_to_world(77.322539, 18.497263)
		var ge: Vector3 = guide.pts[guide.pts.size() - 1]
		check(guide.has_route() and absf(ge.x - ing.x) < 8.0 and absf(ge.z - ing.y) < 8.0, "Ingenuity alcanzable: meta de la ruta (%.0f, %.0f) vs Ingenuity (%.0f, %.0f), %.1f km" % [ge.x, ge.z, ing.x, ing.y, guide.cum[guide.cum.size() - 1] / 1000.0])
		check(absf(guide.pts[3].y - main.W.height_at(guide.pts[3].x, guide.pts[3].z)) < 0.01, "la guía queda sobre el terreno del world (height_at)")

	# 6. recarga en ejecución: no se acumulan nodos y la ruta cambia
	check(guide.pts.size() != n1 or guide.pts[guide.pts.size() - 1].distance_to(goal1) > 1.0, "set_route reemplazó la ruta anterior")
	await process_frame
	await process_frame
	var kids: int = guide.get_child_count()
	check(kids <= 5, "GuidePath no acumula nodos tras recargar (hijos: %d)" % kids)

	# 7. replanificación desde otra posición (R) hacia el último destino
	var rx := -20.0
	if world_mode:
		main.riding = false
		rx = 100.0
		main.origin.position = Vector3(rx, main.W.height_at(rx, rx), rx)
	else:
		main.origin.position = Vector3(rx, main.height_at(rx, rx), rx)
	ui.replan()
	check(await _wait_route(180.0), "replanificación desde otra posición")
	check(absf(guide.pts[0].x - rx) < 6.0 and absf(guide.pts[0].z - rx) < 6.0, "la nueva ruta parte de la posición actual (%.1f, %.1f)" % [guide.pts[0].x, guide.pts[0].z])

	# 8. destino inalcanzable: error claro en pantalla
	var far: Array = ui.local_to_latlon(50000.0 if world_mode else 5000.0, 0.0)
	ui.submit_text("%.6f, %.6f" % [far[0], far[1]])
	check(await _wait_route(), "respuesta para destino fuera de la capa")
	check(failed_msgs.size() == 1 and failed_msgs[0].contains("fuera de"), "error claro: " + (failed_msgs[0] if failed_msgs.size() else "(ninguno)"))

	# 9. posición del jugador por la misma vía
	var got: Array = []
	ui.player_position_changed.connect(func(a, b): got.append([a, b]))
	main.cam.position = Vector3(0, 1.6, 0)
	main.origin.position = Vector3(3, 0, 4)       # tick() usa la cámara (feet()), que cuelga del origen
	ui.tick(Vector3(3, 0, 4), Basis.IDENTITY, 1.0)
	check(got.size() == 1 and absf(got[0][0] - ui.local_to_latlon(3, 4)[0]) < 1e-9, "player_position_changed emitida con lat/lon del jugador")
	ui.set_start(18.48, 77.36)
	check(ui._start_override != null, "set_start acepta la posición del mapa")

	# 10. mientras se escribe (typing) el jugador no se mueve; al cerrar el diálogo sí
	main.riding = false
	var key := InputEventKey.new()
	key.keycode = KEY_W
	key.physical_keycode = KEY_W
	key.pressed = true
	await process_frame                             # deja que el visor reasiente la altura tras el cambio de posición
	var p0: Vector3 = main.origin.position
	ui.typing = true
	Input.parse_input_event(key)
	for i in 20:
		await process_frame
	var p1: Vector3 = main.origin.position
	check(p1.distance_to(p0) < 0.001, "con typing=true el jugador no se mueve (W pulsada)")
	ui.typing = false
	for i in 20:
		await process_frame
	check(main.origin.position.distance_to(p0) > 0.05, "con typing=false W sí mueve al jugador (%.2f m)" % main.origin.position.distance_to(p0))
	key.pressed = false
	Input.parse_input_event(key)

	# 11. VR: la posición del jugador es la de la CÁMARA (room-scale), no la del XROrigin3D
	main.cam.position = Vector3(2.0, 1.6, -1.0)
	var fe: Vector3 = ui.feet()
	check(absf(fe.x - (main.origin.position.x + 2.0)) < 1e-4 and absf(fe.z - (main.origin.position.z - 1.0)) < 1e-4, "feet() usa la cámara: (%.2f, %.2f) vs origen (%.2f, %.2f)" % [fe.x, fe.z, main.origin.position.x, main.origin.position.z])
	var pl: Array = ui.player_latlon()
	var back: Vector2 = ui.latlon_to_local(pl[0], pl[1])
	check(absf(back.x - fe.x) < 1e-3 and absf(back.y - fe.z) < 1e-3, "player_latlon corresponde a la cámara")
	main.cam.position = Vector3(0, 1.6, 0)

	print("RESULTADO: %s (%d fallos)" % ["TODO OK" if fails == 0 else "HAY FALLOS", fails])
	quit(0 if fails == 0 else 1)

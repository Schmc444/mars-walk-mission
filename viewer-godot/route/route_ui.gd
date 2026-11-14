extends Node
class_name RouteUI
## Selección de destino + planificador de rutas para el visor (modo parche: --patch=patch_793).
##
## UNA sola puerta para elegir destino: la señal `destination_selected(lat, lon, nombre)`.
## El ingreso por teclado (L), los puntos guardados (P) y -en la versión final- el mapa solo tienen que emitirla.
## También se puede entrar la posición del jugador desde fuera: `set_start(lat, lon)` / `clear_start()`;
## y salir: la señal `player_position_changed(lat, lon)` (para que el mapa muestre dónde está el jugador).
##
## Cómo pide la ruta: ejecuta `route-planner/mars_route.py --request req.json --result res.json` como proceso externo
## (OS.create_process, sin bloquear el frame), muestra "Calculando…" en el HUD y al terminar llama a GuidePath.set_route().
## Teclas: L = escribir lat/lon · P = puntos guardados (1-9) · R = recalcular desde donde estás · C = borrar ruta · Esc = cerrar.
## Los archivos temporales van a user://route/. Contrato JSON: route-planner/README.md ("Integración con el mapa").

signal destination_selected(lat: float, lon: float, nombre: String)
signal player_position_changed(lat: float, lon: float)
signal route_ready(result_path: String)
signal route_failed(message: String)

@export var condition := "normal"
@export var risk_weight := 1.0            # --riesgo del planificador: más alto = evita más dunas/rocas/pendiente
@export var python_path := ""             # vacío = busca ../.venv/bin/python y luego python3
@export var waypoints_path := "res://route/waypoints.json"

const R_MARS := 3396190.0                 # igual que route-planner/geo.py
const EMIT_EVERY := 0.5                   # s entre player_position_changed

var menu_open := false                    # true mientras el menu VR esta abierto
var vr_menu: Node3D
var typing := false                       # true mientras hay un diálogo abierto (main.gd deja de mover al jugador)
var core: Node                            # main.gd: origin (XROrigin3D), cam, hud
var guide: Node                           # GuidePath
var scene_dir := ""                       # ruta de la escena (patch_793) o de la carpeta del world
var world_mode := false                   # true: escena "world" (WorldStreamer) en vez de un parche
var W: Node                               # WorldStreamer (solo world_mode)
var lon0 := 0.0
var lat0 := 0.0
var has_geo := false
var terrain_n := 0
var terrain_step := 1.0
var terrain_half := 0.0
var terrain_cls := PackedByteArray()
var terrain_meta := {}
var waypoints: Array = []
var status := ""                          # mensaje corto del HUD (calculando, error, resumen)
var status_until := 0.0
var last_dest := {}                       # {lat, lon, nombre} del último destino
var _start_override = null                # Vector2(lat, lon) o null
var _busy_pid := -1
var _busy_req := ""
var _busy_res := ""
var _busy_name := ""
var _terrain_pid := -1
var _req_n := 0
var _emit_t := 0.0
var _last_emit := [INF, INF]
var _panel: PanelContainer
var _title: Label
var _edit: LineEdit
var _err: Label
var _list: Label
var _mode := ""                           # "", "latlon", "puntos"
var _py := ""
var _script := ""
var _out_dir := ""


func setup(core_node: Node, guide_node: Node, scene_res_dir: String, scene: Dictionary) -> void:
	## Modo parche: georreferencia de scene.json -> origin.
	core = core_node
	guide = guide_node
	guide.hud_terrain = false
	scene_dir = ProjectSettings.globalize_path(scene_res_dir).trim_suffix("/")
	var o: Dictionary = scene.get("origin", {})
	if o.has("lon") and o.has("lat"):
		lon0 = float(o["lon"])
		lat0 = float(o["lat"])
		has_geo = true
	_init_common()
	if core.get("left") != null and core.left != null:
		vr_menu = load("res://route/vr_menu.gd").new()
		vr_menu.name = "VRMenu"
		core.add_child(vr_menu)
		vr_menu.setup(self, core)


func setup_world(core_node: Node, guide_node: Node, world: Node) -> void:
	## Modo world: usa el WorldStreamer (misma geometría y lat/lon que el visor) y pega la guía a su terreno.
	core = core_node
	guide = guide_node
	guide.hud_terrain = false
	guide.lift = 0.3
	guide.height_fn = world.height_at
	world_mode = true
	W = world
	scene_dir = world.dir.trim_suffix("/")
	has_geo = true
	_init_common()


func _init_common() -> void:
	var proj := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var repo := proj.get_base_dir()
	_script = repo.path_join("route-planner/mars_route.py")
	_py = python_path
	if _py == "":
		var venv := repo.path_join(".venv/bin/python")
		_py = venv if FileAccess.file_exists(venv) else "python3"
	_out_dir = ProjectSettings.globalize_path("user://route")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_load_waypoints()
	_build_ui()
	_load_terrain_map()


# ------------------------------------------------------------------ georreferencia (misma fórmula que route-planner/geo.py)
func latlon_to_local(lat: float, lon: float) -> Vector2:
	if world_mode:   # misma fórmula que WorldStreamer.lonlat_to_world, en float64
		var o: Dictionary = W.W["origin"]
		var px: float = (W.planet_r * deg_to_rad(lon) - float(o["mosaic_x0"])) - W.opx
		var py: float = (float(o["mosaic_y0"]) - W.planet_r * deg_to_rad(lat)) - W.opy
		return Vector2(px * W.sx, py * W.sz)
	var dlon := fposmod(lon - lon0 + 180.0, 360.0) - 180.0
	return Vector2(R_MARS * cos(deg_to_rad(lat0)) * deg_to_rad(dlon), R_MARS * deg_to_rad(lat0 - lat))


func local_to_latlon(x: float, z: float) -> Array:
	## [lat, lon] en float64 (un Vector2 es float32 y pierde ~6 cm de precisión en grados)
	if world_mode:   # misma fórmula que WorldStreamer.world_to_lonlat
		var o: Dictionary = W.W["origin"]
		var X: float = (x / W.sx + W.opx) + float(o["mosaic_x0"])
		var Y: float = float(o["mosaic_y0"]) - (z / W.sz + W.opy)
		return [rad_to_deg(Y / W.planet_r), rad_to_deg(X / W.planet_r)]
	return [lat0 - rad_to_deg(z / R_MARS), fposmod(lon0 + rad_to_deg(x / (R_MARS * cos(deg_to_rad(lat0)))), 360.0)]


# ------------------------------------------------------------------ puntos guardados
func _load_waypoints() -> void:
	waypoints = []
	if not FileAccess.file_exists(waypoints_path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(waypoints_path))
	if d is Dictionary and d.has("waypoints"):
		waypoints = d["waypoints"]


func _waypoint_usable(w: Dictionary) -> bool:
	return w.get("lat") != null and w.get("lon") != null


func select_waypoint(key: String) -> String:
	## Elige un punto guardado por número (1-9), id o nombre. Devuelve "" si todo bien o el mensaje de error.
	_load_waypoints()
	var w = null
	if key.is_valid_int() and int(key) >= 1 and int(key) <= waypoints.size():
		w = waypoints[int(key) - 1]
	else:
		for x in waypoints:
			if str(x["id"]).to_lower() == key.to_lower() or str(x["nombre"]).to_lower() == key.to_lower():
				w = x
	if w == null:
		return "No hay un punto guardado '%s'" % key
	if not _waypoint_usable(w):
		return "'%s' es un placeholder sin coordenadas: edita res://route/waypoints.json" % w["nombre"]
	destination_selected.emit(float(w["lat"]), float(w["lon"]), str(w["nombre"]))
	return ""


# ------------------------------------------------------------------ ingreso por teclado
static func parse_latlon(text: String) -> Dictionary:
	## "18.4826, 77.3687" -> {lat, lon} o {error}. Valida formato y rango.
	var t := text.replace(";", " ").replace(",", " ").strip_edges()
	var parts: PackedStringArray = []
	for p in t.split(" ", false):
		parts.append(p)
	if parts.size() != 2:
		return {"error": "Formato: lat, lon en grados decimales (ej. 18.4826, 77.3687)"}
	if not parts[0].is_valid_float() or not parts[1].is_valid_float():
		return {"error": "Lat y lon deben ser números decimales (ej. 18.4826, 77.3687)"}
	var lat := parts[0].to_float()
	var lon := parts[1].to_float()
	if lat < -90.0 or lat > 90.0:
		return {"error": "Latitud fuera de rango (-90 a 90): %s" % parts[0]}
	if lon < -360.0 or lon > 360.0:
		return {"error": "Longitud fuera de rango (-360 a 360): %s" % parts[1]}
	return {"lat": lat, "lon": lon}


func submit_text(text: String) -> String:
	## Procesa lo escrito: "lat, lon" o el id/nombre de un punto guardado. Devuelve "" si se aceptó o el mensaje de error.
	var p := parse_latlon(text)
	if not p.has("error"):
		destination_selected.emit(p["lat"], p["lon"], "%.5f, %.5f" % [p["lat"], p["lon"]])
		return ""
	_load_waypoints()
	for x in waypoints:
		if str(x["id"]).to_lower() == text.strip_edges().to_lower() or str(x["nombre"]).to_lower() == text.strip_edges().to_lower():
			return select_waypoint(str(x["id"]))
	return p["error"]


func _build_ui() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 20
	add_child(cl)
	_panel = PanelContainer.new()
	_panel.position = Vector2(16, 90)
	_panel.custom_minimum_size = Vector2(430, 0)
	_panel.visible = false
	cl.add_child(_panel)
	var vb := VBoxContainer.new()
	_panel.add_child(vb)
	_title = Label.new()
	vb.add_child(_title)
	_edit = LineEdit.new()
	_edit.placeholder_text = "lat, lon   (ej. 18.4826, 77.3687)  o  id/nombre de punto"
	_edit.text_submitted.connect(_on_text_submitted)
	vb.add_child(_edit)
	_list = Label.new()
	vb.add_child(_list)
	_err = Label.new()
	_err.add_theme_color_override("font_color", Color(1, 0.4, 0.35))
	vb.add_child(_err)
	destination_selected.connect(_on_destination_selected)


func open_latlon() -> void:
	_mode = "latlon"
	typing = true
	_title.text = "Destino: escribe latitud, longitud y Enter  (Esc = cancelar)"
	_list.text = ""
	_err.text = ""
	_edit.visible = true
	_edit.text = ""
	_panel.visible = true
	_edit.grab_focus()


func open_points() -> void:
	_load_waypoints()
	_mode = "puntos"
	typing = true
	_title.text = "Puntos guardados: pulsa su número  (Esc = cancelar)"
	var s := ""
	for i in mini(waypoints.size(), 9):
		var w: Dictionary = waypoints[i]
		s += "%d. %s%s\n" % [i + 1, w["nombre"], "" if _waypoint_usable(w) else "   [placeholder sin coordenadas]"]
	_list.text = s if s != "" else "(no hay puntos en waypoints.json)"
	_err.text = ""
	_edit.visible = false
	_panel.visible = true


func close_dialog() -> void:
	_mode = ""
	typing = false
	_panel.visible = false
	_edit.release_focus()


func _on_text_submitted(text: String) -> void:
	var err := submit_text(text)
	if err == "":
		close_dialog()
	else:
		_err.text = err


func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if _mode != "":
		if e.keycode == KEY_ESCAPE:
			close_dialog()
			get_viewport().set_input_as_handled()
		elif _mode == "puntos" and e.keycode >= KEY_1 and e.keycode <= KEY_9:
			var err := select_waypoint(str(e.keycode - KEY_0))
			if err == "":
				close_dialog()
			else:
				_err.text = err
			get_viewport().set_input_as_handled()
		return
	match e.keycode:
		KEY_L:
			open_latlon()
			get_viewport().set_input_as_handled()
		KEY_P:
			open_points()
			get_viewport().set_input_as_handled()
		KEY_R:
			replan()
		KEY_C:
			clear_route()


# ------------------------------------------------------------------ posición del jugador (entrada/salida)
func set_start(lat: float, lon: float) -> void:
	## El mapa puede fijar el punto de partida (en vez de la posición del jugador en el visor).
	_start_override = Vector2(lat, lon)


func clear_start() -> void:
	_start_override = null


func player_latlon() -> Array:
	var p: Vector3 = core.origin.position
	return local_to_latlon(p.x, p.z)


# ------------------------------------------------------------------ pedir la ruta al planificador
func _say(msg: String, secs := 8.0) -> void:
	status = msg
	status_until = Time.get_ticks_msec() / 1000.0 + secs


func _on_destination_selected(lat: float, lon: float, nombre: String) -> void:
	last_dest = {"lat": lat, "lon": lon, "nombre": nombre}
	request_route(lat, lon, nombre)


func replan() -> void:
	## Recalcula desde la posición actual hacia el último destino.
	if last_dest.is_empty():
		_say("No hay destino: pulsa L (lat/lon) o P (puntos guardados)")
		return
	request_route(last_dest["lat"], last_dest["lon"], last_dest["nombre"])


func clear_route() -> void:
	if _busy_pid > 0:
		OS.kill(_busy_pid)
		_busy_pid = -1
	guide.clear_route()
	_say("Ruta borrada", 3.0)


func request_route(lat: float, lon: float, nombre: String) -> void:
	if not has_geo:
		_say("Esta escena no tiene georreferencia (scene.json -> origin): no se pueden usar lat/lon")
		route_failed.emit(status)
		return
	if _busy_pid > 0:
		OS.kill(_busy_pid)               # una petición nueva reemplaza a la anterior
	_req_n += 1
	_busy_req = _out_dir.path_join("req_%d.json" % _req_n)
	_busy_res = _out_dir.path_join("res_%d.json" % _req_n)
	_busy_name = nombre
	var start := {}
	if _start_override != null:
		start = {"lat": _start_override.x, "lon": _start_override.y}
	else:
		var p: Vector3 = core.origin.position
		start = {"x": p.x, "z": p.z}
	var req := {"scene": scene_dir, "condition": condition, "risk_weight": risk_weight,
		"start": start, "goal": {"lat": lat, "lon": lon}}
	if not world_mode:
		req["layer"] = "terrain"
	var f := FileAccess.open(_busy_req, FileAccess.WRITE)
	f.store_string(JSON.stringify(req))
	f.close()
	_busy_pid = OS.create_process(_py, [_script, scene_dir, "--request", _busy_req, "--result", _busy_res])
	if _busy_pid <= 0:
		_busy_pid = -1
		_say("No se pudo ejecutar el planificador (python: %s)" % _py, 12.0)
		route_failed.emit(status)
		return
	_say("Calculando ruta a %s…" % nombre, 120.0)


func _finish_request() -> void:
	_busy_pid = -1
	if not FileAccess.file_exists(_busy_res):
		_say("El planificador terminó sin resultado (revisa que %s tenga numpy y Pillow)" % _py, 12.0)
		route_failed.emit(status)
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(_busy_res))
	if not d is Dictionary:
		_say("Resultado del planificador ilegible", 12.0)
		route_failed.emit(status)
		return
	if not d.get("ok", false):
		_say("No se pudo planificar: %s" % d.get("error", "?"), 12.0)
		route_failed.emit(status)
		return
	if not guide.set_route(_busy_res, _busy_name):
		_say("La ruta recibida no se pudo dibujar", 12.0)
		route_failed.emit(status)
		return
	var sm: Dictionary = d["route"]["summary"]
	var extra := ""
	for w in d.get("warnings", []):
		extra += "\n⚠ " + str(w)
	_say("Ruta a %s: %.0f m · ETA %d s · duna %.0f m · calculada en %.0f ms%s" % [_busy_name, sm["length_m"], sm["eta_s"], sm["dune_m"], d["timing_ms"]["total_ms"], extra], 15.0)
	route_ready.emit(_busy_res)


# ------------------------------------------------------------------ terreno bajo el jugador
var _terrain_n_req := 0
var _terrain_prefix := ""


func _load_terrain_map() -> void:
	## Parche: matriz de toda la escena (se genera una vez). World: ventana t1 alrededor del jugador (ver _ensure_terrain_window).
	if world_mode:
		return
	var prefix := _out_dir.path_join("terreno_" + scene_dir.get_file())
	if FileAccess.file_exists(prefix + ".u8") and FileAccess.file_exists(prefix + ".json"):
		_read_terrain(prefix)
		return
	if _terrain_pid <= 0:                # aún no existe: pedirla al planificador (asíncrono)
		_terrain_prefix = prefix
		_terrain_pid = OS.create_process(_py, [_script, scene_dir, "--export-terrain", prefix])


func _read_terrain(prefix: String) -> bool:
	if not (FileAccess.file_exists(prefix + ".u8") and FileAccess.file_exists(prefix + ".json")):
		return false
	var m = JSON.parse_string(FileAccess.get_file_as_string(prefix + ".json"))
	if not m is Dictionary:
		return false
	terrain_meta = m
	terrain_n = int(m["n"])
	terrain_step = float(m["step_m"])
	terrain_half = float(m["half_m"])
	terrain_cls = FileAccess.get_file_as_bytes(prefix + ".u8")
	return true


func _ensure_terrain_window(p: Vector3) -> void:
	## world: pide (asíncrono) una ventana de clases de ~400 m centrada en el jugador cuando no hay una o se acerca al borde.
	if _terrain_pid > 0:
		return
	if not terrain_cls.is_empty():
		var x0 := float(terrain_meta["x0"])
		var z0 := float(terrain_meta["z0"])
		var w := float(terrain_meta["nc"]) * terrain_step
		var h := float(terrain_meta["nr"]) * terrain_step
		if p.x > x0 + 60.0 and p.x < x0 + w - 60.0 and p.z > z0 + 60.0 and p.z < z0 + h - 60.0:
			return
	_terrain_n_req += 1
	_terrain_prefix = _out_dir.path_join("terreno_world_%d" % _terrain_n_req)
	_terrain_pid = OS.create_process(_py, [_script, scene_dir, "--export-terrain", _terrain_prefix, "--around", str(p.x), str(p.z), "--radius", "200"])


func terrain_code_at(x: float, z: float) -> int:
	## Código de clase (0 roca firme, 1 regolito, 2 duna, 3 bloques) de la celda bajo (x, z); -1 si no hay mapa o está fuera.
	if terrain_cls.is_empty():
		return -1
	var nr := int(terrain_meta.get("nr", terrain_n))
	var nc := int(terrain_meta.get("nc", terrain_n))
	var x0 := float(terrain_meta.get("x0", -terrain_half))
	var z0 := float(terrain_meta.get("z0", -terrain_half))
	var r := int(round((z - z0) / terrain_step))
	var c := int(round((x - x0) / terrain_step))
	if r < 0 or c < 0 or r >= nr or c >= nc:
		return -1
	return terrain_cls[r * nc + c]


func terrain_name_at(x: float, z: float) -> String:
	var k := terrain_code_at(x, z)
	if k < 0:
		return "calculando…" if terrain_cls.is_empty() else "fuera del mapa"
	return str(terrain_meta.get("short", {}).get(str(k), "?"))


# ------------------------------------------------------------------ cada frame
func tick(player_pos: Vector3, head_basis: Basis, delta: float) -> void:
	if _terrain_pid > 0 and not OS.is_process_running(_terrain_pid):
		_terrain_pid = -1
		if not _read_terrain(_terrain_prefix) and not world_mode:
			_load_terrain_map()
	if world_mode:
		_ensure_terrain_window(player_pos)
	if _busy_pid > 0 and not OS.is_process_running(_busy_pid):
		_finish_request()
	guide.update_player(player_pos, head_basis)
	_emit_t += delta
	if has_geo and _emit_t >= EMIT_EVERY:
		_emit_t = 0.0
		var ll := local_to_latlon(player_pos.x, player_pos.z)
		if absf(ll[0] - _last_emit[0]) + absf(ll[1] - _last_emit[1]) > 1e-7:
			_last_emit = ll
			player_position_changed.emit(ll[0], ll[1])


func hud_lines(player_pos: Vector3) -> String:
	var s := "\nTerreno: %s" % terrain_name_at(player_pos.x, player_pos.z)
	if has_geo:
		var ll := local_to_latlon(player_pos.x, player_pos.z)
		s += " · lat %.5f lon %.5f" % [ll[0], ll[1]]
	if bool(terrain_meta.get("is_proxy", false)):
		s += " (estimado: proxy)"
	s += guide.hud_line()
	if status != "" and (Time.get_ticks_msec() / 1000.0 < status_until or _busy_pid > 0):
		s += "\n" + status
	s += "\nL: destino lat/lon · P: puntos guardados · R: recalcular · C: borrar ruta · VR: agarre izq = menu"
	return s

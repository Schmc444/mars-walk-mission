extends Node3D
class_name GuidePath
## VR walking guide for Mars Route Walker.
## Reads guide_path.json (written by mars_route.py) and draws:
##   - chevrons on the ground every `spacing` m, coloured by risk (green ok, amber slope, red rocky/steep)
##   - a beacon + label at the goal
##   - a floating arrow in front of the player that points to the next point of the route
##   - tramos sobre duna / arena suelta en color propio (morado)
## Call `update_player(player_pos, head_basis)` every frame and show `hud_line()` in the HUD.
## `set_route(json_path)` recarga una ruta nueva en ejecución (borra la anterior); acepta guide_path.json o el sobre de plan_route.

@export var json_path := "res://patch_793/guide_path.json"
@export var condition := "normal"      # used when the json holds several conditions
@export var spacing := 1.5             # m between chevrons
@export var lookahead := 4.0           # m ahead along the route the floating arrow points to
@export var off_route_warn := 3.0      # m: warn when the player is farther than this from the route

const COL_OK := Color(0.2, 1.0, 0.55)
const COL_SLOPE := Color(1.0, 0.75, 0.1)
const COL_RISK := Color(1.0, 0.25, 0.2)
const COL_DUNE := Color(0.8, 0.4, 1.0)
const T_DUNE := 2                       # código de terrain_classes.ARENA_DUNA
const T_BLOCKS := 3                     # BLOQUES

var data: Dictionary
var pts: Array[Vector3] = []
var cum: PackedFloat32Array = []        # cumulative distance along the route
var eta: PackedFloat32Array = []
var slope: PackedFloat32Array = []
var terrain: PackedInt32Array = []
var _last_i := 0
var _arrow: MeshInstance3D
var _goal_label: Label3D
var _state := {}
var goal_name := ""                     # nombre del destino para la baliza (opcional)
var hud_terrain := true                 # false si otro nodo (RouteUI) ya muestra el terreno bajo el jugador
var _chevrons: MultiMeshInstance3D
var _goal_mesh: MeshInstance3D


func _ready() -> void:
	if FileAccess.file_exists(json_path):
		set_route(json_path)


func has_route() -> bool:
	return not pts.is_empty()


func clear_route() -> void:
	## Borra la línea, la baliza y la flecha de la ruta actual (si hay).
	for n in [_chevrons, _goal_mesh, _goal_label, _arrow]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_chevrons = null
	_goal_mesh = null
	_goal_label = null
	_arrow = null
	pts = []
	cum = PackedFloat32Array()
	eta = PackedFloat32Array()
	slope = PackedFloat32Array()
	terrain = PackedInt32Array()
	data = {}
	_state = {}
	_last_i = 0


func set_route(path: String, dest_name := "") -> bool:
	## Carga una ruta nueva sin reiniciar la escena. Devuelve false (y deja la ruta anterior borrada) si el archivo no sirve.
	clear_route()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not parsed is Dictionary:
		push_error("guide_path: cannot read " + path)
		return false
	if parsed.has("route") and parsed["route"] is Dictionary:       # sobre de plan_route: {ok, route, ...}
		parsed = parsed["route"]
	data = parsed if parsed.has("points") else parsed.get(condition, parsed.values()[0])
	if not data.has("points") or data["points"].size() < 2:
		push_error("guide_path: ruta vacia en " + path)
		data = {}
		return false
	json_path = path
	goal_name = dest_name
	var d := 0.0
	for i in data["points"].size():
		var p: Array = data["points"][i]
		var v := Vector3(p[0], p[1], p[2])
		if i > 0:
			d += v.distance_to(pts[i - 1])
		pts.append(v)
		cum.append(d)
		eta.append(float(data["eta_s"][i]))
		slope.append(float(data["slope_deg"][i]))
		terrain.append(int(data["terrain"][i]))
	_build_chevrons()
	_build_goal()
	_build_arrow()
	return true


func _risk_color(i: int) -> Color:
	if terrain[i] == T_BLOCKS or slope[i] >= 20.0:
		return COL_RISK
	if terrain[i] == T_DUNE:
		return COL_DUNE
	if slope[i] >= 15.0:
		return COL_SLOPE
	return COL_OK


func _point_at(dist: float) -> int:
	# index of the first point at or beyond `dist` metres along the route
	var lo := 0
	var hi := cum.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if cum[mid] < dist:
			lo = mid + 1
		else:
			hi = mid
	return lo


func _build_chevrons() -> void:
	# one flat "V" (two thin boxes) per chevron, drawn with a MultiMesh so hundreds cost one draw call
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		var arm := BoxMesh.new()
		arm.size = Vector3(0.06, 0.015, 0.38)
		var xf := Transform3D(Basis(Vector3.UP, side * 0.6), Vector3(side * 0.11, 0, 0.1))
		st.append_from(arm, 0, xf)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.4, 0.2)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var total := cum[cum.size() - 1]
	var count := int(total / spacing)
	mm.instance_count = count
	for k in count:
		var i := _point_at(k * spacing)
		var j := mini(i + 1, pts.size() - 1)
		var dir := (pts[j] - pts[maxi(i - 1, 0)])
		dir.y = 0
		if dir.length() < 0.01:
			dir = Vector3.FORWARD
		var b := Basis.looking_at(dir.normalized(), Vector3.UP)  # -Z points along the route: the V tip points forward
		mm.set_instance_transform(k, Transform3D(b, pts[i] + Vector3.UP * 0.05))
		mm.set_instance_color(k, _risk_color(i))
	var mi := MultiMeshInstance3D.new()
	_chevrons = mi
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_goal() -> void:
	var g := pts[pts.size() - 1]
	var c := CylinderMesh.new()
	c.top_radius = 0.05
	c.bottom_radius = 0.05
	c.height = 6.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0.3, 0.2, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var m := MeshInstance3D.new()
	m.mesh = c
	m.material_override = mat
	m.position = g + Vector3.UP * 3.0
	_goal_mesh = m
	add_child(m)
	_goal_label = Label3D.new()
	_goal_label.font_size = 56
	_goal_label.pixel_size = 0.006
	_goal_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_goal_label.no_depth_test = true
	_goal_label.position = g + Vector3.UP * 6.5
	add_child(_goal_label)


func _build_arrow() -> void:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.07
	cone.height = 0.22
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = COL_OK
	mat.no_depth_test = true
	_arrow = MeshInstance3D.new()
	_arrow.mesh = cone
	_arrow.material_override = mat
	add_child(_arrow)


## Call every frame. player_pos: feet position (XROrigin3D / camera projected to the ground).
## head_basis: camera global basis, used to place the arrow in front of the eyes.
func update_player(player_pos: Vector3, head_basis: Basis) -> Dictionary:
	if pts.is_empty() or _arrow == null:
		return {}
	# nearest route point, searching a window around the last one (cheap and avoids jumping to a far branch)
	var best := INF
	var lo := maxi(_last_i - 30, 0)
	var hi := mini(_last_i + 60, pts.size() - 1)
	for k in range(lo, hi + 1):
		var dd := Vector2(pts[k].x - player_pos.x, pts[k].z - player_pos.z).length_squared()
		if dd < best:
			best = dd
			_last_i = k
	if sqrt(best) > off_route_warn:      # lost track (teleport, big detour): scan the whole route once
		for k in pts.size():
			var dd := Vector2(pts[k].x - player_pos.x, pts[k].z - player_pos.z).length_squared()
			if dd < best:
				best = dd
				_last_i = k
	var i := _last_i
	var off := sqrt(best)
	var target_i := _point_at(cum[i] + lookahead)
	var target := pts[target_i]
	if off > off_route_warn:
		target = pts[i]                   # off the route: point back to the nearest route point first
	# floating arrow 1 m ahead of the eyes, 0.5 m below them, pointing to the target
	var fwd := -head_basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var head := player_pos + Vector3.UP * 1.6
	_arrow.global_position = head + fwd * 1.0 + Vector3.DOWN * 0.5
	var to := target - _arrow.global_position
	to.y = 0
	if to.length() > 0.01:
		_arrow.global_basis = Basis.looking_at(to.normalized(), Vector3.UP) * Basis(Vector3.RIGHT, -PI / 2)  # cone tip along -Z
	(_arrow.material_override as StandardMaterial3D).albedo_color = COL_RISK if off > off_route_warn else _risk_color(target_i)
	var remaining := cum[cum.size() - 1] - cum[i]
	var eta_left := eta[eta.size() - 1] - eta[i]
	var warn := ""
	for w in data["warnings"]:
		var wi := int(w["i"])
		if wi >= i and cum[wi] - cum[i] < 10.0:
			warn = "%s (en %.0f m)" % [w["msg"], cum[wi] - cum[i]]
			break
	_goal_label.text = "%s  %.0f m · %s" % [goal_name if goal_name != "" else "META", remaining, _fmt_time(eta_left)]
	_state = {"index": i, "off_route_m": off, "remaining_m": remaining, "eta_s": eta_left,
		"slope_here": slope[i], "terrain_here": str(data["terrain_names"].get(str(terrain[i]), "?")), "terrain_code": terrain[i], "warning": warn,
		"arrived": remaining < 1.5}
	return _state


func hud_line() -> String:
	if _state.is_empty():
		return ""
	if _state["arrived"]:
		return "\nRUTA: ¡llegaste a la meta!"
	var s := "\nRUTA (%s): faltan %.0f m · %s" % [condition, _state["remaining_m"], _fmt_time(_state["eta_s"])]
	if hud_terrain:
		s += " · terreno: %s" % _state["terrain_here"]
	if _state["off_route_m"] > off_route_warn:
		s += "\n⚠ Fuera de ruta (%.0f m) - sigue la flecha" % _state["off_route_m"]
	elif _state["warning"] != "":
		s += "\n⚠ " + _state["warning"]
	return s


func _fmt_time(sec: float) -> String:
	return "%d min %02d s" % [int(sec) / 60, int(sec) % 60] if sec >= 60 else "%d s" % int(sec)

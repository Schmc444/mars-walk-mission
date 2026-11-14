extends Node3D
# Menu flotante para VR sobre RouteUI: destinos guardados, recalcular, borrar ruta.
# Abrir/cerrar: agarre (grip) o click del stick de la mano izquierda. Apuntar: mano derecha. Elegir: gatillo derecho.

const W := 0.8
const ROW := 0.075
const DIST := 1.1

var ui: Node
var core: Node
var open := false
var panel: Node3D
var buttons: Array = []     # {mesh, rect: Rect2, fn: Callable, mat}
var status_label: Label3D
var ray: MeshInstance3D
var hover := -1
var grip_down := false


func setup(route_ui: Node, core_node: Node) -> void:
	ui = route_ui
	core = core_node
	ray = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.004, 0.004, 1.0)
	ray.mesh = bm
	ray.material_override = _mat(Color(1.0, 0.9, 0.3))
	ray.visible = false
	add_child(ray)
	if core.left != null:
		core.left.button_pressed.connect(func(n: String):
			print("vr_menu: izq boton ", n)
			if n in ["primary_click", "menu_button", "select_button"]:
				toggle())
	if core.right != null:
		core.right.button_pressed.connect(func(n: String):
			print("vr_menu: der boton ", n)
			if open and n == "trigger_click":
				_click())


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = 100
	return m


func toggle() -> void:
	if open:
		close()
	else:
		_open()


func close() -> void:
	open = false
	ui.menu_open = false
	ray.visible = false
	if panel:
		panel.queue_free()
		panel = null
	buttons.clear()


func _open() -> void:
	open = true
	ui.menu_open = true
	var head: Transform3D = core.cam.global_transform
	var f := -head.basis.z
	f.y = 0.0
	f = f.normalized() if f.length() > 0.01 else Vector3.FORWARD
	panel = Node3D.new()
	add_child(panel)
	panel.global_transform = Transform3D(Basis.looking_at(f, Vector3.UP), head.origin + f * DIST + Vector3(0, -0.05, 0))
	_build()


func _quad(size: Vector2, pos: Vector3, col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	m.mesh = q
	m.material_override = _mat(col)
	m.position = pos
	panel.add_child(m)
	return m


func _text(t: String, pos: Vector3, px: float, col: Color, parent: Node3D) -> Label3D:
	var l := Label3D.new()
	l.text = t
	l.pixel_size = px
	l.modulate = col
	l.no_depth_test = true
	l.render_priority = 101
	l.outline_size = 0
	l.position = pos
	parent.add_child(l)
	return l


func _add_button(label: String, y: float, fn: Callable, col := Color(0.18, 0.2, 0.28)) -> void:
	var h := ROW * 0.9
	var m := _quad(Vector2(W - 0.06, h), Vector3(0, y, 0.004), col)
	_text(label, Vector3(0, 0, 0.003), 0.0007, Color.WHITE, m)
	buttons.append({"mesh": m, "rect": Rect2(-(W - 0.06) / 2, y - h / 2, W - 0.06, h), "fn": fn, "col": col})


func _build() -> void:
	ui._load_waypoints()
	var rows := 0
	var items: Array = []
	for w in ui.waypoints:
		if ui._waypoint_usable(w):
			items.append(w)
	rows = items.size() + 4
	var H := rows * ROW + 0.12
	_quad(Vector2(W, H), Vector3(0, 0, 0), Color(0.05, 0.06, 0.09, 0.96))
	var y := H / 2 - 0.05
	_text("RUTA A DESTINO", Vector3(0, y, 0.002), 0.0009, Color(1, 0.8, 0.4), panel)
	y -= ROW
	status_label = _text("", Vector3(0, y, 0.002), 0.0005, Color(0.7, 0.9, 1.0), panel)
	y -= ROW * 0.8
	for w in items:
		var id: String = str(w["id"])
		var pick := func():
			var err: String = ui.select_waypoint(id)
			if err == "":
				close()
			else:
				ui._say(err, 6.0)
		_add_button(str(w["nombre"]).left(40), y, pick, Color(0.15, 0.3, 0.35))
		y -= ROW
	_add_button("Recalcular ruta", y, func(): ui.replan())
	y -= ROW
	_add_button("Borrar ruta", y, func(): ui.clear_route())
	y -= ROW
	_add_button("Cerrar menu", y, func(): close(), Color(0.35, 0.18, 0.18))


func _aim() -> Variant:
	if core.right == null:
		return null
	var xf: Transform3D = core.right.global_transform
	var o := xf.origin
	var d := -xf.basis.z
	var n: Vector3 = panel.global_basis.z
	var den := d.dot(n)
	if absf(den) < 1e-4:
		return null
	var t := (panel.global_position - o).dot(n) / den
	if t < 0.0:
		return null
	return {"local": panel.global_transform.affine_inverse() * (o + d * t), "t": t, "o": o, "d": d}


func _process(_dt: float) -> void:
	if core.left != null:
		var g: float = core.left.get_float("grip")
		if g > 0.85 and not grip_down:
			grip_down = true
			toggle()
		elif g < 0.4:
			grip_down = false
	if not open or panel == null:
		return
	var s: String = ui.status if (ui.status != "" and Time.get_ticks_msec() / 1000.0 < ui.status_until) or ui._busy_pid > 0 else "Apunta con la derecha, gatillo para elegir"
	status_label.text = s.left(70)
	var a = _aim()
	hover = -1
	if a != null:
		ray.visible = true
		var d: Vector3 = a["d"]
		var len: float = minf(a["t"], 3.0)
		var o: Vector3 = a["o"]
		ray.global_transform = Transform3D(Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT) * Basis.from_scale(Vector3(1, 1, len)), o + d * len * 0.5)
		var p := Vector2(a["local"].x, a["local"].y)
		for i in buttons.size():
			if buttons[i]["rect"].has_point(p):
				hover = i
	else:
		ray.visible = false
	for i in buttons.size():
		var c: Color = buttons[i]["col"]
		buttons[i]["mesh"].material_override.albedo_color = c.lightened(0.35) if i == hover else c


func _click() -> void:
	if hover >= 0:
		buttons[hover]["fn"].call()

extends Node3D
# Capa "ruta": el Perseverance sobre la ruta real. Paso 1: el rover sigue core.ride_s y queda estacionado al bajarse.

const ROVER_MODEL := "res://models/perseverance.glbd"

var world: WorldStreamer
var core: Node
var rover: Node3D
var rover_s := 0.0

const MAX_V := 50.0 / 3.6        # 50 km/h en m/s
const MAX_ANG := deg_to_rad(60.0)
const SEAT_Y := 1.0              # altura de la cubierta (el modelo mide 1.85 m con el mastil)
const DESKTOP_EYE := 0.9         # ojos sobre la cubierta en escritorio (sentado)
var lever_pos := Vector3(0.4, SEAT_Y + 0.3, -0.55)   # en el marco del rover (x der., y arriba, -z adelante)
const ROVER_LOD := 3          # nivel de detalle del modelo (mayor = menos triangulos)
const LEVER_LEN := 0.45

var lever := 0.0                 # -1..1, fraccion de la velocidad maxima
var pivot: Node3D
var knob: Node3D
var speed_label: Label3D
var grabbing := false
var hand_marks: Array[MeshInstance3D] = []
var pose_try := 0
var pose_clock := 0.0
const POSES: Array[StringName] = [&"grip", &"aim", &"default", &"grip_pose", &"aim_pose", &"default_pose"]


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	rover = _load_rover()
	if rover:
		rover_s = core.ride_s
		_place()
		_build_lever()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lever="):
			lever = clampf(float(a.get_slice("=", 1)), -1.0, 1.0)
	for hc: XRController3D in [core.left, core.right]:
		var m := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.03
		sm.height = 0.06
		m.mesh = sm
		m.material_override = _mat(Color(0.2, 0.7, 1.0))
		hc.add_child(m)
		hand_marks.append(m)


func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.keycode:
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			lever = clampf(lever + 0.1, -1.0, 1.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			lever = clampf(lever - 0.1, -1.0, 1.0)
		KEY_SPACE:
			lever = 0.0


func _process(delta: float) -> void:
	if rover == null or not world.is_ready():
		return
	if core.riding:
		_grab_input()
		if absf(lever) > 0.001:
			# la palanca manda: se reemplaza la velocidad que ya aplico el core este cuadro
			core.ride_s = clampf(core.ride_s + (lever * MAX_V - core.world_speed) * delta, 0.0, world.route_length())
		rover_s = core.ride_s
	_place()
	if core.riding:
		core.origin.position = rover.position + rover.basis.y * SEAT_Y
		if not core.in_xr:
			core.cam.position.y = DESKTOP_EYE
	elif not core.in_xr:
		core.cam.position.y = 1.6
	_update_lever()
	if "--ruta-face" in OS.get_cmdline_user_args():
		var f := -rover.global_transform.basis.z
		core.yaw = atan2(-f.x, -f.z)


func _place() -> void:
	var p := world.route_pos(rover_s)
	var a := world.route_pos(maxf(rover_s - 1.5, 0.0))
	var b := world.route_pos(minf(rover_s + 1.5, world.route_length()))
	var fwd := Vector3(b.x - a.x, 0.0, b.y - a.y)
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	var gx := (world.height_at(p.x + 1.5, p.y) - world.height_at(p.x - 1.5, p.y)) / 3.0
	var gz := (world.height_at(p.x, p.y + 1.5) - world.height_at(p.x, p.y - 1.5)) / 3.0
	var up := Vector3(-gx, 1.0, -gz).normalized()
	var right := fwd.cross(up).normalized()
	var f2 := up.cross(right)
	var low := INF
	for o: Vector2 in [Vector2(0, 0), Vector2(1.3, 1.5), Vector2(-1.3, 1.5), Vector2(1.3, -1.5), Vector2(-1.3, -1.5)]:
		var q: Vector3 = Vector3(p.x, 0, p.y) + right * o.x + f2 * o.y
		low = minf(low, world.height_at(q.x, q.z))
	rover.transform = Transform3D(Basis(right, up, -f2), Vector3(p.x, low + 0.02, p.y))


func _load_rover() -> Node3D:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(FileAccess.get_file_as_bytes(ROVER_MODEL), "", st) != OK:
		push_warning("ruta: no cargo el modelo del rover")
		return null
	var scene := doc.generate_scene(st)
	var holder := Node3D.new()
	holder.name = "Perseverance"
	holder.add_child(scene)
	add_child(holder)
	_simplify(holder)
	var acc: Array = [null]
	_aabb(holder, holder, acc)
	var bb: AABB = acc[0]
	scene.basis = Basis(Vector3.UP, PI)   # el modelo mira hacia +z; el rover avanza hacia -z
	scene.position = Vector3(bb.position.x + bb.size.x / 2.0, -bb.position.y, bb.position.z + bb.size.z / 2.0)
	return holder


func _aabb(n: Node, root: Node3D, acc: Array) -> void:
	if n is MeshInstance3D:
		var a: AABB = (root.global_transform.affine_inverse() * n.global_transform) * (n as MeshInstance3D).get_aabb()
		acc[0] = a if acc[0] == null else (acc[0] as AABB).merge(a)
	for ch in n.get_children():
		_aabb(ch, root, acc)


func _build_lever() -> void:
	pivot = Node3D.new()
	add_child(pivot)
	var base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.05
	bm.bottom_radius = 0.07
	bm.height = 0.06
	base.mesh = bm
	base.material_override = _mat(Color(0.15, 0.15, 0.17))
	pivot.add_child(base)
	var stick := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.012
	cm.bottom_radius = 0.015
	cm.height = LEVER_LEN
	stick.mesh = cm
	stick.position.y = LEVER_LEN / 2.0
	stick.material_override = _mat(Color(0.7, 0.7, 0.72))
	pivot.add_child(stick)
	knob = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.035
	sm.height = 0.07
	knob.mesh = sm
	knob.position.y = LEVER_LEN
	knob.material_override = _mat(Color(0.9, 0.2, 0.1))
	pivot.add_child(knob)
	speed_label = Label3D.new()
	speed_label.font_size = 48
	speed_label.pixel_size = 0.0007
	speed_label.no_depth_test = true
	speed_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	speed_label.position = Vector3(0, LEVER_LEN + 0.12, 0)
	pivot.add_child(speed_label)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 10
	return m


func _update_lever() -> void:
	lever_pos = Vector3(0.3, SEAT_Y + 0.6, -0.4) if core.in_xr else Vector3(0.4, SEAT_Y + 0.3, -0.55)
	pivot.visible = core.riding
	if not core.riding:
		return
	pivot.global_transform = rover.global_transform * Transform3D(Basis(Vector3.RIGHT, -lever * MAX_ANG), lever_pos)
	speed_label.text = "%+.0f km/h" % (lever * 50.0)


func _grab_input() -> void:
	if not core.in_xr or core.right == null:
		return
	var g: float = core.right.get_float("grip")
	var hand: Vector3 = core.right.global_position
	if not grabbing:
		if g > 0.7 and hand.distance_to(knob.global_position) < 0.25:
			grabbing = true
	elif g < 0.4:
		grabbing = false
	if grabbing:
		var d: Vector3 = rover.global_transform.affine_inverse() * hand - lever_pos
		lever = clampf(atan2(-d.z, d.y) / MAX_ANG, -1.0, 1.0)


func _simplify(n: Node) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		var mi := n as MeshInstance3D
		var src: ArrayMesh = mi.mesh
		var im := ImporterMesh.new()
		for i in src.get_surface_count():
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(i), [], {}, src.surface_get_material(i))
		im.generate_lods(25.0, 60.0, [])
		var out := ArrayMesh.new()
		for i in im.get_surface_count():
			var arr := im.get_surface_arrays(i)
			var nl := im.get_surface_lod_count(i)
			if nl > 0:
				arr[Mesh.ARRAY_INDEX] = im.get_surface_lod_indices(i, mini(ROVER_LOD, nl) - 1)
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(i, im.get_surface_material(i))
		mi.mesh = out
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for ch in n.get_children():
		_simplify(ch)

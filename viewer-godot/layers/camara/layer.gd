extends Node3D
# Capa camara: una camara virtual con mirilla, independiente de la cabeza.
#  - VR: la camara es tu mano derecha (apuntas con ella); desktop: es la vista libre.
#  - Se dibuja la camara, un rayo y una mirilla donde apunta.
#  - Graba SU trayecto (no tu cabeza) relativo al rover: --cam-rec, o tecla R en desktop.
#  - Reproduce/renderiza ese trayecto: --cam-play=<json> [--cam-from=s] [--cam-fps=30] [--cam-pitch=grados]
#    [--cam-level] [--cam-smooth=k] [--cam-fov=grados]. Sirve con cualquier rama, sin la ruta del casco.
# Si la capa ruta esta presente (capa_ruta.rover), el trayecto se guarda en el marco del rover; si no, en el mundo.

const TILT_DEG := 0.0            # inclinacion de la mano: ajustar si "apunta" distinto a tu muneca
const REACH := 400.0

var world: WorldStreamer
var core: Node
var rig: Node3D
var ray: MeshInstance3D
var reticle: MeshInstance3D
var tilt := TILT_DEG

var rec_on := false
var rec_data: Array = []
var rec_t0 := 0
var rec_clock := 0.0
var rec_path := ""

var play_data: Array = []
var play_fps := 30.0
var play_from := 0.0
var play_frame := -1
var play_started := false
var pitch_off := 0.0
var level := false
var smooth := 0.0
var fov := 0.0
var prev_xf := Transform3D.IDENTITY


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	process_priority = -100
	_build_rig()
	for a in OS.get_cmdline_user_args():
		if a == "--cam-rec":
			_rec_toggle.call_deferred()
		elif a.begins_with("--cam-play="):
			var j = JSON.parse_string(FileAccess.get_file_as_string(a.get_slice("=", 1)))
			if j != null:
				play_data = j
		elif a.begins_with("--cam-from="):
			play_from = float(a.get_slice("=", 1))
		elif a.begins_with("--cam-fps="):
			play_fps = float(a.get_slice("=", 1))
		elif a.begins_with("--cam-pitch="):
			pitch_off = float(a.get_slice("=", 1))
		elif a.begins_with("--cam-smooth="):
			smooth = float(a.get_slice("=", 1))
		elif a.begins_with("--cam-fov="):
			fov = float(a.get_slice("=", 1))
		elif a.begins_with("--cam-tilt="):
			tilt = float(a.get_slice("=", 1))
		elif a == "--cam-level":
			level = true
	if not play_data.is_empty():
		rig.visible = false
		ray.visible = false
		reticle.visible = false
		print("camara: reproduciendo ", play_data.size(), " muestras")
	if play_data.is_empty():
		RenderingServer.frame_pre_draw.connect(_late)
	else:
		var t := Node.new()
		t.set_script(load("res://layers/camara/tardio.gd"))
		t.capa = self
		t.process_priority = 1000
		add_child(t)
	if core.right != null:
		core.right.button_pressed.connect(func(n: String): if n == "trigger_click" and not (core.get("route_ui") != null and core.route_ui.menu_open): _rec_toggle())
	if core.left != null:
		core.left.button_pressed.connect(func(n: String): if n == "by_button": _toggle_visible())
	if "--nocam" in OS.get_cmdline_user_args():
		_toggle_visible()



func _toggle_visible() -> void:
	if not play_data.is_empty():
		return
	var v := not rig.visible
	rig.visible = v
	ray.visible = v
	reticle.visible = v


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_R:
		_rec_toggle()


func _mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.no_depth_test = true
	m.render_priority = 100
	return m


func _build_rig() -> void:
	rig = Node3D.new()
	add_child(rig)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.05, 0.09)
	body.mesh = bm
	body.material_override = _mat(Color(0.15, 0.15, 0.17))
	rig.add_child(body)
	var lens := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.02
	cm.height = 0.04
	lens.mesh = cm
	lens.rotation = Vector3(PI / 2, 0, 0)
	lens.position = Vector3(0, 0, -0.065)
	lens.material_override = _mat(Color(0.3, 0.6, 1.0))
	rig.add_child(lens)
	ray = MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(0.004, 0.004, 1.0)
	ray.mesh = rm
	ray.material_override = _mat(Color(0.4, 1.0, 0.4, 1.0))
	add_child(ray)
	reticle = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	reticle.mesh = tm
	reticle.material_override = _mat(Color(0.4, 1.0, 0.4))
	add_child(reticle)


func _rover() -> Node3D:
	var r = core.get_node_or_null("capa_ruta")
	return r.rover if r != null and r.get("rover") != null else null


func _base() -> Transform3D:
	var r := _rover()
	return r.global_transform if r != null else Transform3D.IDENTITY


func _source_xf() -> Transform3D:
	if core.in_xr and core.right != null:
		return core.right.global_transform * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(tilt)), Vector3.ZERO)
	return core.cam.global_transform


func _hit(xf: Transform3D) -> Vector3:
	var o := xf.origin
	var d := -xf.basis.z
	var last := 0.0
	var t := 0.5
	while t < REACH:
		var p := o + d * t
		if p.y < world.height_at(p.x, p.z):
			var lo := last
			var hi := t
			for i in 8:
				var m := (lo + hi) * 0.5
				var q := o + d * m
				if q.y < world.height_at(q.x, q.z):
					hi = m
				else:
					lo = m
			return o + d * hi
		last = t
		t += 1.0 if t < 40.0 else 4.0
	return o + d * REACH


func _show(xf: Transform3D) -> void:
	rig.global_transform = xf
	var h := _hit(xf)
	var d := xf.origin.distance_to(h)
	var mid := xf.origin.lerp(h, 0.5)
	var dir := (h - xf.origin).normalized()
	var fb := Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
	ray.global_transform = Transform3D(fb * Basis.from_scale(Vector3(1, 1, d)), mid)
	var s := maxf(0.06 * d * 0.1, 0.03)
	reticle.global_transform = Transform3D(fb * Basis(Vector3.RIGHT, PI / 2) * Basis.from_scale(Vector3(s, s, s)), h)


func _process(_d: float) -> void:
	if play_data.is_empty() or not world.is_ready():
		return
	if not play_started:
		play_started = true
		play_frame = int(play_from * play_fps)
		if core.get("hud") != null:
			core.hud.visible = false
		print("camara: PLAY_START frame ", Engine.get_frames_drawn())
	var r := _row()
	core.ride_s = r[0]
	core.riding = r[1] == 1


func _late() -> void:
	if world == null or not world.is_ready():
		return
	if not play_data.is_empty():
		if not play_started:
			return
		var r := _row()
		var xf: Transform3D = _base() * r[2]
		if level:
			var f := -xf.basis.z
			f.y = 0.0
			if f.length() > 0.001:
				var up := Vector3.UP
				var pit := asin(clampf((-xf.basis.z).y, -1.0, 1.0))
				xf.basis = Basis.looking_at(f.normalized(), up) * Basis(Vector3.RIGHT, pit)
		if pitch_off != 0.0:
			xf.basis = xf.basis * Basis(Vector3.RIGHT, deg_to_rad(pitch_off))
		if smooth > 0.0 and play_frame > int(play_from * play_fps):
			var k := 1.0 - exp(-smooth / play_fps)
			xf = prev_xf.interpolate_with(xf, k)
		prev_xf = xf
		core.cam.global_transform = xf
		if fov > 0.0:
			core.cam.fov = fov
		play_frame += 1
		if play_frame / play_fps > play_data[play_data.size() - 1][0]:
			print("camara: reproduccion terminada")
			get_tree().quit()
		return
	var src := _source_xf()
	_show(src)
	if rec_on:
		var l: Transform3D = _base().affine_inverse() * src
		var q := l.basis.get_rotation_quaternion()
		rec_data.append([snappedf((Time.get_ticks_msec() - rec_t0) / 1000.0, 0.001), snappedf(core.ride_s, 0.01), 1 if core.riding else 0,
			snappedf(l.origin.x, 0.001), snappedf(l.origin.y, 0.001), snappedf(l.origin.z, 0.001),
			snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001), snappedf(q.w, 0.0001)])
		rec_clock += get_process_delta_time()
		if rec_clock > 5.0:
			rec_clock = 0.0
			_rec_save()


func _row() -> Array:
	var t := maxf(play_frame, 0) / play_fps
	var lo := 0
	var hi := play_data.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if play_data[mid][0] < t:
			lo = mid + 1
		else:
			hi = mid
	var b: Array = play_data[lo]
	var a: Array = play_data[maxi(lo - 1, 0)]
	var w := clampf((t - a[0]) / maxf(b[0] - a[0], 1e-6), 0.0, 1.0)
	var qs := Quaternion(a[6], a[7], a[8], a[9]).slerp(Quaternion(b[6], b[7], b[8], b[9]), w)
	var pos := Vector3(lerpf(a[3], b[3], w), lerpf(a[4], b[4], w), lerpf(a[5], b[5], w))
	return [lerpf(a[1], b[1], w), b[2], Transform3D(Basis(qs), pos)]


func _exit_tree() -> void:
	if rec_on:
		_rec_save()


func _rec_toggle() -> void:
	rec_on = not rec_on
	reticle.material_override.albedo_color = Color(1, 0.15, 0.15) if rec_on else Color(0.4, 1.0, 0.4)
	ray.material_override.albedo_color = reticle.material_override.albedo_color
	if rec_on:
		rec_data = []
		rec_t0 = Time.get_ticks_msec()
		var dir := OS.get_environment("HOME") + "/mars/rec"
		DirAccess.make_dir_recursive_absolute(dir)
		rec_path = "%s/cam_%s.json" % [dir, Time.get_datetime_string_from_system().replace(":", "-")]
		print("camara: GRABANDO -> ", rec_path)
	else:
		_rec_save()
		print("camara: grabacion guardada, muestras=", rec_data.size())


func _rec_save() -> void:
	var f := FileAccess.open(rec_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rec_data))

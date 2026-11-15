extends Node3D
# Mars Route Walker viewer: loads a patch folder (heightmap.f32, ortho.png, route_local.json, meta.json).

var PATCH := "res://patch/"
const STEP := 0.5
const LIMIT := 45.0 # walkable half-width in m (a ~90 m x 90 m square); the "100 m2" request is read as ~100 m across
const MARS_R := 3396190.0
const FAR_ALBEDO := Color(0.2, 0.14, 0.1)
const ROVER_MODEL := "res://models/perseverance.glbd"
const HAZARD_DEG := 15.0

var scene: Dictionary # scene.json (see docs/SCENE_FORMAT.md)
var meta: Dictionary
var n := 101
var half := 50.0
var heights := PackedFloat32Array()
var origin: XROrigin3D
var cam: XRCamera3D
var left: XRController3D
var right: XRController3D
var in_xr := false
var giro_v := 0.0
const WALK_SPEED := 1.9
const GIRO_MAX_GRADOS_S := 55.0
const GIRO_ZONA_MUERTA := 0.2
const GIRO_SUAVIZADO := 7.0
var yaw := 0.0
var pitch := 0.0
var terrain_mat: ShaderMaterial
var hazard_on := false
var hud: Label
var sun_dir_xz := Vector2(-0.64, -0.76)
var route_ui: Node # route/route_ui.gd: destino por lat/lon, puntos guardados y guía de ruta (solo modo parche)


func layer_entry(id: String) -> Dictionary:
	for e in scene["layers"]:
		if e["id"] == id:
			return e
	return {}


func ring_gain_at_patch() -> Dictionary:
	# brightness the 3 km ring texture has around the origin (relative to its mean), so the patch can match it
	var e := layer_entry("ring_3km")
	var out := {"gain": 1.0, "stats": false}
	if e.is_empty() or not e.has("texture"):
		return out
	var timg := Image.load_from_file(ProjectSettings.globalize_path(PATCH + str(e["texture"])))
	if timg == null:
		return out
	timg.convert(Image.FORMAT_L8)
	var d8 := timg.get_data()
	var sum := 0.0
	for i in range(0, d8.size(), 7):
		sum += d8[i]
	var mean := maxf(sum / (d8.size() / 7.0) / 255.0, 0.01)
	var w := timg.get_width()
	var r := maxi(int(half / float(e["half_m"]) * w * 2.0), 4)
	var csum := 0.0
	var n := 0
	for y in range(w / 2 - r, w / 2 + r):
		for x in range(w / 2 - r, w / 2 + r):
			csum += timg.get_pixel(x, y).r
			n += 1
	out["gain"] = pow(clampf(csum / n / mean, 0.4, 1.7), 1.25)
	out["stats"] = true
	return out


var W: WorldStreamer
var world_mode := false
const DEFAULT_START_SOL := 1063
var ride_s := 0.0
var riding := true
var world_speed := 0.0


func _ready() -> void:
	var peb_layers := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pebbles="):
			peb_layers = clampi(int(a.get_slice("=", 1)), 0, 3)
	RenderingServer.global_shader_parameter_add("pebble_layers", RenderingServer.GLOBAL_VAR_TYPE_INT, peb_layers)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--world="):
			_ready_world(a.substr(8))
			return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--patch="):
			PATCH = "res://" + a.substr(8) + "/"
	scene = JSON.parse_string(FileAccess.get_file_as_string(PATCH + "scene.json"))
	var terr := layer_entry("terrain")
	meta = {"samples": terr["samples"], "waypoint": scene["origin"]}
	n = int(meta["samples"])
	half = (n - 1) * 0.5
	var f := FileAccess.open(PATCH + terr["file"], FileAccess.READ)
	heights = f.get_buffer(f.get_length()).to_float32_array()
	_environment()
	add_child(_terrain())
	_farfield()
	_rocks()
	_route()
	_setup_player()
	_setup_xr()
	_rover()
	var p := Vector3(0, 0, 8)
	origin.position = Vector3(p.x, height_at(p.x, p.z), p.z)
	yaw = 0.0
	_cli_camera()
	_hud()
	_route_setup()
	if "--test" in OS.get_cmdline_user_args():
		print("TEST ok n=%d h(0,0)=%.2f h(30,0)=%.2f" % [n, height_at(0, 0), height_at(30, 0)])
		get_tree().quit()


var shot_path := ""
var shot_frames := 0
var shot_ready_frames := 0


func _ready_world(dir: String) -> void:
	world_mode = true
	var args := OS.get_cmdline_user_args()
	_environment()
	W = WorldStreamer.new()
	add_child(W)
	W.setup(dir)
	_setup_player()
	_setup_xr()
	_hud()
	_load_layers(args)
	_route_setup_world()
	if not ("--norings" in args):
		var fr := FarRings.new()
		fr.albedo = FAR_ALBEDO
		add_child(fr)
		fr.setup(dir, W)
	ride_s = W.route_s_of_sol(DEFAULT_START_SOL)
	var start := W.route_pos(ride_s)
	for a in args:
		if a.begins_with("--sol="):
			start = W.route_pos(W.route_s_of_sol(int(a.get_slice("=", 1))))
			ride_s = W.route_s_of_sol(int(a.get_slice("=", 1)))
		elif a.begins_with("--at="):
			var v := a.substr(5).split_floats(",")
			start = Vector2(v[0], v[1])
			riding = false
		elif a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--cam="):
			var v := a.substr(6).split_floats(",")
			yaw = -deg_to_rad(v[0])
			pitch = deg_to_rad(v[1])
			cam.fov = v[2]
	origin.position = Vector3(start.x, W.height_at(start.x, start.y), start.y)
	W.focus = origin.position
	if "--test" in args:
		_world_test()


func _load_layers(args: PackedStringArray) -> void:
	# Cada compañero pone su capa en res://layers/<nombre>/layer.gd (ver docs/EQUIPO.md). --layers=a,b limita cuales se cargan.
	var only: PackedStringArray = []
	for a in args:
		if a.begins_with("--layers="):
			only = a.substr(9).split(",")
	for d in DirAccess.get_directories_at("res://layers"):
		if d.begins_with("_") or (not only.is_empty() and not d in only):
			continue
		var path := "res://layers/%s/layer.gd" % d
		if not ResourceLoader.exists(path):
			continue
		var sc: Script = load(path)
		if sc == null:
			push_warning("capa %s: no se pudo cargar" % d)
			continue
		var node := Node3D.new()
		node.name = "capa_" + d
		node.set_script(sc)
		add_child(node)
		if node.has_method("setup"):
			node.setup(W, self)
		print("capa cargada: ", d)


func _world_test() -> void:
	var t0 := Time.get_ticks_msec()
	while not W.is_ready() and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
		W.focus = origin.position
	var nodes := 0
	var tris := 0
	for c in W.get_children():
		if c is MeshInstance3D:
			nodes += 1
			tris += (c.mesh as ArrayMesh).surface_get_array_index_len(0) / 3
	print("TEST world tiles=%d route_len=%.0f m sol_max=%d meshes=%d tris=%d ready=%s in %.1fs h(0,0)=%.2f"
		% [W.tiles.size(), W.route_length(), W.route_sol[W.route_sol.size() - 1], nodes, tris, W.is_ready(), (Time.get_ticks_msec() - t0) / 1000.0, W.height_at(0, 0)])
	var ing := W.lonlat_to_world(77.322539, 18.497263)
	print("TEST ingenuity world=(%.1f, %.1f) h=%.1f nearest route s=%.0f sol=%d" % [ing.x, ing.y, W.height_at(ing.x, ing.y), W.route_nearest_s(ing), W.route_sol_at(W.route_nearest_s(ing))])
	get_tree().quit()


func _process_world(delta: float) -> void:
	if shot_path != "":
		shot_frames += 1
		if W.is_ready():
			shot_ready_frames += 1
		if shot_frames > 120 and shot_ready_frames > 120:
			get_viewport().get_texture().get_image().save_png(shot_path)
			get_tree().quit()
	var p := origin.position
	if in_xr:
		var fwd := -cam.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var rgt := fwd.cross(Vector3.UP)
		var mv := left.get_vector2("primary")
		if riding:
			world_speed = mv.y * 12.0
		else:
			p += (fwd * mv.y + rgt * mv.x) * delta * (15.0 if left.get_float("trigger") > 0.5 else WALK_SPEED)
		var tx := right.get_vector2("primary").x
		var objetivo := 0.0
		if absf(tx) > GIRO_ZONA_MUERTA:
			objetivo = -signf(tx) * (absf(tx) - GIRO_ZONA_MUERTA) / (1.0 - GIRO_ZONA_MUERTA) * deg_to_rad(GIRO_MAX_GRADOS_S)
		giro_v = lerpf(giro_v, objetivo, 1.0 - exp(-GIRO_SUAVIZADO * delta))
		origin.rotate_y(giro_v * delta)
	else:
		cam.rotation = Vector3(pitch, yaw, 0)
		var d := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): d.z -= 1
		if Input.is_key_pressed(KEY_S): d.z += 1
		if Input.is_key_pressed(KEY_A): d.x -= 1
		if Input.is_key_pressed(KEY_D): d.x += 1
		var spd := 20.0 if Input.is_key_pressed(KEY_SHIFT) else 2.2
		if route_ui and route_ui.typing:
			d = Vector3.ZERO
		if riding:
			world_speed = -d.z * 12.0
		else:
			p += Basis(Vector3.UP, yaw) * d * delta * spd
	if riding:
		ride_s = clampf(ride_s + world_speed * delta, 0.0, W.route_length())
		var rp := W.route_pos(ride_s)
		p.x = rp.x
		p.z = rp.y
	var head_off := cam.global_position - origin.global_position if in_xr else Vector3.ZERO
	p.y = W.height_at(p.x + head_off.x, p.z + head_off.z)
	origin.position = p
	W.focus = p
	if route_ui:
		route_ui.tick(p, cam.global_basis, delta)
	if _hud_due(delta):
		hud.text = "Mars Route Walker · sol %d · %s · %.0f m de ruta · pendiente %.1f° · H: peligro %s · G: bajar/subir del rover\nTerreno: USGS/JPL HiRISE DTM 1 m + ortho 25 cm" % [W.route_sol_at(ride_s), "en el rover" if riding else "a pie", ride_s, W.slope_deg(p.x, p.z), "ON" if hazard_on else "off"] \
			+ (route_ui.hud_lines(p) if route_ui else "")


var _hud_t := 0.0


func _hud_due(delta: float) -> bool:
	# El texto del HUD (formato de cadenas + re-maquetado del Label) se rehace a 10 Hz, no en cada cuadro.
	_hud_t -= delta
	if _hud_t > 0.0:
		return false
	_hud_t = 0.1
	return true


func _route_setup() -> void:
	# Guía de ruta + selección de destino (ver route/route_ui.gd). --noroute lo desactiva.
	if "--noroute" in OS.get_cmdline_user_args():
		return
	var guide: Node = load("res://route/guide_path.gd").new()
	guide.name = "GuidePath"
	guide.json_path = ""
	add_child(guide)
	route_ui = load("res://route/route_ui.gd").new()
	route_ui.name = "RouteUI"
	add_child(route_ui)
	route_ui.setup(self, guide, PATCH, scene)


func _route_setup_world() -> void:
	# Igual que _route_setup() pero para el modo world: la guía queda pegada al terreno de WorldStreamer. --noroute lo desactiva.
	if "--noroute" in OS.get_cmdline_user_args():
		return
	var guide: Node = load("res://route/guide_path.gd").new()
	guide.name = "GuidePath"
	guide.json_path = ""
	add_child(guide)
	route_ui = load("res://route/route_ui.gd").new()
	route_ui.name = "RouteUI"
	add_child(route_ui)
	route_ui.setup_world(self, guide, W)


func _cli_camera() -> void:
	# --cam=az_deg,el_deg,vfov_deg  (compass az clockwise from north, el negative = down); --shot=/path.png
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cam="):
			var v := a.substr(6).split_floats(",")
			var az := deg_to_rad(float(meta["waypoint"].get("yaw", 0.0)))
			var f := Vector3(sin(az), 0, -cos(az))
			var r := Vector3(-f.z, 0, f.x) * -1.0
			r = f.cross(Vector3.UP)
			var pp := f * 0.85 + r * 0.68
			origin.position = Vector3(pp.x, height_at(pp.x, pp.z), pp.z)
			cam.position.y = 1.97
			yaw = -deg_to_rad(v[0])
			pitch = deg_to_rad(v[1])
			cam.fov = v[2]
		elif a == "--norover":
			get_node("Perseverance").visible = false
		elif a.begins_with("--shot="):
			shot_path = a.substr(7)


func _hraw(ix: int, iz: int) -> float:
	ix = clampi(ix, 0, n - 1)
	iz = clampi(iz, 0, n - 1)
	return heights[iz * n + ix]


func height_at(x: float, z: float) -> float:
	var fx := clampf(x + half, 0.0, n - 1.001)
	var fz := clampf(z + half, 0.0, n - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	return lerpf(lerpf(_hraw(ix, iz), _hraw(ix + 1, iz), tx), lerpf(_hraw(ix, iz + 1), _hraw(ix + 1, iz + 1), tx), tz)


func slope_deg(x: float, z: float) -> float:
	var dx := (height_at(x + 1, z) - height_at(x - 1, z)) / 2.0
	var dz := (height_at(x, z + 1) - height_at(x, z - 1)) / 2.0
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


func _environment() -> void:
	var env := Environment.new()
	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.6, 0.4, 0.3)
	sky.sky_horizon_color = Color(0.95, 0.6, 0.4)
	sky.ground_horizon_color = Color(0.88, 0.55, 0.38)
	sky.ground_bottom_color = Color(0.5, 0.35, 0.27)
	var s := Sky.new()
	s.sky_material = sky
	env.sky = s
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.fog_enabled = true
	env.fog_light_color = Color(0.9, 0.58, 0.4)
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.00007
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.94, 0.86)
	sun.light_angular_distance = 0.35
	sun.light_energy = 1.3
	sun.rotation_degrees = Vector3(-35, 40, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)
	var ld := -sun.basis.z
	sun_dir_xz = Vector2(ld.x, ld.z).normalized()


func _terrain() -> MeshInstance3D:
	var ortho_file: String = layer_entry("ortho")["file"]
	var img := Image.load_from_file(ProjectSettings.globalize_path(PATCH + ortho_file))
	if img == null:
		img = Image.load_from_file(PATCH + ortho_file)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var sh: Shader = load("res://terrain.gdshader")
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = sh
	terrain_mat.set_shader_parameter("ortho", tex)
	terrain_mat.set_shader_parameter("hazard_deg", HAZARD_DEG)
	terrain_mat.set_shader_parameter("far_albedo", Vector3(FAR_ALBEDO.r, FAR_ALBEDO.g, FAR_ALBEDO.b))
	terrain_mat.set_shader_parameter("patch_half", half)
	if scene.get("show_rover", true) == false:
		var rg := ring_gain_at_patch()
		if rg["stats"]:
			var im := img.duplicate()
			im.convert(Image.FORMAT_L8)
			var px: PackedByteArray = im.get_data()
			var m := 0.0
			for i in range(px.size()):
				m += px[i]
			m /= px.size() * 255.0
			var v := 0.0
			for i in range(px.size()):
				v += pow(px[i] / 255.0 - m, 2.0)
			terrain_mat.set_shader_parameter("stats", true)
			terrain_mat.set_shader_parameter("o_mean", m)
			terrain_mat.set_shader_parameter("o_std", maxf(sqrt(v / px.size()), 0.02))
			terrain_mat.set_shader_parameter("ring_gain", rg["gain"])
	terrain_mat.set_shader_parameter("shadow_dir", sun_dir_xz)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cells := int(round(2.0 * half / STEP))
	var ext := 2.0 * half + 1.0
	for iz in range(cells):
		for ix in range(cells):
			var x0 := -half + ix * STEP
			var z0 := -half + iz * STEP
			var vs := [Vector2(x0, z0), Vector2(x0 + STEP, z0), Vector2(x0, z0 + STEP), Vector2(x0 + STEP, z0 + STEP)]
			for k in [0, 1, 2, 1, 3, 2]:
				var v: Vector2 = vs[k]
				st.set_uv(Vector2((v.x + ext / 2.0) / ext, (v.y + ext / 2.0) / ext))
				st.add_vertex(Vector3(v.x, height_at(v.x, v.y), v.y))
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = terrain_mat
	return mi


func _rock_mesh(seed_: int, levels: int) -> ArrayMesh:
	# Icosphere (2 subdivisions), lumpy radius, then several random planar "fracture" cuts so
	# the rock has flat broken faces and edges instead of reading as a crystal. Even seeds are
	# flat shaded (fresh, angular), odd seeds smooth shaded (wind-rounded).
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var t := (1.0 + sqrt(5.0)) / 2.0
	var vs: Array[Vector3] = []
	for p in [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]]:
		vs.append(Vector3(p[0], p[1], p[2]).normalized())
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for lvl in levels:
		var mid := {}
		var nf := []
		for f in faces:
			var m := []
			for e in [[f[0], f[1]], [f[1], f[2]], [f[2], f[0]]]:
				var key: int = mini(e[0], e[1]) * 4096 + maxi(e[0], e[1])
				if not mid.has(key):
					mid[key] = vs.size()
					vs.append(((vs[e[0]] + vs[e[1]]) * 0.5).normalized())
				m.append(mid[key])
			nf.append([f[0], m[0], m[2]])
			nf.append([f[1], m[1], m[0]])
			nf.append([f[2], m[2], m[1]])
			nf.append([m[0], m[1], m[2]])
		faces = nf
	# low-frequency lumps: sum of a few random lobes
	var lobes := []
	for k in 4:
		lobes.append([Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(), rng.randf_range(-0.18, 0.22)])
	for i in vs.size():
		var r := 1.0
		for l in lobes:
			r += l[1] * maxf(vs[i].dot(l[0]), 0.0) * maxf(vs[i].dot(l[0]), 0.0)
		vs[i] *= r * rng.randf_range(0.97, 1.03)
	# fracture planes
	for k in rng.randi_range(5, 9) if seed_ % 2 == 0 else rng.randi_range(2, 5):
		var nrm := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var d := rng.randf_range(0.38, 0.8) if seed_ % 2 == 0 else rng.randf_range(0.6, 0.85)
		for i in vs.size():
			var o := vs[i].dot(nrm)
			if o > d:
				vs[i] -= nrm * (o - d)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1 if seed_ % 2 == 0 else 0)
	for f in faces:
		var a: Vector3 = vs[f[0]]
		var b: Vector3 = vs[f[1]]
		var c: Vector3 = vs[f[2]]
		# Godot front faces are clockwise: emit so that (b-a)x(c-a) points inward
		var order := [f[0], f[2], f[1]] if (b - a).cross(c - a).dot(a + b + c) > 0.0 else [f[0], f[1], f[2]]
		for idx in order:
			st.add_vertex(vs[idx])
	if seed_ % 2 == 1:
		st.index()
	st.generate_normals()
	return st.commit()


var rock_variants := 10


func _rock_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_back;
varying vec3 wp;
varying vec3 wn;
varying vec3 icol;
float h31(vec3 p){ p = fract(p * 0.1031); p += dot(p, p.zyx + 31.32); return fract((p.x + p.y) * p.z); }
float vn3(vec3 p){ vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
  return mix(mix(mix(h31(i), h31(i+vec3(1,0,0)), f.x), mix(h31(i+vec3(0,1,0)), h31(i+vec3(1,1,0)), f.x), f.y),
             mix(mix(h31(i+vec3(0,0,1)), h31(i+vec3(1,0,1)), f.x), mix(h31(i+vec3(0,1,1)), h31(i+vec3(1,1,1)), f.x), f.y), f.z); }
void vertex() {
  wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
  wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
  icol = COLOR.rgb;
}
void fragment() {
  float n = vn3(wp * 9.0) * 0.6 + vn3(wp * 31.0) * 0.4;
  vec3 rock = icol * (0.75 + 0.5 * n);
  // reddish dust settles on up-facing surfaces and near the ground line
  vec3 dust = vec3(0.3, 0.165, 0.085);
  float up = smoothstep(0.45, 0.95, wn.y) * smoothstep(0.3, 0.7, vn3(wp * 6.0) * 0.7 + vn3(wp * 23.0) * 0.3);
  float dustamt = clamp(up * 0.6, 0.0, 0.6);
  ALBEDO = mix(rock, dust, dustamt);
  ROUGHNESS = mix(0.82, 1.0, dustamt);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


func _rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 448
	var mat := _rock_material()
	var xf: Array = []
	var cols: Array = []
	for v in rock_variants * 2:
		xf.append([] as Array[Transform3D])
		cols.append([] as Array[Color])
	# Rock field = clustered (parent boulder + debris apron) plus a sparse background scatter,
	# sizes power-law up to 0.7 m, thinning on flat ground and toward the patch edge.
	for cidx in range(70):
		var cx := rng.randf_range(-half + 3, half - 3)
		var cz := rng.randf_range(-half + 3, half - 3)
		var fade := 1.0 - smoothstep(0.35, 1.0, maxf(absf(cx), absf(cz)) / half)
		if rng.randf() > fade:
			continue
		var big := minf(0.15 / pow(rng.randf_range(0.05, 1.0), 0.55), 0.7)
		_add_rock(rng, cx, cz, big, xf, cols)
		var spread := 0.6 + big * 4.0
		for j in rng.randi_range(4, 22):
			var ang := rng.randf() * TAU
			var dd := spread * sqrt(-2.0 * log(maxf(rng.randf(), 1e-4))) * 0.5
			var x := cx + cos(ang) * dd
			var z := cz + sin(ang) * dd
			if absf(x) > half - 1 or absf(z) > half - 1:
				continue
			_add_rock(rng, x, z, minf(big * 0.6, 0.03 / pow(rng.randf_range(0.04, 1.0), 0.6)), xf, cols)
	for i in range(2500):
		var x := rng.randf_range(-half + 1, half - 1)
		var z := rng.randf_range(-half + 1, half - 1)
		var sl := slope_deg(x, z)
		var fade := 1.0 - smoothstep(0.35, 1.0, maxf(absf(x), absf(z)) / half)
		if rng.randf() > (0.06 + sl / 40.0) * fade:
			continue
		var r := minf(0.07 / pow(rng.randf_range(0.02, 1.0), 0.6), 0.6)
		_add_rock(rng, x, z, r, xf, cols)
	# pebbles and flat slabs near the walking area, in loose patches (the shader adds the fine gravel)
	var pc: Array[Vector2] = []
	for i in range(60):
		pc.append(Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(-20.0, 20.0)))
	for i in range(9000):
		var x := rng.randf_range(-20.0, 20.0)
		var z := rng.randf_range(-20.0, 20.0)
		var near := 1e9
		for q in pc:
			near = minf(near, q.distance_squared_to(Vector2(x, z)))
		var keep := (0.25 + 0.75 * exp(-near / 6.0)) * (1.0 - smoothstep(6.0, 20.0, Vector2(x, z).length()))
		if rng.randf() > keep:
			continue
		var r := minf(0.012 / pow(rng.randf_range(0.03, 1.0), 0.55), 0.14)
		_add_rock(rng, x, z, r, xf, cols)
	var tris := 0
	for v in rock_variants * 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		# second half of the variants = low-poly versions for small clasts (< 6 cm)
		mm.mesh = _rock_mesh(448 + v * 17 + v % 2, 2 if v < rock_variants else 1)
		tris += xf[v].size() * (320 if v < rock_variants else 80)
		mm.instance_count = xf[v].size()
		for k in xf[v].size():
			mm.set_instance_transform(k, xf[v][k])
			mm.set_instance_color(k, cols[v][k])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = mat
		mi.name = "SyntheticRocks%d" % v
		add_child(mi)
	print("rocks: %d tris" % tris)


func _add_rock(rng: RandomNumberGenerator, x: float, z: float, r: float, xf: Array, cols: Array) -> void:
	# sit the rock on the local terrain normal, random yaw, and bury 20-55 % of its height
	var gx := (height_at(x + 0.5, z) - height_at(x - 0.5, z))
	var gz := (height_at(x, z + 0.5) - height_at(x, z - 0.5))
	var up := Vector3(-gx, 1.0, -gz).normalized()
	var tilt := Basis(Vector3.UP, rng.randf() * TAU)
	var lean := Vector3(rng.randf_range(-0.25, 0.25), 0, rng.randf_range(-0.25, 0.25))
	var b := Basis(Quaternion(Vector3.UP, (up + lean).normalized())) * tilt
	var flat := rng.randf_range(0.35, 0.85)
	b = b * Basis.from_scale(Vector3(r * rng.randf_range(0.85, 1.35), r * flat, r * rng.randf_range(0.65, 1.15)))
	var v := rng.randi() % rock_variants + (rock_variants if r < 0.06 else 0)
	var bury := rng.randf_range(0.2, 0.55)
	xf[v].append(Transform3D(b, Vector3(x, height_at(x, z), z) + up * r * flat * (1.0 - 2.0 * bury)))
	# lithology: mostly grey-brown basaltic, some darker, a few lighter tan clasts
	var u := rng.randf()
	var col := Color(0.2, 0.15, 0.115) if u < 0.55 else (Color(0.1, 0.085, 0.075) if u < 0.88 else Color(0.32, 0.24, 0.17))
	cols[v].append(col * rng.randf_range(0.85, 1.15))


func _route() -> void:
	var segs: Array = JSON.parse_string(FileAccess.get_file_as_string(PATCH + layer_entry("route")["file"]))
	var bm := BoxMesh.new()
	bm.size = Vector3(0.18, 0.02, 0.18)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.8, 1.0)
	var xf: Array[Transform3D] = []
	for s in segs:
		var pts: Array = s["points"]
		for i in range(pts.size() - 1):
			var a := Vector2(pts[i][0], pts[i][1])
			var b := Vector2(pts[i + 1][0], pts[i + 1][1])
			var steps := maxi(1, int(a.distance_to(b) / 0.4))
			for k in range(steps):
				var p := a.lerp(b, float(k) / steps)
				if absf(p.x) > half or absf(p.y) > half:
					continue
				xf.append(Transform3D(Basis(), Vector3(p.x, height_at(p.x, p.y) + 0.06, p.y)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = bm
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	add_child(mi)
	var wp: Dictionary = meta["waypoint"]
	var l := Label3D.new()
	l.text = str(scene.get("label", "origin"))
	l.font_size = 64
	l.pixel_size = 0.006
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = Vector3(0, height_at(0, 0) + 3.4, 0)
	l.no_depth_test = true
	add_child(l)


func _hud() -> void:
	var cl := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_color_override("font_color", Color(1, 0.9, 0.7))
	cl.add_child(hud)
	add_child(cl)


func _setup_player() -> void:
	origin = XROrigin3D.new()
	add_child(origin)
	cam = XRCamera3D.new()
	cam.position.y = 1.6
	cam.far = 150000.0
	origin.add_child(cam)
	left = XRController3D.new()
	left.tracker = &"left_hand"
	right = XRController3D.new()
	right.tracker = &"right_hand"
	origin.add_child(left)
	origin.add_child(right)
	right.button_pressed.connect(func(name: String):
		if name == "by_button":
			_toggle_ride()
		elif name == "ax_button":
			a_down_ms = Time.get_ticks_msec()
			a_reset_done = false)
	right.button_released.connect(func(name: String):
		if name == "ax_button" and a_down_ms > 0:
			a_down_ms = 0
			if not a_reset_done:
				_toggle_hazard())


func _setup_xr() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr and xr.initialize():
		get_viewport().use_xr = true
		var scale := 0.85
		var msaa := 0
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--xr-scale="):
				scale = float(a.get_slice("=", 1))
			elif a.begins_with("--msaa="):
				msaa = int(a.get_slice("=", 1))
		xr.render_target_size_multiplier = scale
		get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][clampi(msaa, 0, 2)]
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		in_xr = true
	else:
		get_viewport().msaa_3d = Viewport.MSAA_4X
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


var overlay := 0   # 0 normal, 1 pendiente, 2.. vistas de falso color de la capa atmosfera


var a_down_ms := 0
var a_reset_done := false
var hud_vr_on := true
var grip_der_down := false


func _toggle_hud_vr() -> void:
	hud_vr_on = not hud_vr_on
	var atm = get_node_or_null("capa_atmosfera")
	if atm != null and atm.has_method("alternar_panel") and atm.ver_panel != hud_vr_on:
		atm.alternar_panel()
	var mm = get_node_or_null("capa_minimapa")
	if mm != null and mm.has_method("poner_visible_vr"):
		mm.poner_visible_vr(hud_vr_on)


func _toggle_hazard(to := -1) -> void:
	## Cicla: normal -> pendiente -> vistas de atmosfera (calor, radiacion, O2, presion, polvo) -> normal.
	var atm = get_node_or_null("capa_atmosfera")
	var has_atm: bool = atm != null and atm.has_method("alternar_vista")
	overlay = (overlay + 1) % (7 if has_atm else 2) if to < 0 else to
	hazard_on = overlay == 1
	if world_mode:
		W.set_hazard(hazard_on)
	else:
		terrain_mat.set_shader_parameter("hazard", hazard_on)
	if has_atm:
		var want: int = overlay - 2 if overlay >= 2 else -1
		if atm.vista != want:
			atm.alternar_vista(atm.vista if want < 0 else want)


func _toggle_ride() -> void:
	if not world_mode:
		return
	riding = not riding
	if riding:
		ride_s = W.route_nearest_s(Vector2(origin.position.x, origin.position.z))


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_H:
		_toggle_hazard()
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif world_mode and e is InputEventKey and e.pressed and e.keycode == KEY_G:
		_toggle_ride()
	elif e is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= e.relative.x * 0.003
		pitch = clampf(pitch - e.relative.y * 0.003, -1.4, 1.4)


func _process(delta: float) -> void:
	if in_xr and right != null:
		var gd: float = right.get_float("grip")
		if gd > 0.85 and not grip_der_down:
			grip_der_down = true
			_toggle_hud_vr()
		elif gd < 0.4:
			grip_der_down = false
	if a_down_ms > 0 and not a_reset_done and Time.get_ticks_msec() - a_down_ms >= 3000:
		a_reset_done = true
		_toggle_hazard(0)
	if world_mode:
		_process_world(delta)
		return
	if shot_path != "":
		shot_frames += 1
		if shot_frames == 40:
			get_viewport().get_texture().get_image().save_png(shot_path)
			get_tree().quit()
	if in_xr:
		var fwd := -cam.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var rgt := fwd.cross(Vector3.UP)
		var mv := left.get_vector2("primary")
		origin.global_position += (fwd * mv.y + rgt * mv.x) * delta * (15.0 if left.get_float("trigger") > 0.5 else WALK_SPEED)
		var tx := right.get_vector2("primary").x
		var objetivo := 0.0
		if absf(tx) > GIRO_ZONA_MUERTA:
			objetivo = -signf(tx) * (absf(tx) - GIRO_ZONA_MUERTA) / (1.0 - GIRO_ZONA_MUERTA) * deg_to_rad(GIRO_MAX_GRADOS_S)
		giro_v = lerpf(giro_v, objetivo, 1.0 - exp(-GIRO_SUAVIZADO * delta))
		origin.rotate_y(giro_v * delta)
	else:
		cam.rotation = Vector3(pitch, yaw, 0)
		var d := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): d.z -= 1
		if Input.is_key_pressed(KEY_S): d.z += 1
		if Input.is_key_pressed(KEY_A): d.x -= 1
		if Input.is_key_pressed(KEY_D): d.x += 1
		var spd := 6.0 if Input.is_key_pressed(KEY_SHIFT) else 2.2
		if route_ui and route_ui.typing:
			d = Vector3.ZERO
		origin.position += Basis(Vector3.UP, yaw) * d * delta * spd
	var p := origin.position
	p.x = clampf(p.x, -LIMIT, LIMIT)
	p.z = clampf(p.z, -LIMIT, LIMIT)
	p.y = height_at(p.x, p.z)
	origin.position = p
	if route_ui:
		route_ui.tick(p, cam.global_basis, delta)
	if _hud_due(delta):
		hud.text = "Mars Route Walker · %s · pendiente aquí %.1f° · H: capa de peligro %s\nTerreno: USGS/JPL HiRISE DTM 1 m + ortho 25 cm · rocas SINTÉTICAS (ilustrativas)" % [str(scene.get("label", "")), slope_deg(p.x, p.z), "ON" if hazard_on else "off"] \
			+ (route_ui.hud_lines(p) if route_ui else "")


func _farfield() -> void:
	for e in scene["layers"]:
		if e.get("role", "") == "ring":
			var v: Dictionary = e.get("view", {})
			_farring(e, int(v.get("subsample", 3)), float(v.get("lower_m", 3.0)), float(e.get("inner_skip_m", 0.0)))


func _farring(fm: Dictionary, sub: int, lower: float, skip_half: float) -> void:
	var base: String = fm["id"]
	var fn := int(fm["samples"])
	var fstep := float(fm["step_m"])
	var f := FileAccess.open(PATCH + fm["file"], FileAccess.READ)
	var fh := f.get_buffer(f.get_length()).to_float32_array()
	var fhalf := float(fm["half_m"])
	var cs := fstep * sub
	var cells := (fn - 1) / sub
	var sk := absf(skip_half)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(cells):
		for ix in range(cells):
			var x0 := -fhalf + ix * cs
			var z0 := -fhalf + iz * cs
			var inside := x0 >= -sk and x0 + cs <= sk and z0 >= -sk and z0 + cs <= sk
			if inside:
				continue
			var vs := [Vector2i(ix, iz), Vector2i(ix + 1, iz), Vector2i(ix, iz + 1), Vector2i(ix + 1, iz + 1)]
			for k in [0, 1, 2, 1, 3, 2]:
				var v: Vector2i = vs[k]
				var hh := fh[(v.y * sub) * fn + v.x * sub] - lower
				st.add_vertex(Vector3(-fhalf + v.x * cs, hh, -fhalf + v.y * cs))
	st.generate_normals()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
uniform vec3 albedo = vec3(0.2, 0.14, 0.1);
uniform float planet_r = 3396190.0;
uniform sampler2D tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform float tex_mean = 1.0;
uniform float tex_on = 0.0;
uniform float tex_half = 1000.0;
varying vec2 wpos;
float h21(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
void vertex() {
  wpos = VERTEX.xz;
  vec2 rel = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz - CAMERA_POSITION_WORLD.xz;
  VERTEX.y -= dot(rel, rel) / (2.0 * planet_r);
}
void fragment() {
  float d = vn(wpos / 120.0) * 0.6 + vn(wpos / 30.0) * 0.4;
  float tv = texture(tex, (wpos + tex_half) / (2.0 * tex_half)).r;
  float tg = mix(1.0, pow(clamp(tv / tex_mean, 0.4, 1.7), 1.25), tex_on);
  ALBEDO = albedo * (0.8 + 0.4 * d) * tg;
  ROUGHNESS = 1.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo", Vector3(FAR_ALBEDO.r, FAR_ALBEDO.g, FAR_ALBEDO.b))
	mat.set_shader_parameter("planet_r", MARS_R)
	var tex_file: String = fm.get("texture", "")
	var tp := ProjectSettings.globalize_path(PATCH + tex_file)
	if tex_file != "" and FileAccess.file_exists(PATCH + tex_file):
		var timg := Image.load_from_file(tp)
		if timg != null:
			timg.convert(Image.FORMAT_L8)
			timg.generate_mipmaps()
			var sum := 0.0
			var d8 := timg.get_data()
			for i in range(0, d8.size(), 7):
				sum += d8[i]
			mat.set_shader_parameter("tex", ImageTexture.create_from_image(timg))
			mat.set_shader_parameter("tex_mean", maxf(sum / (d8.size() / 7.0) / 255.0, 0.01))
			mat.set_shader_parameter("tex_on", 1.0)
			mat.set_shader_parameter("tex_half", fhalf)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(-fhalf, -3000, -fhalf), Vector3(2 * fhalf, 7000, 2 * fhalf))
	mi.name = base
	add_child(mi)


func _collect_aabb(n: Node, root: Node3D, acc: Array) -> void:
	if n is MeshInstance3D:
		var xf: Transform3D = root.global_transform.affine_inverse() * n.global_transform
		var a: AABB = xf * n.get_aabb()
		acc[0] = a if acc[0] == null else (acc[0] as AABB).merge(a)
	for ch in n.get_children():
		_collect_aabb(ch, root, acc)


func _rover() -> void:
	var bytes := FileAccess.get_file_as_bytes(ROVER_MODEL)
	var doc := GLTFDocument.new()
	var gst := GLTFState.new()
	if doc.append_from_buffer(bytes, "", gst) != OK:
		push_warning("rover model failed to load")
		return
	var scene := doc.generate_scene(gst)
	var holder := Node3D.new()
	holder.add_child(scene)
	add_child(holder)
	var acc: Array = [null]
	_collect_aabb(holder, holder, acc)
	var bb: AABB = acc[0]
	scene.position = Vector3(-(bb.position.x + bb.size.x / 2.0), -bb.position.y, -(bb.position.z + bb.size.z / 2.0))
	var az := deg_to_rad(float(meta["waypoint"].get("yaw", 0.0)))
	var fwd := Vector3(sin(az), 0, -cos(az))
	var hs := [height_at(0, 0), height_at(1.3, 1.5), height_at(-1.3, 1.5), height_at(1.3, -1.5), height_at(-1.3, -1.5)]
	var gx := (height_at(1.5, 0) - height_at(-1.5, 0)) / 3.0
	var gz := (height_at(0, 1.5) - height_at(0, -1.5)) / 3.0
	var up := Vector3(-gx, 1.0, -gz).normalized()
	var right := fwd.cross(up).normalized()
	var fwd2 := up.cross(right)
	var lowest: float = hs.min()
	holder.transform = Transform3D(Basis(right, up, -fwd2), Vector3(0, lowest + 0.02, 0))
	holder.name = "Perseverance"


extends Node3D
# Mars Route Walker viewer: loads a patch folder (heightmap.f32, ortho.png, route_local.json, meta.json).

var PATCH := "res://patch/"
const STEP := 0.5
const LIMIT := 45.0 # walkable half-width in m (a ~90 m x 90 m square); the "100 m2" request is read as ~100 m across
const MARS_R := 3396190.0
const FAR_ALBEDO := Color(0.2, 0.14, 0.1)
const ROVER_MODEL := "res://models/perseverance.glbd"
const HAZARD_DEG := 15.0

var meta: Dictionary
var n := 101
var half := 50.0
var heights := PackedFloat32Array()
var origin: XROrigin3D
var cam: XRCamera3D
var left: XRController3D
var right: XRController3D
var in_xr := false
var snap_ready := true
var yaw := 0.0
var pitch := 0.0
var terrain_mat: ShaderMaterial
var hazard_on := false
var hud: Label


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--patch="):
			PATCH = "res://" + a.substr(8) + "/"
	meta = JSON.parse_string(FileAccess.get_file_as_string(PATCH + "meta.json"))
	n = int(meta["samples"])
	half = (n - 1) * 0.5
	var f := FileAccess.open(PATCH + "heightmap.f32", FileAccess.READ)
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
	if "--test" in OS.get_cmdline_user_args():
		print("TEST ok n=%d h(0,0)=%.2f h(30,0)=%.2f" % [n, height_at(0, 0), height_at(30, 0)])
		get_tree().quit()


var shot_path := ""
var shot_frames := 0


func _cli_camera() -> void:
	# --cam=az_deg,el_deg,vfov_deg  (compass az clockwise from north, el negative = down); --shot=/path.png
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cam="):
			var v := a.substr(6).split_floats(",")
			var az := deg_to_rad(float(meta["waypoint"]["yaw"]))
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


func _terrain() -> MeshInstance3D:
	var img := Image.load_from_file(ProjectSettings.globalize_path(PATCH + "ortho.png"))
	if img == null:
		img = Image.load_from_file(PATCH + "ortho.png")
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
uniform sampler2D ortho : filter_linear_mipmap_anisotropic;
uniform bool hazard = false;
uniform float hazard_deg = 15.0;
varying float slope;
varying vec2 wpos;
uniform vec3 far_albedo = vec3(0.2, 0.14, 0.1);
uniform float patch_half = 50.0;
varying float vdist;
void vertex() { slope = degrees(acos(clamp(NORMAL.y, 0.0, 1.0))); wpos = VERTEX.xz; }
float h21(vec2 p){ vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
float peb(vec2 p, float cell, out float tone) {
  vec2 q = p / cell; vec2 i = floor(q); vec2 f = fract(q);
  vec2 c = vec2(h21(i + 7.1), h21(i + 3.3)) * 0.5 + 0.25;
  float rad = 0.14 + 0.2 * h21(i + 9.7);
  tone = h21(i + 5.5);
  return step(0.2, h21(i + 1.9)) * smoothstep(rad, 0.0, length(f - c));
}
void fragment() {
  float g = texture(ortho, UV).r;
  float d = vn(wpos*6.0)*0.5 + vn(wpos*23.0)*0.3 + vn(wpos*91.0)*0.2;
  float c = clamp((g - 0.227) / 0.313, 0.0, 1.0);
  vec3 dark = vec3(0.07, 0.042, 0.027);
  vec3 bright = vec3(0.3, 0.16, 0.08);
  float near = 1.0 - smoothstep(25.0, 70.0, length(VERTEX));
  d = mix(vn(wpos*6.0)*0.5 + vn(wpos*23.0)*0.3 + 0.1, d, near);
  vec3 base = mix(dark, bright, c) * (0.85 + 0.3 * d);
  float edge = max(abs(wpos.x), abs(wpos.y));
  base = mix(base, far_albedo * (0.8 + 0.4 * d), smoothstep(patch_half - 20.0, patch_half - 1.0, edge));
  if (hazard) {
    float t = smoothstep(hazard_deg*0.6, hazard_deg*1.3, slope);
    base = mix(base, vec3(0.9,0.1,0.1), t*0.65);
  }
  float dist = length(VERTEX);
  float w1 = 1.0 - smoothstep(3.0, 9.0, dist);
  float w2 = 1.0 - smoothstep(8.0, 24.0, dist);
  float t1; float t2;
  vec2 e = vec2(0.003, 0.0);
  float a1 = peb(wpos, 0.022, t1);
  float a2 = peb(wpos, 0.065, t2);
  vec2 g1 = vec2(peb(wpos + e.xy, 0.022, t1) - peb(wpos - e.xy, 0.022, t1), peb(wpos + e.yx, 0.022, t1) - peb(wpos - e.yx, 0.022, t1)) / (2.0 * e.x);
  vec2 g2 = vec2(peb(wpos + e.xy, 0.065, t2) - peb(wpos - e.xy, 0.065, t2), peb(wpos + e.yx, 0.065, t2) - peb(wpos - e.yx, 0.065, t2)) / (2.0 * e.x);
  vec3 bump = vec3(-(g1.x * w1 * 0.0030 + g2.x * w2 * 0.0080), 0.0, -(g1.y * w1 * 0.0030 + g2.y * w2 * 0.0080));
  NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(bump, 0.0)).xyz);
  float lit = a1 * w1 * (t1 - 0.3) + a2 * w2 * (t2 - 0.3);
  base *= 1.0 + 0.9 * lit;
  ALBEDO = base;
  ROUGHNESS = 1.0;
}
"""
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = sh
	terrain_mat.set_shader_parameter("ortho", tex)
	terrain_mat.set_shader_parameter("hazard_deg", HAZARD_DEG)
	terrain_mat.set_shader_parameter("far_albedo", Vector3(FAR_ALBEDO.r, FAR_ALBEDO.g, FAR_ALBEDO.b))
	terrain_mat.set_shader_parameter("patch_half", half)
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


func _rock_mesh(seed_: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var t := (1.0 + sqrt(5.0)) / 2.0
	var vs: Array[Vector3] = []
	for p in [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]]:
		var v := Vector3(p[0], p[1], p[2]).normalized()
		vs.append(v * rng.randf_range(0.75, 1.15))
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	for f in faces:
		for k in [f[0], f[2], f[1]]:
			st.add_vertex(vs[k])
	st.generate_normals()
	return st.commit()


func _rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 448
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	var variants := 6
	var xf: Array = []
	var cols: Array = []
	for v in variants:
		xf.append([] as Array[Transform3D])
		cols.append([] as Array[Color])
	# big rocks (power-law, up to 0.7 m), thinning with distance from the centre
	for i in range(2500):
		var x := rng.randf_range(-half + 1, half - 1)
		var z := rng.randf_range(-half + 1, half - 1)
		var sl := slope_deg(x, z)
		var fade := 1.0 - smoothstep(0.35, 1.0, maxf(absf(x), absf(z)) / half)
		if rng.randf() > (0.12 + sl / 30.0) * fade:
			continue
		var r := minf(0.08 / pow(rng.randf_range(0.02, 1.0), 0.6), 0.7)
		_add_rock(rng, x, z, r, xf, cols)
	# pebbles and flat slabs near the walking area (real surface here is dense gravel)
	for i in range(9000):
		var x := rng.randf_range(-20.0, 20.0)
		var z := rng.randf_range(-20.0, 20.0)
		if rng.randf() > 1.0 - smoothstep(6.0, 20.0, Vector2(x, z).length()):
			continue
		var r := minf(0.012 / pow(rng.randf_range(0.03, 1.0), 0.55), 0.14)
		_add_rock(rng, x, z, r, xf, cols)
	for v in variants:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _rock_mesh(448 + v * 17)
		mm.use_colors = true
		mm.instance_count = xf[v].size()
		for k in xf[v].size():
			mm.set_instance_transform(k, xf[v][k])
			mm.set_instance_color(k, cols[v][k])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = mat
		mi.name = "SyntheticRocks%d" % v
		add_child(mi)


func _add_rock(rng: RandomNumberGenerator, x: float, z: float, r: float, xf: Array, cols: Array) -> void:
	var b := Basis.from_euler(Vector3(rng.randf() * 0.6, rng.randf() * TAU, rng.randf() * 0.6))
	var flat := rng.randf_range(0.3, 0.9)
	b = b.scaled(Vector3(r * rng.randf_range(0.8, 1.4), r * flat, r * rng.randf_range(0.6, 1.2)))
	var v := rng.randi() % xf.size()
	xf[v].append(Transform3D(b, Vector3(x, height_at(x, z) + r * flat * 0.25, z)))
	var k := rng.randf_range(0.85, 1.2)
	cols[v].append((Color(0.34, 0.225, 0.155) if rng.randf() < 0.65 else Color(0.12, 0.085, 0.065)) * k)


func _route() -> void:
	var segs: Array = JSON.parse_string(FileAccess.get_file_as_string(PATCH + "route_local.json"))
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
	l.text = "Sol %d · site %d drive %d" % [wp["sol"], wp["site"], wp["drive"]]
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
	right.button_pressed.connect(func(name: String): if name == "by_button" or name == "ax_button": _toggle_hazard())
	left.button_pressed.connect(func(name: String): if name == "by_button" or name == "ax_button": _toggle_hazard())


func _setup_xr() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr and xr.initialize():
		get_viewport().use_xr = true
		xr.render_target_size_multiplier = 1.25
		get_viewport().msaa_3d = Viewport.MSAA_4X
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		in_xr = true
	else:
		get_viewport().msaa_3d = Viewport.MSAA_4X
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _toggle_hazard() -> void:
	hazard_on = not hazard_on
	terrain_mat.set_shader_parameter("hazard", hazard_on)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_H:
		_toggle_hazard()
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif e is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= e.relative.x * 0.003
		pitch = clampf(pitch - e.relative.y * 0.003, -1.4, 1.4)


func _process(delta: float) -> void:
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
		origin.global_position += (fwd * mv.y + rgt * mv.x) * delta * 2.2
		var tx := right.get_vector2("primary").x
		if absf(tx) > 0.7 and snap_ready:
			origin.rotate_y(-signf(tx) * PI / 6.0)
			snap_ready = false
		elif absf(tx) < 0.3:
			snap_ready = true
	else:
		cam.rotation = Vector3(pitch, yaw, 0)
		var d := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): d.z -= 1
		if Input.is_key_pressed(KEY_S): d.z += 1
		if Input.is_key_pressed(KEY_A): d.x -= 1
		if Input.is_key_pressed(KEY_D): d.x += 1
		var spd := 6.0 if Input.is_key_pressed(KEY_SHIFT) else 2.2
		origin.position += Basis(Vector3.UP, yaw) * d * delta * spd
	var p := origin.position
	p.x = clampf(p.x, -LIMIT, LIMIT)
	p.z = clampf(p.z, -LIMIT, LIMIT)
	p.y = height_at(p.x, p.z)
	origin.position = p
	hud.text = "Mars Route Walker · sol %d · pendiente aquí %.1f° · H: capa de peligro %s\nTerreno: USGS/JPL HiRISE DTM 1 m + ortho 25 cm · rocas SINTÉTICAS (ilustrativas)" % [meta["waypoint"]["sol"], slope_deg(p.x, p.z), "ON" if hazard_on else "off"]


func _farfield() -> void:
	_farring("farfield", 3, 2.5, 8.0 - half)
	_farring("farfield6", 3, 3.0, 2990.0)
	if FileAccess.file_exists(PATCH + "farfield80.f32"):
		_farring("farfield80", 2, 6.0, 5990.0)


func _farring(base: String, sub: int, lower: float, skip_half: float) -> void:
	var fm: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PATCH + base + ".json"))
	var fn := int(fm["samples"])
	var fstep := float(fm["step_m"])
	var f := FileAccess.open(PATCH + base + ".f32", FileAccess.READ)
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
	var tp := ProjectSettings.globalize_path(PATCH + base + "_tex.png")
	if FileAccess.file_exists(PATCH + base + "_tex.png"):
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
	var az := deg_to_rad(float(meta["waypoint"]["yaw"]))
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


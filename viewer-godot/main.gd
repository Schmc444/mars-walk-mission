extends Node3D
# Mars Route Walker viewer: loads a patch folder (heightmap.f32, ortho.png, route_local.json, meta.json).

const PATCH := "res://patch/"
const STEP := 0.5
const LIMIT := 45.0
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
	meta = JSON.parse_string(FileAccess.get_file_as_string(PATCH + "meta.json"))
	n = int(meta["samples"])
	half = (n - 1) * 0.5
	var f := FileAccess.open(PATCH + "heightmap.f32", FileAccess.READ)
	heights = f.get_buffer(f.get_length()).to_float32_array()
	_environment()
	add_child(_terrain())
	_rocks()
	_route()
	_setup_player()
	_setup_xr()
	var p := Vector3(0, 0, 0)
	origin.position = Vector3(p.x, height_at(p.x, p.z), p.z)
	yaw = deg_to_rad(float(meta["waypoint"]["yaw"]))
	_hud()
	if "--test" in OS.get_cmdline_user_args():
		print("TEST ok n=%d h(0,0)=%.2f h(30,0)=%.2f" % [n, height_at(0, 0), height_at(30, 0)])
		get_tree().quit()


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
	sky.sky_top_color = Color(0.45, 0.38, 0.33)
	sky.sky_horizon_color = Color(0.85, 0.62, 0.45)
	sky.ground_horizon_color = Color(0.8, 0.58, 0.42)
	sky.ground_bottom_color = Color(0.5, 0.35, 0.27)
	var s := Sky.new()
	s.sky_material = sky
	env.sky = s
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.fog_enabled = true
	env.fog_light_color = Color(0.82, 0.6, 0.45)
	env.fog_density = 0.0
	env.fog_depth_begin = 40.0
	env.fog_depth_end = 140.0
	env.fog_mode = Environment.FOG_MODE_DEPTH
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.88, 0.75)
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
uniform sampler2D ortho : source_color, filter_linear_mipmap_anisotropic;
uniform bool hazard = false;
uniform float hazard_deg = 15.0;
varying float slope;
varying vec2 wpos;
void vertex() { slope = degrees(acos(clamp(NORMAL.y, 0.0, 1.0))); wpos = VERTEX.xz; }
float h21(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
float vn(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y); }
void fragment() {
  float g = texture(ortho, UV).r;
  float d = vn(wpos*6.0)*0.5 + vn(wpos*23.0)*0.3 + vn(wpos*91.0)*0.2;
  float c = clamp((g - 0.2) / 0.38, 0.0, 1.0);
  float lum = (0.12 + 0.88 * c) * (0.8 + 0.4*d);
  vec3 base = vec3(lum*0.95, lum*0.62, lum*0.42);
  if (hazard) {
    float t = smoothstep(hazard_deg*0.6, hazard_deg*1.3, slope);
    base = mix(base, vec3(0.9,0.1,0.1), t*0.65);
  }
  ALBEDO = base;
  ROUGHNESS = 1.0;
}
"""
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = sh
	terrain_mat.set_shader_parameter("ortho", tex)
	terrain_mat.set_shader_parameter("hazard_deg", HAZARD_DEG)
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


func _rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 448
	var sm := SphereMesh.new()
	sm.radial_segments = 8
	sm.rings = 5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.26, 0.2)
	mat.roughness = 1.0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sm
	var xf: Array[Transform3D] = []
	for i in range(2500):
		var x := rng.randf_range(-half + 1, half - 1)
		var z := rng.randf_range(-half + 1, half - 1)
		var sl := slope_deg(x, z)
		if rng.randf() > 0.12 + sl / 30.0:
			continue
		var r := 0.08 / pow(rng.randf_range(0.02, 1.0), 0.6)
		r = minf(r, 0.7)
		var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
		b = b.scaled(Vector3(r, r * rng.randf_range(0.5, 0.9), r * rng.randf_range(0.7, 1.2)))
		xf.append(Transform3D(b, Vector3(x, height_at(x, z) + r * 0.15, z)))
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.name = "SyntheticRocks"
	add_child(mi)


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
	l.position = Vector3(0, height_at(0, 0) + 3.0, 0)
	l.no_depth_test = true
	add_child(l)
	var pole := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.03
	cm.height = 2.6
	pole.mesh = cm
	pole.material_override = mat
	pole.position = Vector3(0, height_at(0, 0) + 1.3, 0)
	add_child(pole)


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
	cam.far = 400.0
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

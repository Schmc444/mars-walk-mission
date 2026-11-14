extends Node3D
# Capa "ruta": el Perseverance sobre la ruta real. Paso 1: el rover sigue core.ride_s y queda estacionado al bajarse.

const ROVER_MODEL := "res://models/perseverance.glbd"

var world: WorldStreamer
var core: Node
var rover: Node3D
var rover_s := 0.0

const MAX_V := 100.0 / 3.6       # 100 km/h en m/s
const MAX_ANG := deg_to_rad(60.0)
const SEAT_Y := 1.0              # altura de la cubierta (el modelo mide 1.85 m con el mastil)
const DESKTOP_EYE := 0.9         # ojos sobre la cubierta en escritorio (sentado)
const TEX_MAX := 256
const ROVER_LOD := 2          # nivel de detalle del modelo (mayor = menos triangulos)
const LEVER_LEN := 0.45

var lever := 0.0                 # -1..1, fraccion de la velocidad maxima


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	rover = _load_rover()
	if rover:
		rover_s = core.ride_s
		_place()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lever="):
			lever = clampf(float(a.get_slice("=", 1)), -1.0, 1.0)


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
		var inp: float = core.world_speed / 12.0   # joystick / WASD del core, -1..1
		var target: float = inp * MAX_V if absf(inp) > 0.01 else lever * MAX_V
		if absf(target - core.world_speed) > 0.001:
			core.ride_s = clampf(core.ride_s + (target - core.world_speed) * delta, 0.0, world.route_length())
		rover_s = core.ride_s
	_place()
	if core.riding:
		core.origin.position = rover.position + rover.basis.y * SEAT_Y
		if not core.in_xr:
			core.cam.position.y = DESKTOP_EYE
	elif not core.in_xr:
		core.cam.position.y = 1.6
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
	_simplify(scene as Node3D)
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


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 10
	return m


func _simplify(scene: Node3D) -> void:
	var groups := {}   # material -> {"v": PackedVector3Array, "n": ..., "uv": PackedVector2Array, "i": PackedInt32Array}
	var olds: Array[MeshInstance3D] = []
	_collect(scene, scene, groups, olds)
	for mi in olds:
		if not is_instance_valid(mi):
			continue
		mi.get_parent().remove_child(mi)
		mi.free()
	var out := ArrayMesh.new()
	for m in groups:
		var g: Dictionary = groups[m]
		if (g["v"] as PackedVector3Array).is_empty() or (g["i"] as PackedInt32Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = g["v"]
		arr[Mesh.ARRAY_NORMAL] = g["n"]
		arr[Mesh.ARRAY_TEX_UV] = g["uv"]
		arr[Mesh.ARRAY_INDEX] = g["i"]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, _light_mat(m))
	var merged := MeshInstance3D.new()
	merged.name = "RoverMerged"
	merged.mesh = out
	merged.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(merged)
	print("ruta: rover fusionado, superficies=", out.get_surface_count())


func _collect(n: Node, root: Node3D, groups: Dictionary, olds: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		var mi := n as MeshInstance3D
		var src: ArrayMesh = mi.mesh
		var xf: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
		var nb := xf.basis.inverse().transposed()
		var im := ImporterMesh.new()
		for si in src.get_surface_count():
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, src.surface_get_arrays(si), [], {}, src.surface_get_material(si))
		im.generate_lods(25.0, 60.0, [])
		for si in im.get_surface_count():
			var arr := im.get_surface_arrays(si)
			var nl := im.get_surface_lod_count(si)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			if nl > 0:
				idx = im.get_surface_lod_indices(si, mini(ROVER_LOD, nl) - 1)
			var mat: Material = im.get_surface_material(si)
			if not groups.has(mat):
				groups[mat] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(), "i": PackedInt32Array()}
			var g: Dictionary = groups[mat]
			var gv: PackedVector3Array = g["v"]
			var gn: PackedVector3Array = g["n"]
			var gu: PackedVector2Array = g["uv"]
			var gi: PackedInt32Array = g["i"]
			var base: int = gv.size()
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var us: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			for k in vs.size():
				gv.append(xf * vs[k])
				gn.append((nb * ns[k]).normalized() if k < ns.size() else Vector3.UP)
				gu.append(us[k] if k < us.size() else Vector2.ZERO)
			for k in idx:
				gi.append(base + k)
			g["v"] = gv
			g["n"] = gn
			g["uv"] = gu
			g["i"] = gi
		olds.append(mi)
	for ch in n.get_children():
		_collect(ch, root, groups, olds)


var mat_cache := {}


func _light_mat(m: Material) -> Material:
	if not (m is BaseMaterial3D):
		return m
	if mat_cache.has(m):
		return mat_cache[m]
	var b := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
	b.normal_enabled = false
	b.rim_enabled = false
	b.clearcoat_enabled = false
	b.ao_enabled = false
	b.heightmap_enabled = false
	b.refraction_enabled = false
	b.subsurf_scatter_enabled = false
	b.detail_enabled = false
	var t := b.albedo_texture
	if t != null:
		var img := t.get_image()
		if img != null:
			if img.is_compressed():
				img.decompress()
			var big := maxi(img.get_width(), img.get_height())
			if big > TEX_MAX:
				var f := float(TEX_MAX) / big
				img.resize(maxi(int(img.get_width() * f), 1), maxi(int(img.get_height() * f), 1), Image.INTERPOLATE_BILINEAR)
			img.generate_mipmaps()
			b.albedo_texture = ImageTexture.create_from_image(img)
	b.roughness_texture = null
	b.metallic_texture = null
	b.emission_texture = null
	b.roughness = 0.8
	b.metallic = minf(b.metallic, 0.3)
	mat_cache[m] = b
	return b

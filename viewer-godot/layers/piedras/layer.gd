extends Node3D
# Piedras decorativas (SINTETICAS, aleatorias con semilla; no son un mapa real de rocas).
# Se generan por celdas de 16 m alrededor del jugador y se agrupan en 20 MultiMesh (10 variantes grandes + 10 de bajo poligono
# para guijarros) para pocos draw calls en la Frame. Reusa la malla y el material de roca de main.gd.

const CELL := 16.0
const RADIUS_CELLS := 3          # rocas hasta ~56 m
const PEBBLE_CELLS := 1          # guijarros solo cerca (~24 m)
const PER_FRAME := 3             # celdas nuevas por frame
const SEED := 448

var world: WorldStreamer
var core: Node
var variants := 10
var mms: Array[MultiMesh] = []
var cache := {}                  # Vector2i -> {"rocks": [[v, Transform3D, Color]...], "pebbles": [...]}
var center := Vector2i(1 << 30, 1 << 30)
var want: Array[Vector2i] = []
var dirty := false
var stat_tris := 0


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	variants = c.rock_variants
	var mat: ShaderMaterial = c._rock_material()
	for v in variants * 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = c._rock_mesh(SEED + v * 17 + v % 2, 2 if v < variants else 1)
		mm.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
		mms.append(mm)
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.name = "Piedras%d" % v
		add_child(mi)


func _process(_delta: float) -> void:
	if world == null or not world.is_ready():
		return
	var p: Vector3 = core.origin.global_position
	var c := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
	if c != center:
		center = c
		want.clear()
		for dz in range(-RADIUS_CELLS, RADIUS_CELLS + 1):
			for dx in range(-RADIUS_CELLS, RADIUS_CELLS + 1):
				if dx * dx + dz * dz <= RADIUS_CELLS * RADIUS_CELLS + 1:
					want.append(Vector2i(c.x + dx, c.y + dz))
		want.sort_custom(func(a, b): return (a - c).length_squared() < (b - c).length_squared())
		dirty = true
	if not dirty:
		return
	var made := 0
	for k in want:
		if not cache.has(k):
			cache[k] = _gen_cell(k)
			made += 1
			if made >= PER_FRAME:
				return
	_rebuild()
	dirty = false
	if cache.size() > 200:
		var keep := {}
		for k in want:
			keep[k] = cache[k]
		cache = keep


func _rebuild() -> void:
	var bufs: Array = []
	for v in variants * 2:
		bufs.append(PackedFloat32Array())
	var tris := 0
	for k in want:
		var d: Dictionary = cache[k]
		var near: bool = absi(k.x - center.x) <= PEBBLE_CELLS and absi(k.y - center.y) <= PEBBLE_CELLS
		for part in (["rocks", "pebbles"] if near else ["rocks"]):
			for e in d[part]:
				var v: int = e[0]
				var t: Transform3D = e[1]
				var col: Color = e[2]
				var b := t.basis
				bufs[v].append_array(PackedFloat32Array([
					b.x.x, b.y.x, b.z.x, t.origin.x,
					b.x.y, b.y.y, b.z.y, t.origin.y,
					b.x.z, b.y.z, b.z.z, t.origin.z,
					col.r, col.g, col.b, col.a]))
				tris += 320 if v < variants else 80
	for v in variants * 2:
		var mm := mms[v]
		var n: int = bufs[v].size() / 16
		mm.instance_count = n
		if n > 0:
			mm.buffer = bufs[v]
	stat_tris = tris
	print("piedras: ", tris, " tris, celdas ", want.size())


func _gen_cell(k: Vector2i) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(k.x, k.y, SEED))
	var x0 := k.x * CELL
	var z0 := k.y * CELL
	var rocks: Array = []
	# cumulo: un bloque con escombros alrededor (poco frecuente) + dispersion de fondo
	if rng.randf() < 0.5:
		var cx := x0 + rng.randf() * CELL
		var cz := z0 + rng.randf() * CELL
		var big := minf(0.15 / pow(rng.randf_range(0.05, 1.0), 0.55), 0.7)
		rocks.append(_rock(rng, cx, cz, big))
		var spread := 0.6 + big * 4.0
		for j in rng.randi_range(4, 22):
			var ang := rng.randf() * TAU
			var dd := spread * sqrt(-2.0 * log(maxf(rng.randf(), 1e-4))) * 0.5
			rocks.append(_rock(rng, cx + cos(ang) * dd, cz + sin(ang) * dd, minf(big * 0.6, 0.03 / pow(rng.randf_range(0.04, 1.0), 0.6))))
	for i in range(36):
		var x := x0 + rng.randf() * CELL
		var z := z0 + rng.randf() * CELL
		if rng.randf() > 0.1 + world.slope_deg(x, z) / 30.0:
			continue
		rocks.append(_rock(rng, x, z, minf(0.07 / pow(rng.randf_range(0.02, 1.0), 0.6), 0.6)))
	# guijarros y lajas pequenas, en parches
	var pebbles: Array = []
	var pc: Array[Vector2] = []
	for i in range(3):
		pc.append(Vector2(x0 + rng.randf() * CELL, z0 + rng.randf() * CELL))
	for i in range(70):
		var x := x0 + rng.randf() * CELL
		var z := z0 + rng.randf() * CELL
		var near := 1e9
		for q in pc:
			near = minf(near, q.distance_squared_to(Vector2(x, z)))
		if rng.randf() > 0.25 + 0.75 * exp(-near / 6.0):
			continue
		pebbles.append(_rock(rng, x, z, minf(0.012 / pow(rng.randf_range(0.03, 1.0), 0.55), 0.14)))
	return {"rocks": rocks, "pebbles": pebbles}


func _rock(rng: RandomNumberGenerator, x: float, z: float, r: float) -> Array:
	var h := world.height_at(x, z)
	var gx := world.height_at(x + 0.5, z) - world.height_at(x - 0.5, z)
	var gz := world.height_at(x, z + 0.5) - world.height_at(x, z - 0.5)
	var up := Vector3(-gx, 1.0, -gz).normalized()
	var tilt := Basis(Vector3.UP, rng.randf() * TAU)
	var lean := Vector3(rng.randf_range(-0.25, 0.25), 0, rng.randf_range(-0.25, 0.25))
	var b := Basis(Quaternion(Vector3.UP, (up + lean).normalized())) * tilt
	var flat := rng.randf_range(0.35, 0.85)
	b = b * Basis.from_scale(Vector3(r * rng.randf_range(0.85, 1.35), r * flat, r * rng.randf_range(0.65, 1.15)))
	var v := rng.randi() % variants + (variants if r < 0.06 else 0)
	var bury := rng.randf_range(0.2, 0.55)
	var u := rng.randf()
	var col := Color(0.2, 0.15, 0.115) if u < 0.55 else (Color(0.1, 0.085, 0.075) if u < 0.88 else Color(0.32, 0.24, 0.17))
	col = col * rng.randf_range(0.85, 1.15)
	col.a = 1.0
	return [v, Transform3D(b, Vector3(x, h, z) + up * r * flat * (1.0 - 2.0 * bury)), col]

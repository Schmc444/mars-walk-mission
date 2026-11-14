class_name WorldStreamer
extends Node3D
# Streams the tiled world made by tools/build_world.py (world.json, terrain/t*/ and ortho/o*/ tiles).
# Frame: x east, z south, y up, ground metres, origin = first route vertex. Tiles are 500 px blocks; each is split in
# 5x5 chunks of 100 px. Near chunks use the 1 m terrain, the rest 5 m, tiles beyond `mid_m` are one 20 m mesh.
# Public API for layers: height_at, slope_deg, lonlat_to_world, world_to_lonlat, route_*, set_hazard, is_ready.

const CHUNK_PX := 100
const SHADER := preload("res://terrain.gdshader")

var lod1_m := 250.0          # chunks closer than this use the 1 m terrain
var mid_m := 1100.0          # tiles closer than this are split in chunks (5 m or 1 m); farther ones are one 20 m mesh
var tex_near_cm := 50        # ortho resolution for tiles near the camera (25 or 50)
var tex_near_m := 350.0
var planet_r := 3396190.0
var shadow_dir := Vector2(-0.64, -0.76)

var dir := ""
var W := {}
var block := 500
var sx := 1.0
var sz := 1.0
var opx := 0.0
var opy := 0.0
var tile_w := 500.0
var tile_h := 500.0
var tiles := {}              # Vector2i(bx, by) -> tile Dictionary
var hazard_on := false
var route_xz := PackedVector2Array()
var route_sol := PackedInt32Array()
var route_s := PackedFloat32Array()
var focus := Vector3.ZERO
var stat_chunks := 0

var _thread := Thread.new()
var _sem := Semaphore.new()
var _mx := Mutex.new()
var _jobs: Array = []        # [priority, kind, key, args]
var _done: Array = []
var _quit := false
var _idx_cache := {}
var _blank: ImageTexture
var _next_update := 0.0
var _ready_flag := false


func setup(world_dir: String) -> void:
	dir = world_dir if world_dir.ends_with("/") else world_dir + "/"
	W = JSON.parse_string(FileAccess.get_file_as_string(dir + "world.json"))
	block = int(W["block"])
	sx = float(W["spacing_x"])
	sz = float(W["spacing_z"])
	opx = float(W["origin"]["px"][0])
	opy = float(W["origin"]["px"][1])
	tile_w = block * sx
	tile_h = block * sz
	var bi := Image.create(2, 2, false, Image.FORMAT_L8)
	bi.fill(Color(0.5, 0.5, 0.5))
	_blank = ImageTexture.create_from_image(bi)
	for t in W["tiles"]:
		var k := Vector2i(int(t["bx"]), int(t["by"]))
		tiles[k] = {
			"k": k, "org": Vector2((k.x * block - opx) * sx, (k.y * block - opy) * sz),
			"h5": _read_f32(dir + "terrain/t5/%d_%d.f32" % [k.x, k.y]),
			"h20": _read_f32(dir + "terrain/t20/%d_%d.f32" % [k.x, k.y]),
			"h1": PackedFloat32Array(), "mat": null, "tex_cm": 0, "far": null,
			"chunks": {}, "chunk_lod": {}, "pending": {}, "near": false, "d": 1e9,
		}
	_load_route()
	_thread.start(_worker)
	focus = Vector3(0, 0, 0)
	_update(true)


func _exit_tree() -> void:
	_quit = true
	_sem.post()
	if _thread.is_started():
		_thread.wait_to_finish()


func _read_f32(path: String) -> PackedFloat32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(f.get_length()).to_float32_array()


# ---------------------------------------------------------------- coordinates

func lonlat_to_world(lon: float, lat: float) -> Vector2:
	var px := (planet_r * deg_to_rad(lon) - float(W["origin"]["mosaic_x0"])) - opx
	var py := (float(W["origin"]["mosaic_y0"]) - planet_r * deg_to_rad(lat)) - opy
	return Vector2(px * sx, py * sz)


func world_to_lonlat(x: float, z: float) -> Vector2:
	var X := (x / sx + opx) + float(W["origin"]["mosaic_x0"])
	var Y := float(W["origin"]["mosaic_y0"]) - (z / sz + opy)
	return Vector2(rad_to_deg(X / planet_r), rad_to_deg(Y / planet_r))


# ---------------------------------------------------------------- ground height

func height_at(x: float, z: float) -> float:
	var px := x / sx + opx
	var py := z / sz + opy
	var k := Vector2i(floori(px / block), floori(py / block))
	if not tiles.has(k):
		return 0.0
	var t: Dictionary = tiles[k]
	var fx := px - k.x * block
	var fz := py - k.y * block
	var h: PackedFloat32Array = t["h1"]
	var st := 1.0
	if h.is_empty():
		h = t["h5"]
		st = 5.0
	var n := int(block / st) + 1
	var gx := clampf(fx / st, 0.0, n - 1.001)
	var gz := clampf(fz / st, 0.0, n - 1.001)
	var ix := int(gx)
	var iz := int(gz)
	var tx := gx - ix
	var tz := gz - iz
	return lerpf(lerpf(h[iz * n + ix], h[iz * n + ix + 1], tx), lerpf(h[(iz + 1) * n + ix], h[(iz + 1) * n + ix + 1], tx), tz)


func slope_deg(x: float, z: float) -> float:
	var dx := (height_at(x + 1, z) - height_at(x - 1, z)) / 2.0
	var dz := (height_at(x, z + 1) - height_at(x, z - 1)) / 2.0
	return rad_to_deg(atan(sqrt(dx * dx + dz * dz)))


# ---------------------------------------------------------------- route

func _load_route() -> void:
	var segs: Array = JSON.parse_string(FileAccess.get_file_as_string(dir + str(W["route"])))["route"]
	segs.sort_custom(func(a, b): return a["sol"] < b["sol"])
	var acc := 0.0
	for s in segs:
		for p in s["xz"]:
			var v := Vector2(p[0], p[1])
			if not route_xz.is_empty():
				acc += route_xz[route_xz.size() - 1].distance_to(v)
			route_xz.append(v)
			route_sol.append(int(s["sol"]))
			route_s.append(acc)


func route_length() -> float:
	return route_s[route_s.size() - 1] if not route_s.is_empty() else 0.0


func route_pos(s: float) -> Vector2:
	var i := route_s.bsearch(s)
	i = clampi(i, 1, route_s.size() - 1)
	var a := route_s[i - 1]
	var b := route_s[i]
	return route_xz[i - 1].lerp(route_xz[i], 0.0 if b <= a else clampf((s - a) / (b - a), 0.0, 1.0))


func route_sol_at(s: float) -> int:
	return route_sol[clampi(route_s.bsearch(s), 0, route_sol.size() - 1)]


func route_s_of_sol(sol: int) -> float:
	for i in route_sol.size():
		if route_sol[i] >= sol:
			return route_s[i]
	return route_length()


func route_nearest_s(p: Vector2) -> float:
	var best := 1e30
	var bs := 0.0
	for i in route_xz.size():
		var d := route_xz[i].distance_squared_to(p)
		if d < best:
			best = d
			bs = route_s[i]
	return bs


# ---------------------------------------------------------------- streaming

func set_hazard(on: bool) -> void:
	hazard_on = on
	for t in tiles.values():
		if t["mat"] != null:
			(t["mat"] as ShaderMaterial).set_shader_parameter("hazard", on)


func is_ready() -> bool:
	return _ready_flag


func _process(_d: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _next_update:
		_next_update = now + 0.25
		_update(false)
	_collect()


func _rect_dist(t: Dictionary, x0: float, z0: float, w: float, h: float) -> float:
	var dx := maxf(maxf(x0 - focus.x, focus.x - (x0 + w)), 0.0)
	var dz := maxf(maxf(z0 - focus.z, focus.z - (z0 + h)), 0.0)
	return sqrt(dx * dx + dz * dz)


func _material(t: Dictionary) -> ShaderMaterial:
	if t["mat"] == null:
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("ortho", _blank)
		m.set_shader_parameter("tile_origin", t["org"])
		m.set_shader_parameter("patch_half", 1.0e9)
		m.set_shader_parameter("planet_r", planet_r)
		m.set_shader_parameter("shadow_dir", shadow_dir)
		m.set_shader_parameter("hazard", hazard_on)
		t["mat"] = m
	return t["mat"]


func _post(prio: float, kind: String, t: Dictionary, args: Dictionary) -> void:
	var key: String = kind + str(args.get("c", "")) + str(args.get("lod", ""))
	if t["pending"].has(key):
		return
	t["pending"][key] = true
	args["kind"] = kind
	args["t"] = t
	args["key"] = key
	_mx.lock()
	_jobs.append([prio, args])
	_mx.unlock()
	_sem.post()


func _update(first: bool) -> void:
	var nready := true
	var total_near := 0
	for t in tiles.values():
		var org: Vector2 = t["org"]
		var d := _rect_dist(t, org.x, org.y, tile_w, tile_h)
		t["d"] = d
		var was_near: bool = t["near"]
		var near := d < mid_m * (1.1 if was_near else 1.0)
		t["near"] = near
		# ortho resolution
		var want_cm := 400
		if d < tex_near_m:
			want_cm = tex_near_cm
		elif d < mid_m:
			want_cm = 100
		if want_cm != t["tex_cm"] and not t["pending"].has("texcm" + str(want_cm)):
			if d < mid_m * 1.5 or t["tex_cm"] == 0:
				_post(d, "tex", t, {"cm": want_cm, "lod": want_cm})
		if near:
			total_near += 1
			_material(t)
			var cells_ready := 0
			for cz in range(block / CHUNK_PX):
				for cx in range(block / CHUNK_PX):
					var c := Vector2i(cx, cz)
					var cd := _rect_dist(t, org.x + cx * CHUNK_PX * sx, org.y + cz * CHUNK_PX * sz, CHUNK_PX * sx, CHUNK_PX * sz)
					var cur: int = t["chunk_lod"].get(c, 0)
					var want := 1 if cd < lod1_m * (1.15 if cur == 1 else 1.0) else 5
					if want == 1 and t["h1"].is_empty():
						_post(cd, "h1", t, {})
						want = 5
					if cur != want and not t["pending"].has("chunk" + str(c) + str(want)):
						_post(cd, "chunk", t, {"c": c, "lod": want})
					if cur != 0:
						cells_ready += 1
			if t["far"] != null and cells_ready == 25:
				(t["far"] as Node).queue_free()
				t["far"] = null
			if cd_all(t) and cells_ready < 25:
				nready = false
		else:
			if t["far"] == null and not t["pending"].has("far20"):
				_post(d, "far", t, {"lod": 20})
			if not t["chunks"].is_empty() and t["far"] != null:
				for c in t["chunks"].values():
					(c as Node).queue_free()
				t["chunks"].clear()
				t["chunk_lod"].clear()
			if d > mid_m * 1.6 and not t["h1"].is_empty():
				t["h1"] = PackedFloat32Array()
	if first:
		_ready_flag = false
	elif nready and _jobs_empty():
		_ready_flag = true


func cd_all(t: Dictionary) -> bool:
	return t["d"] < lod1_m * 2.0


func _jobs_empty() -> bool:
	_mx.lock()
	var e := _jobs.is_empty()
	_mx.unlock()
	return e


# ---------------------------------------------------------------- worker

func _worker() -> void:
	while true:
		_sem.wait()
		if _quit:
			return
		_mx.lock()
		var best := -1
		var bp := 1e30
		for i in _jobs.size():
			var p: float = _jobs[i][0]
			if p < bp:
				bp = p
				best = i
		var job: Array = []
		if best >= 0:
			job = _jobs[best]
			_jobs.remove_at(best)
		_mx.unlock()
		if job.is_empty():
			continue
		var a: Dictionary = job[1]
		var t: Dictionary = a["t"]
		var k: Vector2i = t["k"]
		match a["kind"]:
			"h1":
				a["data"] = _read_f32(dir + "terrain/t1/%d_%d.f32" % [k.x, k.y])
			"tex":
				var img := Image.load_from_file(ProjectSettings.globalize_path(dir) + "ortho/o%d/%d_%d.png" % [a["cm"], k.x, k.y])
				if img != null:
					img.convert(Image.FORMAT_L8)
					img.generate_mipmaps()
				a["img"] = img
			"chunk":
				var c: Vector2i = a["c"]
				var lod: int = a["lod"]
				var h: PackedFloat32Array = t["h1"] if lod == 1 else t["h5"]
				a["arr"] = _chunk_arrays(h, lod, c.x * CHUNK_PX, c.y * CHUNK_PX, CHUNK_PX)
			"far":
				a["arr"] = _chunk_arrays(t["h20"], 20, 0, 0, block)
		_mx.lock()
		_done.append(a)
		_mx.unlock()


func _indices(cells: int) -> PackedInt32Array:
	if _idx_cache.has(cells):
		return _idx_cache[cells]
	var idx := PackedInt32Array()
	var w := cells + 1
	for j in range(cells):
		for i in range(cells):
			var v0 := j * w + i
			var v1 := v0 + 1
			var v2 := v0 + w
			var v3 := v2 + 1
			idx.append_array([v0, v1, v2, v1, v3, v2])
	var base := w * w
	# skirt quads: edge e (0 N, 1 S, 2 W, 3 E); outward normal (nx, nz), direction of increasing index (dx, dz)
	var defs := [[0, -1, 1, 0], [0, 1, 1, 0], [-1, 0, 0, 1], [1, 0, 0, 1]]
	for e in 4:
		var nx: int = defs[e][0]
		var nz: int = defs[e][1]
		var dx: int = defs[e][2]
		var dz: int = defs[e][3]
		var visible_as_is := (dz * nx - dx * nz) < 0
		for k in range(cells):
			var P := _edge_vert(e, k, cells)
			var Q := _edge_vert(e, k + 1, cells)
			var a := base + e * w + k
			var b := a + 1
			if visible_as_is:
				idx.append_array([P, Q, b, P, b, a])
			else:
				idx.append_array([P, a, b, P, b, Q])
	_idx_cache[cells] = idx
	return idx


func _edge_vert(e: int, k: int, cells: int) -> int:
	var w := cells + 1
	match e:
		0: return k
		1: return cells * w + k
		2: return k * w
		_: return k * w + cells
	return 0


func _chunk_arrays(h: PackedFloat32Array, lod: int, px0: int, py0: int, size_px: int) -> Array:
	var n := block / lod + 1                 # samples per side of the whole tile array
	var cells := size_px / lod
	var i0 := px0 / lod
	var j0 := py0 / lod
	var w := cells + 1
	var nv := w * w + 4 * w
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	pos.resize(nv)
	nrm.resize(nv)
	uv.resize(nv)
	var stx := lod * sx
	var stz := lod * sz
	var depth := 1.0 + lod * 0.6
	for j in range(w):
		var gj := j0 + j
		var jm := maxi(gj - 1, 0)
		var jp := mini(gj + 1, n - 1)
		for i in range(w):
			var gi := i0 + i
			var im := maxi(gi - 1, 0)
			var ip := mini(gi + 1, n - 1)
			var hh := h[gj * n + gi]
			var gx := (h[gj * n + ip] - h[gj * n + im]) / ((ip - im) * stx)
			var gz := (h[jp * n + gi] - h[jm * n + gi]) / ((jp - jm) * stz)
			var v := j * w + i
			pos[v] = Vector3(i * stx, hh, j * stz)
			nrm[v] = Vector3(-gx, 1.0, -gz).normalized()
			uv[v] = Vector2((px0 + i * lod) / float(block), (py0 + j * lod) / float(block))
	for e in 4:
		for k in range(w):
			var src := _edge_vert(e, k, cells)
			var dst := w * w + e * w + k
			pos[dst] = pos[src] - Vector3(0, depth, 0)
			nrm[dst] = nrm[src]
			uv[dst] = uv[src]
	return [pos, nrm, uv, _indices(cells)]


# ---------------------------------------------------------------- main-thread side

func _collect() -> void:
	var budget := 8
	while budget > 0:
		_mx.lock()
		var a: Dictionary = _done.pop_front() if not _done.is_empty() else {}
		_mx.unlock()
		if a.is_empty():
			return
		budget -= 1
		var t: Dictionary = a["t"]
		t["pending"].erase(a["key"])
		match a["kind"]:
			"h1":
				t["h1"] = a["data"]
			"tex":
				if a["img"] != null:
					(_material(t) as ShaderMaterial).set_shader_parameter("ortho", ImageTexture.create_from_image(a["img"]))
					t["tex_cm"] = a["cm"]
			"chunk":
				_add_chunk(t, a)
			"far":
				if t["near"]:
					continue
				var mi := _mesh_instance(t, a["arr"], Vector2(0, 0), false)
				t["far"] = mi
				add_child(mi)


func _mesh_instance(t: Dictionary, arr: Array, off: Vector2, shadow: bool) -> MeshInstance3D:
	var am := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = arr[0]
	arrays[Mesh.ARRAY_NORMAL] = arr[1]
	arrays[Mesh.ARRAY_TEX_UV] = arr[2]
	arrays[Mesh.ARRAY_INDEX] = arr[3]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = _material(t)
	mi.position = Vector3(t["org"].x + off.x, 0.0, t["org"].y + off.y)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _add_chunk(t: Dictionary, a: Dictionary) -> void:
	if not t["near"]:
		return
	var c: Vector2i = a["c"]
	var lod: int = a["lod"]
	var mi := _mesh_instance(t, a["arr"], Vector2(c.x * CHUNK_PX * sx, c.y * CHUNK_PX * sz), lod == 1)
	add_child(mi)
	if t["chunks"].has(c):
		(t["chunks"][c] as Node).queue_free()
	t["chunks"][c] = mi
	t["chunk_lod"][c] = lod

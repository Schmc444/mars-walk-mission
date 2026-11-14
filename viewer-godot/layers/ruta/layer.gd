extends Node3D
# Capa "ruta": el Perseverance sobre la ruta real. Paso 1: el rover sigue core.ride_s y queda estacionado al bajarse.

const ROVER_MODEL := "res://models/perseverance.glbd"

var world: WorldStreamer
var core: Node
var rover: Node3D
var rover_s := 0.0


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	rover = _load_rover()
	if rover:
		rover_s = core.ride_s
		_place()


func _process(_delta: float) -> void:
	if rover == null or not world.is_ready():
		return
	if core.riding:
		rover_s = core.ride_s
	_place()


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
	var acc: Array = [null]
	_aabb(holder, holder, acc)
	var bb: AABB = acc[0]
	scene.position = Vector3(-(bb.position.x + bb.size.x / 2.0), -bb.position.y, -(bb.position.z + bb.size.z / 2.0))
	return holder


func _aabb(n: Node, root: Node3D, acc: Array) -> void:
	if n is MeshInstance3D:
		var a: AABB = (root.global_transform.affine_inverse() * n.global_transform) * (n as MeshInstance3D).get_aabb()
		acc[0] = a if acc[0] == null else (acc[0] as AABB).merge(a)
	for ch in n.get_children():
		_aabb(ch, root, acc)

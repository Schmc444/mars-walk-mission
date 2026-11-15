extends Node3D
# Capa ingenuity: pone el helicoptero (marcador de posicion) y un pin en las coordenadas de ingenuity.json.
# Para mover Ingenuity solo se edita ingenuity.json. Ver LEEME.md.

const ALTO_PIN := 30.0
const COLOR := Color(0.2, 0.9, 1.0)

var world: WorldStreamer
var core: Node
var pin: Node3D
var heli: Node3D
var px := 0.0
var pz := 0.0
var reajuste := 0.0


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	var d = JSON.parse_string(FileAccess.get_file_as_string("res://layers/ingenuity/ingenuity.json"))
	if d == null:
		push_error("ingenuity: ingenuity.json no es JSON valido")
		return
	var xz: Vector2
	if d.has("x") and d.has("z"):
		xz = Vector2(d["x"], d["z"])
	else:
		xz = world.lonlat_to_world(d["lon"], d["lat"])
	px = xz.x
	pz = xz.y
	pin = _make_pin(d.get("nombre", "Ingenuity"), COLOR)
	add_child(pin)
	heli = _make_heli()
	add_child(heli)
	print("ingenuity: x=", snappedf(px, 0.1), " z=", snappedf(pz, 0.1))


# Modelo NASA/JPL (NASA-3D-Resources, el mismo de Luna Visor) a escala real: rotor de 1.21 m. Si no carga, queda el helicoptero provisional.
const ROTOR_M := 1.21


func _make_heli() -> Node3D:
	var ps = load("res://layers/ingenuity/ingenuity.glb")
	if ps is PackedScene:
		var m: Node3D = ps.instantiate()
		var bb := _aabb(m, Transform3D.IDENTITY)
		var span := maxf(bb.size.x, bb.size.z)
		if span > 1e-4:
			var k := ROTOR_M / span
			m.scale = Vector3(k, k, k)
			m.position = Vector3(-(bb.position.x + bb.size.x * 0.5) * k, -bb.position.y * k, -(bb.position.z + bb.size.z * 0.5) * k)
			var n := Node3D.new()
			n.add_child(m)
			print("ingenuity: modelo glb %.2f x %.2f x %.2f (sin escalar), factor %.4f -> alto real %.2f m" % [bb.size.x, bb.size.y, bb.size.z, k, bb.size.y * k])
			return n
	push_warning("ingenuity: no se pudo cargar ingenuity.glb, uso el helicoptero provisional")
	return _make_heli_provisional()


func _aabb(n: Node, xf: Transform3D) -> AABB:
	var r := AABB()
	var primero := true
	if n is MeshInstance3D and n.mesh != null:
		r = xf * (n as MeshInstance3D).get_aabb()
		primero = false
	for c in n.get_children():
		if c is Node3D:
			var cb := _aabb(c, xf * (c as Node3D).transform)
			if cb.size == Vector3.ZERO and cb.position == Vector3.ZERO:
				continue
			r = cb if primero else r.merge(cb)
			primero = false
	return r


func _make_heli_provisional() -> Node3D:
	var n := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.85, 0.85)
	var cuerpo := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.2, 0.3, 0.2)
	cuerpo.mesh = bm
	cuerpo.material_override = mat
	cuerpo.position.y = 0.5
	n.add_child(cuerpo)
	var pala := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(1.2, 0.02, 0.08)
	pala.mesh = pm
	pala.material_override = mat
	pala.position.y = 0.8
	n.add_child(pala)
	return n


# El terreno carga por distancia: se vuelve a pegar al suelo cada 0.5 s.
func _process(d: float) -> void:
	if pin == null:
		return
	reajuste -= d
	if reajuste > 0.0:
		return
	reajuste = 0.5
	var y := world.height_at(px, pz)
	pin.global_position = Vector3(px, y, pz)
	heli.global_position = Vector3(px, y, pz)


# --- pin: poste alto + esfera + nombre, pegado al suelo ---
func _make_pin(nombre: String, color: Color) -> Node3D:
	var n := Node3D.new()
	n.name = nombre
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	var poste := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.04
	cm.bottom_radius = 0.04
	cm.height = ALTO_PIN
	poste.mesh = cm
	poste.material_override = mat
	poste.position.y = ALTO_PIN * 0.5
	n.add_child(poste)
	var bola := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	bola.mesh = sm
	bola.material_override = mat
	bola.position.y = ALTO_PIN + 1.0
	n.add_child(bola)
	var t := Label3D.new()
	t.text = nombre
	t.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	t.no_depth_test = true
	t.fixed_size = true
	t.pixel_size = 0.0008
	t.font_size = 48
	t.modulate = Color(1, 1, 1)
	t.outline_size = 12
	t.position.y = ALTO_PIN + 3.0
	n.add_child(t)
	return n

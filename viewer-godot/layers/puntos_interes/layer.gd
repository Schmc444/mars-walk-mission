extends Node3D
# Capa puntos_interes: pone un pin en cada punto de puntos.json (lon/lat reales de Marte).
# Para agregar un punto NO hay que tocar este script: solo agregar una linea a puntos.json.
# Ver LEEME.md.

const ALTO_PIN := 30.0                 # alto del poste en metros (visible desde lejos)
const COLOR := Color(1.0, 0.75, 0.1)

var world: WorldStreamer
var core: Node
var items: Array = []                  # cada uno: [nodo, x, z]
var reajuste := 0.0


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	var datos = JSON.parse_string(FileAccess.get_file_as_string("res://layers/puntos_interes/puntos.json"))
	if datos == null:
		push_error("puntos_interes: puntos.json no es JSON valido")
		return
	for p in datos:
		var xz: Vector2
		if p.has("x") and p.has("z"):  # alternativa: metros del mundo
			xz = Vector2(p["x"], p["z"])
		else:
			xz = world.lonlat_to_world(p["lon"], p["lat"])
		var pin := _make_pin(p.get("nombre", "?"), COLOR)
		add_child(pin)
		items.append([pin, xz.x, xz.y])
		print("puntos_interes: ", p.get("nombre", "?"), " -> x=", snappedf(xz.x, 0.1), " z=", snappedf(xz.y, 0.1))


# El terreno carga por distancia: se vuelve a pegar al suelo cada 0.5 s para que no quede flotando o enterrado.
func _process(d: float) -> void:
	reajuste -= d
	if reajuste > 0.0:
		return
	reajuste = 0.5
	for it in items:
		it[0].global_position = Vector3(it[1], world.height_at(it[1], it[2]), it[2])


# --- pin: poste alto + esfera + nombre, pegado al suelo ---
func _make_pin(nombre: String, color: Color) -> Node3D:
	var n := Node3D.new()
	n.name = nombre
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	var poste := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.15
	cm.bottom_radius = 0.15
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

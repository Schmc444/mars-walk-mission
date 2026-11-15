extends Node3D
# Capa ruta_punteada: linea de segmentos sobre el suelo a lo largo de TODA la ruta del Perseverance.
# El terreno solo existe cerca del jugador, asi que los segmentos se generan en una ventana alrededor de donde estas.
# Se ajusta con las constantes de abajo; --sinpuntos la apaga.

const PASO_M := 3.0          # distancia entre inicios de segmento
const LARGO_M := 2.2         # largo de cada segmento (el hueco es PASO_M - LARGO_M)
const RADIO_M := 900.0       # hasta donde se dibuja la ruta desde el jugador
const ANCHO_M := 0.28        # ancho del segmento a corta distancia
const CRECE_CADA_M := 120.0  # el segmento se ensancha con la distancia para verse de lejos
const SOBRE_SUELO := 0.14
const COLOR := Color(1.0, 0.82, 0.2)
const REFRESCO_S := 1.0

var world: WorldStreamer
var core: Node
var mm: MultiMesh
var inst: MultiMeshInstance3D
var reloj := 0.0
var ult := Vector2(1e9, 1e9)


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	if "--sinpuntos" in OS.get_cmdline_user_args():
		set_process(false)
		return
	var disco := BoxMesh.new()
	disco.size = Vector3(1.0, 0.05, 1.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = COLOR
	disco.material = m
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = disco
	inst = MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.extra_cull_margin = RADIO_M * 2.0
	add_child(inst)


func _process(dt: float) -> void:
	if mm == null or not world.is_ready():
		return
	reloj += dt
	var p: Vector3 = core.cam.global_position
	var pxz := Vector2(p.x, p.z)
	if reloj < REFRESCO_S and pxz.distance_to(ult) < 15.0:
		return
	reloj = 0.0
	ult = pxz
	_reconstruir(p)


func _reconstruir(p: Vector3) -> void:
	var pxz := Vector2(p.x, p.z)
	var s0: float = world.route_nearest_s(pxz)
	var largo: float = world.route_length()
	var s: float = maxf(0.0, floorf((s0 - RADIO_M) / PASO_M) * PASO_M)
	var s_fin: float = minf(largo, s0 + RADIO_M)
	var xfs: Array[Transform3D] = []
	while s <= s_fin:
		var q: Vector2 = world.route_pos(s)
		var q2: Vector2 = world.route_pos(minf(s + LARGO_M, largo))
		var d := q.distance_to(pxz)
		if d <= RADIO_M and q2.distance_to(q) > 0.2:
			var h: float = world.height_at(q.x, q.y)
			var h2: float = world.height_at(q2.x, q2.y)
			if h != 0.0 and h2 != 0.0:
				var a := Vector3(q.x, h + SOBRE_SUELO, q.y)
				var b := Vector3(q2.x, h2 + SOBRE_SUELO, q2.y)
				var ancho := ANCHO_M * (1.0 + d / CRECE_CADA_M)
				var bas := Basis.looking_at(b - a, Vector3.UP) * Basis.from_scale(Vector3(ancho, 1.0, a.distance_to(b)))
				xfs.append(Transform3D(bas, (a + b) * 0.5))
		s += PASO_M
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])

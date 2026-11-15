extends Node3D
# Capa ruta_punteada: linea punteada sobre el suelo a lo largo de TODA la ruta del Perseverance.
# El terreno solo existe cerca del jugador, asi que los puntos se generan en una ventana alrededor de donde estas.
# Se ajusta con las constantes de abajo; --sinpuntos la apaga.

const PASO_M := 6.0          # distancia entre puntos
const RADIO_M := 900.0       # hasta donde se dibuja la ruta desde el jugador
const PUNTO_M := 0.35        # radio del punto a corta distancia
const CRECE_CADA_M := 120.0  # el punto crece con la distancia para verse de lejos
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
	var disco := CylinderMesh.new()
	disco.top_radius = 1.0
	disco.bottom_radius = 1.0
	disco.height = 0.06
	disco.radial_segments = 12
	disco.rings = 1
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
		var d := q.distance_to(pxz)
		if d <= RADIO_M:
			var h: float = world.height_at(q.x, q.y)
			if h != 0.0:
				var r := PUNTO_M * (1.0 + d / CRECE_CADA_M)
				xfs.append(Transform3D(Basis.from_scale(Vector3(r, 1.0, r)), Vector3(q.x, h + SOBRE_SUELO, q.y)))
		s += PASO_M
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])

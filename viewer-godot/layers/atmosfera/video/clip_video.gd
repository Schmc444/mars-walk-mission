extends Node
# Grabacion de clips para el video del proyecto (no se usa en la simulacion normal).
# Guarda cada cuadro de la ventana como JPG (a la resolucion real de la ventana) y cierra solo. Ejemplo:
#   godot --path viewer-godot --xr-mode off --fullscreen --fixed-fps 30 \
#         -- --world=../world --sol=1063 --layers=atmosfera,piedras --atm-video=portada --atm-video-dir=C:/ruta/cuadros
# --fixed-fps 30 hace que cada cuadro avance exactamente 1/30 s aunque el PC vaya lento (movimiento fluido).
# Despues: ffmpeg -framerate 30 -i cuadros/%05d.jpg ...
# (El Movie Maker de Godot graba al tamanio del proyecto, 1152x648; por eso se guardan los cuadros a mano.)
# Clips: "portada" (paneo lento a ras de suelo en el punto A) y "orbita" (toma cenital que baja hasta el punto A).
# Mientras graba: oculta los textos de pantalla y mueve la camara (y, en "orbita", al jugador bajo la camara para que
# el terreno cargue ahi, y apaga la niebla). No cambia archivos del nucleo.

const ESPERA_FRAMES := 240        # cuadros con el terreno listo antes de empezar a grabar
const ARRANQUE := 0.2             # s con la camara ya en su lugar antes de guardar cuadros (latencia de la GPU)

# Clip "orbita": camara mirando hacia abajo, norte arriba. Puntos clave: [t (s), x, z (m del mundo), altura (m)].
# Empieza sobre la franja HiRISE del proyecto, cerca del delta occidental de Jezero, y baja al punto A (inicio del
# sol 1063). Mas arriba de ~1.5 km se ve el borde de los datos de alta resolucion (bloques claros del anillo lejano):
# la franja de terreno HiRISE del proyecto es angosta de norte a sur alrededor de la ruta.
const ORBITA := [[0.0, -6990.0, -2800.0, 1400.0], [5.0, -6966.0, -2779.0, 300.0]]

var capa
var core
var clip := "portada"
var carpeta := ""
var n_cuadro := 0
var fase := 0
var listos := 0
var t := -ARRANQUE                # tiempo del clip; negativo = arranque, no se guarda
var yaw0 := 0.0
var duracion := 5.0
var muestras := false             # --atm-video-muestras: imprime los valores del panel (para revisar cuanto varian)

# Clips "caminata" y "vistas": caminar por la ruta desde el punto A (el segundo sigue donde termina el primero).
const VEL_CAMINAR := 4.0          # m/s
const S_INICIO := {"caminata": 0.0, "vistas": 20.0}       # m recorridos desde el inicio del sol 1063
# Clip "vistas": una vista por segundo (-1 = sin filtro): normal, calor, radiacion, oxigeno, polvo, presion
const VISTAS_SEQ := [-1, 0, 1, 2, 4, 3]
var s0_ruta := 0.0
var yaw_suave := INF

# Clip "peligro": en el punto A mirando las lomas; a los 0.4 s se activa la capa de peligro por pendiente (tecla H).
const PELIGRO_DUR := 1.2
const PELIGRO_ON := 0.4
var peligro_activado := false
# Clip "mapa": vista cenital del tramo A -> B con el peligro activo y las rutas del informe (informe/datos/caminos.csv):
# real (azul), recta A -> B (blanca, punteada) y segura con A* (verde, se dibuja de A a B).
const MAPA_DUR := 1.8
const MAPA_CENTRO := Vector2(-7123.0, -2806.0)   # algo al norte del tramo: las rutas quedan debajo del panel
const MAPA_ALTURA := 155.0
const MAPA_TRAZO := [0.25, 1.45]     # s en que la ruta segura empieza y termina de dibujarse
var caminos := {}                   # nombre -> PackedVector2Array
var lineas := {}                    # nombre -> MeshInstance3D


func _ready() -> void:
	if clip == "orbita":
		duracion = ORBITA[ORBITA.size() - 1][0]
	elif clip == "vistas":
		duracion = float(VISTAS_SEQ.size())
	elif clip == "peligro":
		duracion = PELIGRO_DUR
		_cargar_caminos()
	elif clip == "mapa":
		duracion = MAPA_DUR
		_cargar_caminos()
	if clip in S_INICIO:
		s0_ruta = capa.world.route_s_of_sol(capa.TRAMO_SOL_A) + S_INICIO[clip]


func _process(delta: float) -> void:
	_ocultar_textos()
	if fase == 0:
		if clip == "orbita":
			_orbita(0.0)               # la camara ya espera en su lugar inicial (y el terreno carga ahi)
		elif clip in S_INICIO:
			_caminar(0.0)
		elif clip == "mapa":
			_mapa(0.0)
		if capa.world.is_ready() and not capa.campo_d1.is_empty():
			listos += 1
		if listos >= ESPERA_FRAMES:
			fase = 1
			yaw0 = core.yaw
			if clip == "peligro" and caminos.has("ruta_real"):
				# mirar hacia donde sigue la ruta (unos 60 m adelante) y dibujarla sobre el suelo, como se ve en VR
				var pr: PackedVector2Array = caminos["ruta_real"]
				var d: Vector2 = pr[mini(6, pr.size() - 1)] - pr[0]
				yaw0 = atan2(-d.x, -d.y)
				caminos["ruta_adelante"] = pr.slice(2)          # desde ~20 m adelante (no tapa la esquina de la toma)
				_cinta("ruta_adelante", 1.0, 1.4, Color(0.25, 0.55, 1.0), false, false, 0.25)
			DirAccess.make_dir_recursive_absolute(carpeta)
			print("VIDEO_INICIO ", get_viewport().get_visible_rect().size)
		return
	if t > 0.0:                        # el cuadro dibujado con el estado del paso anterior
		get_viewport().get_texture().get_image().save_jpg("%s/%05d.jpg" % [carpeta, n_cuadro], 0.95)
		n_cuadro += 1
	t += delta
	var tc := maxf(t, 0.0)
	match clip:
		"portada":
			# paneo lento de derecha a izquierda (24 grados en 5 s), con entrada y salida suaves
			var s := smoothstep(0.0, 1.0, clampf(tc / duracion, 0.0, 1.0))
			core.yaw = yaw0 + deg_to_rad(12.0) - deg_to_rad(24.0) * s
			core.pitch = deg_to_rad(-3.0)
		"orbita":
			_orbita(tc)
		"caminata":
			_caminar(tc)
		"vistas":
			_caminar(tc)
			_poner_vista(VISTAS_SEQ[mini(int(tc), VISTAS_SEQ.size() - 1)])
		"peligro":
			var s := smoothstep(0.0, 1.0, clampf(tc / duracion, 0.0, 1.0))
			core.yaw = yaw0 + deg_to_rad(5.0) - deg_to_rad(8.0) * s
			core.pitch = deg_to_rad(-7.0)
			if tc >= PELIGRO_ON and not peligro_activado:
				_tecla_h()
		"mapa":
			_mapa(tc)
	if muestras and n_cuadro % 15 == 0 and t > 0.0:
		var txt := PackedStringArray()
		for c in capa.FILAS_PANEL:
			txt.append(capa.valores_lbl[c].text)
		print("PANEL t=%.1f  %s" % [tc, " | ".join(txt)])
	if t > duracion + 0.001:
		print("VIDEO_FIN cuadros=", n_cuadro)
		get_tree().quit()


# Interpola entre puntos clave (suave) y pone la camara arriba mirando hacia abajo, norte arriba.
# El jugador se baja del rover y se mueve bajo la camara: el nucleo carga el terreno alrededor del jugador.
# La niebla de la escena se apaga mientras se graba (desde kilometros de altura taparia el suelo).
func _orbita(tc: float) -> void:
	var env: Environment = get_viewport().world_3d.environment
	if env == null:
		var we := get_tree().root.find_children("*", "WorldEnvironment", true, false)
		if not we.is_empty():
			env = (we[0] as WorldEnvironment).environment
	if env and env.fog_enabled:
		env.fog_enabled = false
	var k := 0
	while k < ORBITA.size() - 2 and tc > ORBITA[k + 1][0]:
		k += 1
	var a: Array = ORBITA[k]
	var b: Array = ORBITA[k + 1]
	var u := smoothstep(0.0, 1.0, clampf((tc - a[0]) / (b[0] - a[0]), 0.0, 1.0))
	var x := lerpf(a[1], b[1], u)
	var z := lerpf(a[2], b[2], u)
	var alt := exp(lerpf(log(a[3]), log(b[3]), u))           # la altura baja en escala logaritmica (zoom parejo)
	core.riding = false
	core.origin.position = Vector3(x, capa.world.height_at(x, z), z)
	core.cam.position = Vector3(0.0, alt, 0.0)
	core.yaw = 0.0
	core.pitch = deg_to_rad(-90.0)


# Caminar por la ruta: el jugador va a pie por la polilinea de Perseverance, mirando hacia donde avanza.
func _caminar(tc: float) -> void:
	var s: float = s0_ruta + VEL_CAMINAR * tc
	var p: Vector2 = capa.world.route_pos(s)
	var adelante: Vector2 = capa.world.route_pos(s + 25.0) - p        # direccion promedio de los proximos 25 m
	var yaw_obj := atan2(-adelante.x, -adelante.y)                   # yaw 0 = mirar al norte (-z)
	if yaw_suave == INF:
		yaw_suave = yaw_obj
	yaw_suave = lerp_angle(yaw_suave, yaw_obj, 0.05)                 # sin tirones en los quiebres de la ruta
	core.riding = false
	core.origin.position = Vector3(p.x, capa.world.height_at(p.x, p.y), p.y)
	core.yaw = yaw_suave + deg_to_rad(8.0)                           # un poco a la izquierda: el panel no tapa el camino
	core.pitch = deg_to_rad(-10.0)


# Simula la tecla H (capa de peligro por pendiente del nucleo), como si la apretara el usuario.
func _tecla_h() -> void:
	peligro_activado = true
	var e := InputEventKey.new()
	e.keycode = KEY_H
	e.physical_keycode = KEY_H
	e.pressed = true
	Input.parse_input_event(e)
	var e2 := e.duplicate()
	e2.pressed = false
	Input.parse_input_event(e2)


func _cargar_caminos() -> void:
	var f := FileAccess.open("res://layers/atmosfera/informe/datos/caminos.csv", FileAccess.READ)
	if f == null:
		push_warning("clip mapa: no encuentro informe/datos/caminos.csv (correr --atm-analisis)")
		return
	f.get_line()
	while not f.eof_reached():
		var c := f.get_line().split(",")
		if c.size() < 3:
			continue
		if not caminos.has(c[0]):
			caminos[c[0]] = PackedVector2Array()
		caminos[c[0]].append(Vector2(float(c[1]), float(c[2])))
	# A* trabaja en una grilla de 10 m: se une la ruta segura a los puntos exactos A y B
	if caminos.has("ruta_optima") and caminos.has("ruta_real"):
		var r: PackedVector2Array = caminos["ruta_real"]
		var o: PackedVector2Array = caminos["ruta_optima"]
		o.insert(0, r[0])
		o.append(r[r.size() - 1])
		caminos["ruta_optima"] = o


# Vista cenital fija sobre el tramo (norte arriba), peligro activo, y las rutas dibujadas como cintas sobre el suelo.
func _mapa(tc: float) -> void:
	core.riding = false
	core.origin.position = Vector3(MAPA_CENTRO.x, capa.world.height_at(MAPA_CENTRO.x, MAPA_CENTRO.y), MAPA_CENTRO.y)
	core.cam.position = Vector3(0.0, MAPA_ALTURA, 0.0)
	core.yaw = 0.0
	core.pitch = deg_to_rad(-90.0)
	var env: Environment = get_viewport().world_3d.environment
	if env and env.fog_enabled:
		env.fog_enabled = false
	if not peligro_activado:
		_tecla_h()
	if fase == 0:
		return
	if lineas.is_empty() and caminos.has("ruta_real"):
		var pr: PackedVector2Array = caminos["ruta_real"]
		_letra("A", pr[0])
		_letra("B", pr[pr.size() - 1])
	var u := clampf((tc - MAPA_TRAZO[0]) / (MAPA_TRAZO[1] - MAPA_TRAZO[0]), 0.0, 1.0)
	_cinta("ruta_real", 1.0, 2.2, Color(0.25, 0.55, 1.0), false)
	_cinta("ruta_recta", 1.0, 2.2, Color(1, 1, 1), true)
	_cinta("ruta_optima", smoothstep(0.0, 1.0, u), 4.0, Color(0.15, 1.0, 0.35), false)


# Letra grande (A o B) sobre el terreno, siempre visible y de frente a la camara.
func _letra(txt: String, p: Vector2) -> void:
	var l := Label3D.new()
	l.text = txt
	l.font_size = 220
	l.pixel_size = 0.04
	l.outline_size = 40
	l.modulate = Color(1, 1, 1)
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 40
	l.position = Vector3(p.x, capa.world.height_at(p.x, p.y) + 2.0, p.y + 9.0)   # un poco al sur del punto
	add_child(l)


# Cinta de ancho fijo (m) sobre el terreno siguiendo un camino hasta la fraccion `frac` de su largo.
# encima = true: se ve siempre (mapa desde arriba); false: la tapan las lomas (vista a ras de suelo). alto: m sobre el suelo.
func _cinta(nombre: String, frac: float, ancho: float, col: Color, punteada: bool, encima: bool = true, alto: float = 0.5) -> void:
	if not caminos.has(nombre):
		return
	var pts: PackedVector2Array = caminos[nombre]
	var largo := 0.0
	for i in range(1, pts.size()):
		largo += pts[i - 1].distance_to(pts[i])
	var hasta := largo * frac
	if hasta < 1.0:                      # todavia no empieza a dibujarse
		if lineas.has(nombre):
			(lineas[nombre] as MeshInstance3D).mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var acum := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var l := a.distance_to(b)
		if acum >= hasta or l < 0.01:
			acum += l
			continue
		var paso := 2.0
		var n := maxi(int(l / paso), 1)
		for k in n:
			var s0 := float(k) / n
			var s1 := float(k + 1) / n
			if acum + l * s0 >= hasta:
				break
			if punteada and (int((acum + l * s0) / 8.0) % 2 == 1):
				continue
			var p0 := a.lerp(b, s0)
			var p1 := a.lerp(b, minf(s1, (hasta - acum) / l))
			var d := (p1 - p0).normalized()
			var lado := Vector2(-d.y, d.x) * ancho * 0.5
			var q := [p0 + lado, p0 - lado, p1 + lado, p1 - lado]
			var v3 := []
			for q2 in q:
				v3.append(Vector3(q2.x, capa.world.height_at(q2.x, q2.y) + alto, q2.y))
			for idx in [0, 1, 2, 2, 1, 3]:
				im.surface_add_vertex(v3[idx])
		acum += l
	im.surface_end()
	if not lineas.has(nombre):
		var mi := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		mat.no_depth_test = encima
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 30
		mat.disable_fog = true
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 1000.0
		add_child(mi)
		lineas[nombre] = mi
	(lineas[nombre] as MeshInstance3D).mesh = im if im.get_surface_count() > 0 else null


func _poner_vista(v: int) -> void:
	if v == capa.vista:
		return
	if v < 0:
		capa.alternar_vista(capa.vista)      # apaga la vista activa
	else:
		capa.alternar_vista(v)


const ESCALA_PANEL := 1.6         # el panel se agranda en el video para que se lea en pantallas chicas

func _ocultar_textos() -> void:
	if core.get("hud") != null:
		core.hud.visible = false
	if capa.ui:
		capa.ui.visible = true               # el panel de los 5 parametros se ve en todos los clips
		if capa.ui.visible and capa.canvas:
			# mas grande y sin la linea de hora/bateria (la hora real del PC no tiene sentido en el video);
			# se recoloca despues de que la capa lo pone en su lugar (los hijos se procesan despues del padre)
			if capa.estado_lbl.visible:
				capa.estado_lbl.visible = false
				capa.ui.custom_minimum_size.y = 0.0
				capa.ui.reset_size()             # el recuadro se encoge al quitar la linea
			capa.ui.scale = Vector2(ESCALA_PANEL, ESCALA_PANEL)
			var vs := get_viewport().get_visible_rect().size
			capa.ui.position = Vector2(vs.x * (1.0 - capa.PANEL_MARGEN_X) - capa.ui.size.x * ESCALA_PANEL, vs.y * capa.PANEL_MARGEN_Y)

extends Node3D
# CAPA ATMOSFERA (Kevin). Panel lateral con 5 valores (oxigeno, radiacion, temperatura, presion, polvo) + neblina de colores por zonas.
#   F1 polvo · F2 radiacion · F3 oxigeno · F7 presion · F8 temperatura   (una neblina a la vez; repetir la tecla la apaga)
#   F6 mostrar u ocultar el panel
# Valores base reales (NASA, ver LEEME.md); la variacion de un lugar a otro es SINTETICA (salvo la presion por la altura).
# Opciones de prueba (despues de --): --atm=polvo|radiacion|oxigeno|presion|temperatura
#   --atm-sol=N (forzar el sol)  --atm-hora=H (hora local 0-24; por defecto sale del sol de la escena)
#   --atm-panel-3d (ver el panel como en VR, sin visor)
# En VR el panel flota pegado a la vista. Para botones del control llama a activar(POLVO/RAD/O2/PRES/TEMP) o alternar_panel()
# (los botones aun no estan asignados).

const Modelo := preload("modelo.gd")
const SHADER_NEBLINA := preload("neblina.gdshader")

const POLVO := 0
const RAD := 1
const O2 := 2
const PRES := 3
const TEMP := 4
const NOMBRES_PANEL := ["Polvo", "Radiación", "Oxígeno", "Presión", "Temperatura"]
# tono claro, medio, oscuro (claro = poco/bueno, oscuro = mucho/malo)
const RAMPAS := [
	[Color("#ffd3e6"), Color("#c86bb0"), Color("#3d0b4a")],   # polvo: rosado -> morado
	[Color("#d4f7cf"), Color("#47b552"), Color("#0b3a12")],   # radiacion: verde claro -> verde oscuro
	[Color("#d6efff"), Color("#3d82d6"), Color("#071a4d")],   # oxigeno: azul claro (hay O2) -> azul oscuro (falta)
	[Color("#fff3c4"), Color("#e0b030"), Color("#4a3300")],   # presion: amarillo claro (mas) -> cafe oscuro (menos)
	[Color("#dcfbf6"), Color("#2fb3a8"), Color("#06302e")],   # temperatura: turquesa claro (menos frio) -> oscuro (mas frio)
]
const ALTO_CAPA := [45.0, 40.0, 40.0, 40.0, 25.0]
# presion y temperatura: la escala es local (el valor medio queda en el centro), asi que su neblina de volumen va baja
# y el contraste se ve sobre todo en la capa pegada al suelo
const DENSIDAD := [0.006, 0.005, 0.005, 0.0012, 0.0012]

const N := 160                  # mapa de valores N x N alrededor del jugador
const CELDA := 20.0             # m por casilla -> 3.2 km de lado
const FILAS_POR_FRAME := 6
const RECENTRAR_M := 700.0
const ANCHO_PANEL := 250
const LETRA := 16
const FILAS_PANEL := [O2, RAD, TEMP, PRES, POLVO]      # orden de las filas del panel

var world: WorldStreamer
var core: Node
var m := Modelo.new()

var modo := -1
var ver_panel := true
var sol_forzado := -1.0

# mapa de valores (front = el que usa el shader; gen = el que se esta calculando)
var campo_img: Image
var campo_tex: ImageTexture
var campo_origen := Vector2(1e9, 1e9)
var campo_sol := -1000.0
var gen_img: Image
var gen_origen := Vector2.ZERO
var gen_sol := 0.0
var gen_fila := -1
var gen_fase := 0
var gen_h := PackedFloat32Array()
# segundo mapa: R presion (Pa), G temperatura (K), en valores reales
var campo2_img: Image
var campo2_tex: ImageTexture
var gen2_img: Image
# por canal (polvo, rad, O2, presion, temp): p50 y p95 de la intensidad 0..1 en el mapa actual
var rangos := [Vector2(0.3, 0.9), Vector2(0.3, 0.9), Vector2(0.3, 0.9), Vector2(0.3, 0.9), Vector2(0.3, 0.9)]
# escala de color de presion y temperatura (valor real con mas / con menos): centrada en el valor del lugar
var rango_pres := Vector2(800.0, 750.0)
var rango_temp := Vector2(230.0, 218.0)
var hora := 9.0                 # hora local (LMST)
var hora_forzada := false
var sol_vec := Vector3(0.5, 0.57, 0.6).normalized()   # direccion hacia el sol (sale de la luz de la escena)

var neblina: MeshInstance3D
var mat: ShaderMaterial
var remol: Array = []

var ui: PanelContainer
var valores_lbl := {}           # canal -> Label con el valor
var canvas: CanvasLayer
var vista_vr: SubViewport
var panel_3d: MeshInstance3D
var en_3d := false

var _t_rem := 0.0
var _t_ui := 0.0
var sol_actual := 0.0
var v := {}                     # valores en la posicion del jugador


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	var args := OS.get_cmdline_user_args()
	en_3d = bool(core.get("in_xr")) or "--atm-panel-3d" in args
	_crear_neblina()
	_crear_panel()
	_leer_sol_escena()
	for a in args:
		if a.begins_with("--atm-sol="):
			sol_forzado = float(a.get_slice("=", 1))
		elif a.begins_with("--atm-hora="):
			hora = fposmod(float(a.get_slice("=", 1)), 24.0)
			hora_forzada = true
	for a in args:
		match a:
			"--atm=polvo": activar(POLVO)
			"--atm=radiacion": activar(RAD)
			"--atm=oxigeno": activar(O2)
			"--atm=presion": activar(PRES)
			"--atm=temperatura": activar(TEMP)


# La escena tiene un sol fijo (DirectionalLight3D del nucleo; solo se lee, no se cambia).
# De su elevacion y si esta al este o al oeste sale la hora local aproximada (latitud de Jezero ~18.4 N).
func _leer_sol_escena() -> void:
	var luces := get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	if luces.is_empty():
		return
	var l: DirectionalLight3D = luces[0]
	sol_vec = l.global_transform.basis.z.normalized()      # la luz viaja hacia -z: el sol esta hacia +z
	if hora_forzada:
		return
	var lat := deg_to_rad(world.world_to_lonlat(0.0, 0.0).y)
	var c := clampf(sol_vec.y / cos(lat), -1.0, 1.0)         # equinoccio: sin(elev) = cos(lat) cos(angulo horario)
	var horas_desde_mediodia := rad_to_deg(acos(c)) / 15.0
	hora = 12.0 - horas_desde_mediodia if sol_vec.x > 0.0 else 12.0 + horas_desde_mediodia   # x = este


# ---------------------------------------------------------------- teclas

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.keycode:
		KEY_F1: activar(POLVO)
		KEY_F2: activar(RAD)
		KEY_F3: activar(O2)
		KEY_F6: alternar_panel()
		KEY_F7: activar(PRES)
		KEY_F8: activar(TEMP)
		_: return
	get_viewport().set_input_as_handled()


func activar(nuevo: int) -> void:
	modo = -1 if modo == nuevo else nuevo     # solo una neblina activa
	neblina.visible = modo >= 0
	if modo >= 0:
		var r: Array = RAMPAS[modo]
		mat.set_shader_parameter("modo", modo)
		mat.set_shader_parameter("color_claro", r[0])
		mat.set_shader_parameter("color_medio", r[1])
		mat.set_shader_parameter("color_oscuro", r[2])
		mat.set_shader_parameter("alto_capa", ALTO_CAPA[modo])
		mat.set_shader_parameter("densidad", DENSIDAD[modo])
		mat.set_shader_parameter("rango_suelo", rangos[modo])
		_subir_rango_local()
	_t_ui = 0.0


func alternar_panel() -> void:
	ver_panel = not ver_panel
	ui.visible = ver_panel
	if panel_3d:
		panel_3d.visible = ver_panel


# ---------------------------------------------------------------- cada frame

func _process(delta: float) -> void:
	if world == null:
		return
	var p: Vector3 = core.origin.global_position
	_t_rem -= delta
	_t_ui -= delta
	if _t_ui <= 0.0:
		sol_actual = _sol(p)
	_generar_campo(p)
	if _t_rem <= 0.0:
		_t_rem = 0.1
		remol = m.remolinos(sol_actual, p.x, p.z, Time.get_ticks_msec() / 1000.0, 1200.0, 16)
		_subir_remolinos()
	if _t_ui <= 0.0:
		_t_ui = 0.2
		_valores(p)
		_actualizar_panel()
	if canvas and ver_panel:
		var vs := get_viewport().get_visible_rect().size
		ui.position = Vector2(vs.x - ui.size.x - 12.0, 64.0)      # lateral derecho


func _sol(p: Vector3) -> float:
	if sol_forzado >= 0.0:
		return sol_forzado
	var s: float = core.ride_s if core.riding else world.route_nearest_s(Vector2(p.x, p.z))
	return float(world.route_sol_at(s))


func _valores(p: Vector3) -> void:
	var h := world.height_at(p.x, p.z)
	var vec := 0.0
	for d in [Vector2(40, 0), Vector2(-40, 0), Vector2(0, 40), Vector2(0, -40), Vector2(28, 28), Vector2(-28, 28), Vector2(28, -28), Vector2(-28, -28)]:
		vec += world.height_at(p.x + d.x, p.z + d.y)
	var hond := vec / 8.0 - h
	var tau_f := m.tau_fondo(sol_actual)
	var tau_p := m.tau_parches(sol_actual, p.x, p.z)
	var tau_r := m.tau_remolinos(p.x, p.z, remol)
	var gx := (world.height_at(p.x + 20.0, p.z) - world.height_at(p.x - 20.0, p.z)) / 40.0
	var gz := (world.height_at(p.x, p.z + 20.0) - world.height_at(p.x, p.z - 20.0)) / 40.0
	var ins := m.insolacion_rel(gx, gz, sol_vec)
	v = {
		"h": h, "presion": m.presion(sol_actual, h), "tau": tau_f + tau_p + tau_r, "tau_fondo": tau_f,
		"rad": m.radiacion(sol_actual, h, hond, p.x, p.z), "po2": m.po2(sol_actual, h, p.x, p.z),
		"fo2": m.fraccion_o2(sol_actual), "ls": m.ls_de_sol(sol_actual),
		"temp": m.temperatura(sol_actual, hora, tau_f, ins, hond, p.x, p.z),
	}


# ---------------------------------------------------------------- mapa de valores (se calcula de a poco)

func _generar_campo(p: Vector3) -> void:
	if gen_fila < 0:
		var centro := campo_origen + Vector2.ONE * (N * CELDA * 0.5)
		var lejos := centro.distance_to(Vector2(p.x, p.z)) > RECENTRAR_M
		if lejos or absf(sol_actual - campo_sol) >= 1.0:
			gen_origen = (Vector2(p.x, p.z) - Vector2.ONE * (N * CELDA * 0.5)).snapped(Vector2(CELDA, CELDA))
			gen_sol = sol_actual
			gen_img = Image.create_empty(N, N, false, Image.FORMAT_RGBAF)
			gen2_img = Image.create_empty(N, N, false, Image.FORMAT_RGF)
			gen_h.resize(N * N)
			gen_fila = 0
			gen_fase = 0
		return
	var fin := mini(gen_fila + FILAS_POR_FRAME, N)
	if gen_fase == 0:
		for j in range(gen_fila, fin):
			for i in N:
				gen_h[j * N + i] = world.height_at(gen_origen.x + (i + 0.5) * CELDA, gen_origen.y + (j + 0.5) * CELDA)
	else:
		var tau_f := m.tau_fondo(gen_sol)
		for j in range(gen_fila, fin):
			for i in N:
				var x := gen_origen.x + (i + 0.5) * CELDA
				var z := gen_origen.y + (j + 0.5) * CELDA
				var h := gen_h[j * N + i]
				var hond := (_hg(i - 2, j) + _hg(i + 2, j) + _hg(i, j - 2) + _hg(i, j + 2)) * 0.25 - h
				var tp := m.t_polvo(tau_f + m.tau_parches(gen_sol, x, z))
				var tr := m.t_rad(m.radiacion(gen_sol, h, hond, x, z))
				var to := m.t_o2_falta(m.po2(gen_sol, h, x, z))
				gen_img.set_pixel(i, j, Color(tp, tr, to, h))
				var ins := m.insolacion_rel((_hg(i + 1, j) - _hg(i - 1, j)) / (2.0 * CELDA), (_hg(i, j + 1) - _hg(i, j - 1)) / (2.0 * CELDA), sol_vec)
				gen2_img.set_pixel(i, j, Color(m.presion(gen_sol, h), m.temperatura(gen_sol, hora, tau_f, ins, hond, x, z), 0.0))
	gen_fila = fin
	if gen_fila >= N:
		if gen_fase == 0:
			gen_fase = 1
			gen_fila = 0
		else:
			gen_fila = -1
			campo_img = gen_img
			campo2_img = gen2_img
			campo_origen = gen_origen
			campo_sol = gen_sol
			if campo_tex == null:
				campo_tex = ImageTexture.create_from_image(campo_img)
				campo2_tex = ImageTexture.create_from_image(campo2_img)
				mat.set_shader_parameter("campo", campo_tex)
				mat.set_shader_parameter("campo2", campo2_tex)
			else:
				campo_tex.update(campo_img)
				campo2_tex.update(campo2_img)
			mat.set_shader_parameter("campo_origen", campo_origen)
			mat.set_shader_parameter("campo_tam", N * CELDA)
			_calcular_rangos()
			if modo >= 0:
				mat.set_shader_parameter("rango_suelo", rangos[modo])
			_subir_rango_local()


const MUESTRA := 7              # para los percentiles basta con 1 de cada 7 casillas (~3600 por canal)

# Percentiles 50 y 95 de cada canal del mapa: el shader resalta en el suelo lo que esta por encima de la mediana
# (zonas relativas a lo que te rodea; el color sigue siendo el valor de la leyenda).
# Presion y temperatura: ademas, la escala de color se centra en la mediana del mapa (+-25 Pa, +-6 K).
func _calcular_rangos() -> void:
	var d1 := campo_img.get_data().to_float32_array()       # RGBA por casilla
	var d2 := campo2_img.get_data().to_float32_array()      # RG por casilla
	var n := (N * N + MUESTRA - 1) / MUESTRA
	var crudos: Array = []
	for c in 5:
		var a := PackedFloat32Array()
		a.resize(n)
		for s in n:
			var k := s * MUESTRA
			a[s] = d1[k * 4 + c] if c < 3 else d2[k * 2 + c - 3]
		a.sort()
		crudos.append(a)
	rango_pres = _escala_local(crudos[PRES], Modelo.PRES_MEDIO_RANGO)   # (claro = mas, oscuro = menos)
	rango_temp = _escala_local(crudos[TEMP], Modelo.TEMP_MEDIO_RANGO)
	for c in 5:
		var a: PackedFloat32Array = crudos[c]
		var lo := a[n / 2]
		var hi := a[n * 95 / 100]
		if c == PRES or c == TEMP:          # menos presion / menos temperatura = mas intenso: percentiles 50 y 5
			var r: Vector2 = rango_pres if c == PRES else rango_temp
			lo = _intensidad(a[n / 2], r)
			hi = _intensidad(a[n * 5 / 100], r)
		rangos[c] = Vector2(lo, maxf(hi, lo + 0.08))        # si el mapa es casi parejo, no resaltar ruido


# Escala de color (claro, oscuro) = percentiles 95 y 5 del mapa, con un ancho minimo para no exagerar el ruido.
func _escala_local(a: PackedFloat32Array, medio_min: float) -> Vector2:
	var n := a.size()
	var med := a[n / 2]
	return Vector2(maxf(a[n * 95 / 100], med + medio_min), minf(a[n * 5 / 100], med - medio_min))


# Valor real -> intensidad 0 (claro) .. 1 (oscuro) con la escala (claro, oscuro).
func _intensidad(x: float, r: Vector2) -> float:
	return clampf((r.x - x) / (r.x - r.y), 0.0, 1.0)


func _subir_rango_local() -> void:
	mat.set_shader_parameter("rango_local", rango_pres if modo == PRES else rango_temp)


func _hg(i: int, j: int) -> float:
	return gen_h[clampi(j, 0, N - 1) * N + clampi(i, 0, N - 1)]


# ---------------------------------------------------------------- neblina

func _crear_neblina() -> void:
	mat = ShaderMaterial.new()
	mat.shader = SHADER_NEBLINA
	mat.render_priority = 10
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	neblina = MeshInstance3D.new()
	neblina.name = "NeblinaAtmosfera"
	neblina.mesh = q
	neblina.material_override = mat
	neblina.extra_cull_margin = 16384.0
	neblina.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	neblina.position = Vector3(0, 0, -1)
	neblina.visible = false
	core.cam.add_child(neblina)


func _subir_remolinos() -> void:
	var arr := PackedVector4Array()
	for r in remol:
		arr.append(r)
	mat.set_shader_parameter("n_remolinos", arr.size())
	while arr.size() < 16:
		arr.append(Vector4.ZERO)
	mat.set_shader_parameter("remolinos", arr)


# ---------------------------------------------------------------- panel

func _crear_panel() -> void:
	ui = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.02, 0.04, 0.62)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	ui.add_theme_stylebox_override("panel", sb)
	ui.custom_minimum_size = Vector2(ANCHO_PANEL, 0)
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 6)
	ui.add_child(g)
	for canal in FILAS_PANEL:
		var muestra := ColorRect.new()                  # el color de la neblina de ese parametro
		muestra.color = RAMPAS[canal][1]
		muestra.custom_minimum_size = Vector2(LETRA, LETRA)
		muestra.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		g.add_child(muestra)
		var nombre := _label()
		nombre.text = NOMBRES_PANEL[canal]
		nombre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(nombre)
		var valor := _label()
		valor.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		g.add_child(valor)
		valores_lbl[canal] = valor
	if en_3d:
		vista_vr = SubViewport.new()
		vista_vr.transparent_bg = true
		vista_vr.disable_3d = true
		vista_vr.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vista_vr.size = Vector2i(ANCHO_PANEL, 200)
		add_child(vista_vr)
		vista_vr.add_child(ui)
		var pm := StandardMaterial3D.new()
		pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pm.no_depth_test = true
		pm.cull_mode = BaseMaterial3D.CULL_DISABLED
		pm.albedo_texture = vista_vr.get_texture()
		pm.render_priority = 20
		panel_3d = MeshInstance3D.new()
		panel_3d.name = "PanelAtmosfera"
		panel_3d.mesh = QuadMesh.new()
		panel_3d.material_override = pm
		panel_3d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		panel_3d.extra_cull_margin = 10.0
		panel_3d.rotation = Vector3(0, -0.42, 0)       # mirando hacia el ojo
		core.cam.add_child(panel_3d)
	else:
		canvas = CanvasLayer.new()
		canvas.layer = 5
		add_child(canvas)
		canvas.add_child(ui)


func _label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", LETRA)
	l.add_theme_color_override("font_color", Color(0.95, 0.95, 0.92))
	return l


# Ajusta el tamanio del panel flotante (VR) al contenido: 1 px = 1 mm, a 1 m de los ojos, a la derecha.
func _ajustar_panel_3d() -> void:
	var tam := ui.get_combined_minimum_size()
	var ancho := maxi(int(ceil(tam.x)), ANCHO_PANEL)
	var alto := maxi(int(ceil(tam.y)), 50)
	if vista_vr.size_2d_override != Vector2i(ancho, alto):
		vista_vr.size = Vector2i(ancho, alto) * 2          # el doble de pixeles para que se lea nitido en el visor
		vista_vr.size_2d_override = Vector2i(ancho, alto)
		vista_vr.size_2d_override_stretch = true
		ui.size = Vector2(ancho, alto)
	var k := 0.001
	(panel_3d.mesh as QuadMesh).size = Vector2(ancho * k, alto * k)
	panel_3d.position = Vector3(0.40, 0.32 - alto * k * 0.5, -0.95)


# Solo el valor de cada parametro en la posicion del jugador.
func _actualizar_panel() -> void:
	if not ver_panel or v.is_empty():
		return
	valores_lbl[O2].text = "%.2f %%" % [float(v["fo2"]) * 100.0]
	valores_lbl[RAD].text = "%.2f mSv/día" % float(v["rad"])
	valores_lbl[TEMP].text = "%.0f °C" % [float(v["temp"]) - 273.15]
	valores_lbl[PRES].text = "%.0f Pa" % float(v["presion"])
	valores_lbl[POLVO].text = "τ %.2f" % float(v["tau"])
	if en_3d:
		_ajustar_panel_3d.call_deferred()

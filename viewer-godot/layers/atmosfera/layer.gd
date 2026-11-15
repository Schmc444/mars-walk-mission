extends Node3D
# CAPA ATMOSFERA (Kevin). Panel lateral con 5 valores (oxigeno, radiacion, temperatura, presion, polvo), vistas de falso color
# a pantalla completa, sonido de cercania y neblina de colores por zonas.
#   Vistas (una a la vez; repetir la tecla la apaga):  P calor · O radiacion · K oxigeno · M presion · N polvo
#   J sonido ON/OFF: tono que sube de frecuencia al acercarte a una zona con el parametro alto (el de la vista activa,
#     o el mas cercano de los cinco si no hay vista)
#   F1 polvo · F2 radiacion · F3 oxigeno · F7 presion · F8 temperatura: neblina por zonas (una a la vez)
#   F6 mostrar u ocultar el panel
# Tramo de la ruta del equipo: A = sol 1063, B = sol 1116 (TRAMO_SOL_A / TRAMO_SOL_B). Mientras el jugador esta en ese tramo,
#   el mapa de valores queda fijo y centrado en el (el tramo completo cabe en los 3.2 km del mapa).
# Valores base reales (NASA, ver LEEME.md); la variacion de un lugar a otro es SINTETICA (salvo la presion por la altura).
# Opciones de prueba (despues de --): --atm-vista=calor|radiacion|oxigeno|presion|polvo  --atm-sonido
#   --atm=polvo|radiacion|oxigeno|presion|temperatura (neblina)  --atm-tramo=A,B (otro tramo; --atm-tramo=no lo desactiva)
#   --atm-sol=N (forzar el sol)  --atm-hora=H (hora local 0-24; por defecto sale del sol de la escena)
#   --atm-panel-3d (ver el panel como en VR, sin visor)
# En VR el panel flota pegado a la vista. Para botones del control: alternar_vista(VISTA_*), alternar_sonido(),
# activar(POLVO/RAD/O2/PRES/TEMP) o alternar_panel() (los botones aun no estan asignados).

const Modelo := preload("modelo.gd")
const SHADER_NEBLINA := preload("neblina.gdshader")
const SHADER_VISTA := preload("vista.gdshader")

const POLVO := 0
const RAD := 1
const O2 := 2
const PRES := 3
const TEMP := 4
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
const PRESUPUESTO_US := 2000      # tope de tiempo por cuadro para calcular el mapa de valores
const RECENTRAR_M := 700.0
const ANCHO_PANEL := 250
const LETRA := 16
const FILAS_PANEL := [O2, RAD, TEMP, PRES, POLVO]      # orden de las filas del panel
# Posicion del panel. En pantalla: separacion del borde derecho y del borde de arriba, como fraccion de la ventana.
const PANEL_MARGEN_X := 0.14
const PANEL_MARGEN_Y := 0.18
# En VR: centro horizontal y borde de arriba del panel (m, respecto a los ojos), distancia y giro hacia el ojo (rad).
const PANEL_VR_X := 0.22
const PANEL_VR_ARRIBA := 0.16
const PANEL_VR_DIST := 0.95
const PANEL_VR_GIRO := -0.22
# Seguimiento suave del panel en VR: no se mueve con giros pequenios de la cabeza (zona muerta) y, cuando la cabeza
# gira mas, la alcanza con un filtro de primer orden. Solo se suaviza el giro; la posicion sigue a la cabeza exacta.
const PANEL_ZONA_MUERTA_GRADOS := 6.0
const PANEL_SUAVIZADO_S := 0.25   # constante de tiempo (s); mas grande = mas lento y suave

const VISTA_CALOR := 0
const VISTA_RAD := 1
const VISTA_O2 := 2
const VISTA_PRES := 3
const VISTA_POLVO := 4
const VISTA_CANAL := [TEMP, RAD, O2, PRES, POLVO]       # que parametro muestra cada vista
const VISTA_TECLA := ["P", "O", "K", "M", "N"]
const ANCHO_MIN_VISTA := [0.15, 0.15, 0.15, 8.0, 0.0]  # por canal: ancho minimo de la escala (polvo/rad/O2 en 0..1, presion en Pa)
const CIELO_VISTA := [0.02, 0.85, 0.05, 0.05, 0.35]    # por vista: valor del cielo (frio; de ahi vienen los rayos cosmicos; ...)

# Tramo de la ruta del equipo (punto A y punto B de puntos de interes)
const TRAMO_SOL_A := 1063
const TRAMO_SOL_B := 1116
const TRAMO_MARGEN_M := 700.0     # a menos de esto del tramo, el mapa queda fijo centrado en el tramo
const CAMBIO_SOL_REGEN := 10.0    # el mapa se recalcula si el sol cambia en 10 o mas (los cambios por sol son minimos)

# Sonido (J): oscilador con fase continua (NCO) + un poco de ruido blanco
const AUDIO_HZ := 22050.0
const F_MIN := 220.0              # Hz lejos de toda zona alta
const OCTAVAS := 3.0              # dentro de la zona: F_MIN * 2^3 = 1760 Hz
const RADIO_SONIDO_M := 600.0     # a esta distancia de una zona alta el tono empieza a subir
const GLIDE_S := 0.08             # constante de tiempo del cambio de frecuencia (filtro de un polo)

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
var vista_q: MeshInstance3D      # cuadro de la vista de calor / radiacion
var mat_vista: ShaderMaterial
var vista := -1
var temp_mediana := 215.0
# por canal, el valor "orientado" (mas alto = mas de ese parametro: mas polvo, dosis, O2, presion, temperatura):
# percentiles 5, 50, 90 y 95 en el mapa actual
var pcts := [Vector4(0.2, 0.4, 0.55, 0.6), Vector4(0.2, 0.4, 0.55, 0.6), Vector4(0.2, 0.4, 0.55, 0.6),
	Vector4(770, 780, 785, 790), Vector4(210, 215, 218, 220)]
var campo_d1 := PackedFloat32Array()     # copias en arreglo del mapa (para el sonido)
var campo_d2 := PackedFloat32Array()

var tramo_ok := false
var tramo_caja := Rect2()
var tramo_a := TRAMO_SOL_A
var tramo_b := TRAMO_SOL_B

var sonido_on := false
var reproductor: AudioStreamPlayer
var audio_pb: AudioStreamGeneratorPlayback
var fase := 0.0
var f_obj := F_MIN
var f_act := F_MIN
var nivel_sonido := 0.0
var _t_son := 0.0
var _rng := RandomNumberGenerator.new()
var remol: Array = []

var ui: PanelContainer
var valores_lbl := {}           # canal -> Label "Oxigeno: 0.16 %"
var sonido_lbl: Label
var estado_lbl: Label           # "Hora: 14:32 · Batería: 78 %"
# Idioma del panel: espaniol por defecto; --atm-idioma=en lo pone en ingles (p. ej. para el video del concurso)
var idioma := "es"
const ETIQUETAS := {
	"es": {"o2": "Oxígeno", "rad": "Radiación", "msv": "mSv/día", "temp": "Temperatura", "pres": "Presión",
		"polvo": "Polvo", "sonido": "Sonido", "hora": "Hora", "bateria": "Batería"},
	"en": {"o2": "Oxygen", "rad": "Radiation", "msv": "mSv/day", "temp": "Temperature", "pres": "Pressure",
		"polvo": "Dust", "sonido": "Sound", "hora": "Time", "bateria": "Battery"},
}
var bateria_ok := false         # se muestra la bateria solo si es la del visor (app corriendo en el visor) o si se pide para probar
var bateria := -1               # % (-1 = todavia no se sabe / no disponible)
var _t_bat := 0.0
var analisis := false           # --atm-analisis: escribe los datos del informe (informe/analisis_ruta.gd) y cierra
var _hilo_bat: Thread
var canvas: CanvasLayer
var vista_vr: SubViewport
var panel_3d: MeshInstance3D
var en_3d := false
var panel_local := Transform3D.IDENTITY   # posicion del panel respecto a la cabeza
var giro_suave := Quaternion.IDENTITY     # orientacion filtrada de la cabeza
var giro_iniciado := false
var siguiendo := false
var ancho_fijo := 0.0                     # el panel solo crece de ancho (no salta al cambiar el texto)

var _t_rem := 0.0
var _t_ui := 0.0
var sol_actual := 0.0
var v := {}                     # valores en la posicion del jugador


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c
	var args := OS.get_cmdline_user_args()
	en_3d = bool(core.get("in_xr")) or "--atm-panel-3d" in args
	# Bateria: Godot 4 no tiene funcion de bateria; se lee del sistema donde corre la app (_leer_bateria). Si la app corre
	# dentro del visor (standalone: Android, o Linux ARM como SteamOS), es la de los lentes. Con el visor conectado a la PC
	# (SteamVR / Link) seria la de la PC: no se muestra. --atm-bateria-pc la muestra igual (para probar en la laptop).
	var en_visor := OS.get_name() == "Android" or (bool(core.get("in_xr")) and OS.get_name() == "Linux" and OS.has_feature("arm64"))
	bateria_ok = en_visor or "--atm-bateria-pc" in args
	_crear_neblina()
	_crear_vista()
	_crear_panel()
	_crear_audio()
	_leer_sol_escena()
	for a in args:
		if a == "--atm-tramo=no":
			tramo_a = -1
		elif a.begins_with("--atm-tramo="):
			var ab := a.get_slice("=", 1).split(",")
			if ab.size() == 2:
				tramo_a = int(ab[0])
				tramo_b = int(ab[1])
		elif a.begins_with("--atm-sol="):
			sol_forzado = float(a.get_slice("=", 1))
		elif a.begins_with("--atm-hora="):
			hora = fposmod(float(a.get_slice("=", 1)), 24.0)
			hora_forzada = true
		elif a.begins_with("--atm-idioma="):
			var i := a.get_slice("=", 1)
			if ETIQUETAS.has(i):
				idioma = i
	for a in args:
		match a:
			"--atm=polvo": activar(POLVO)
			"--atm=radiacion": activar(RAD)
			"--atm=oxigeno": activar(O2)
			"--atm=presion": activar(PRES)
			"--atm=temperatura": activar(TEMP)
			"--atm-vista=calor": alternar_vista(VISTA_CALOR)
			"--atm-vista=radiacion": alternar_vista(VISTA_RAD)
			"--atm-vista=oxigeno": alternar_vista(VISTA_O2)
			"--atm-vista=presion": alternar_vista(VISTA_PRES)
			"--atm-vista=polvo": alternar_vista(VISTA_POLVO)
			"--atm-sonido": alternar_sonido()
			"--atm-analisis": analisis = true
	for a in args:
		if a.begins_with("--atm-video="):       # grabacion de clips para el video (video/clip_video.gd)
			var grabador: Node = load("res://layers/atmosfera/video/clip_video.gd").new()
			grabador.capa = self
			grabador.core = core
			grabador.clip = a.get_slice("=", 1)
			grabador.carpeta = OS.get_user_data_dir() + "/video_" + grabador.clip
			grabador.muestras = "--atm-video-muestras" in args
			for b in args:
				if b.begins_with("--atm-video-dir="):
					grabador.carpeta = b.get_slice("=", 1)
			add_child(grabador)
	_preparar_tramo()


# Caja (x, z) que cubre la ruta del sol A al final del sol B. Si cabe en el mapa, el mapa se fija ahi mientras el jugador esta cerca.
func _preparar_tramo() -> void:
	if tramo_a < 0:
		return
	var sa := world.route_s_of_sol(tramo_a)
	var sb := world.route_s_of_sol(tramo_b + 1)
	if sb <= sa:
		return
	var p0 := world.route_pos(sa)
	tramo_caja = Rect2(p0, Vector2.ZERO)
	var s := sa
	while s < sb:
		tramo_caja = tramo_caja.expand(world.route_pos(s))
		s += CELDA
	tramo_caja = tramo_caja.expand(world.route_pos(sb))
	var cabe := maxf(tramo_caja.size.x, tramo_caja.size.y) + 2.0 * TRAMO_MARGEN_M <= N * CELDA - 2.0 * CELDA
	tramo_ok = cabe
	print("atmosfera: tramo sol %d -> %d, %.1f km de ruta, caja %.0f x %.0f m%s" % [tramo_a, tramo_b, (sb - sa) / 1000.0,
		tramo_caja.size.x, tramo_caja.size.y, "" if cabe else " (no cabe en el mapa: se usa el mapa que sigue al jugador)"])


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
		KEY_P: alternar_vista(VISTA_CALOR)
		KEY_O: alternar_vista(VISTA_RAD)
		KEY_K: alternar_vista(VISTA_O2)
		KEY_M: alternar_vista(VISTA_PRES)
		KEY_N: alternar_vista(VISTA_POLVO)
		KEY_J: alternar_sonido()
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


# Vista de falso color a pantalla completa (solo una a la vez; la misma tecla la apaga).
func alternar_vista(nueva: int) -> void:
	vista = -1 if vista == nueva else nueva
	vista_q.visible = vista >= 0
	if vista >= 0:
		mat_vista.set_shader_parameter("vista", vista)
		_subir_vista()
	_marcar_fila()
	_t_son = 0.0


func alternar_sonido() -> void:
	sonido_on = not sonido_on
	if sonido_on:
		reproductor.play()
		audio_pb = reproductor.get_stream_playback()
		_t_son = 0.0
	else:
		reproductor.stop()
		audio_pb = null
	sonido_lbl.visible = sonido_on


func alternar_panel() -> void:
	ver_panel = not ver_panel
	ui.visible = ver_panel
	if panel_3d:
		panel_3d.visible = ver_panel
	_t_ui = 0.0                          # al volver a mostrarlo, refrescar ya (mientras esta oculto no se actualiza)


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
		remol = m.remolinos(sol_actual, p.x, p.z, Time.get_ticks_msec() / 1000.0, 1200.0, 16, hora)
		_subir_remolinos()
	if _t_ui <= 0.0:
		_t_ui = 0.2
		_valores(p)
		_actualizar_panel()
	if sonido_on:
		_t_son -= delta
		if _t_son <= 0.0:
			_t_son = 0.25
			nivel_sonido = _nivel_cercania(p)
			f_obj = F_MIN * pow(2.0, OCTAVAS * nivel_sonido)
		_llenar_audio()
	if canvas and ver_panel:
		var vs := get_viewport().get_visible_rect().size
		ui.position = Vector2(vs.x * (1.0 - PANEL_MARGEN_X) - ui.size.x, vs.y * PANEL_MARGEN_Y)   # lateral derecho
	if panel_3d and ver_panel:
		_seguir_panel(delta)
	if analisis and not campo_d1.is_empty() and Engine.get_process_frames() > 300:
		analisis = false
		load("res://layers/atmosfera/informe/analisis_ruta.gd").new().ejecutar(self)
		get_tree().quit()
	if bateria_ok:
		_t_bat -= delta
		if _t_bat <= 0.0:
			_t_bat = 30.0
			_pedir_bateria()


# ---------------------------------------------------------------- bateria del visor (Godot 4 no la expone: se lee del sistema)

func _pedir_bateria() -> void:
	match OS.get_name():
		"Android":
			bateria = _bateria_android()
		"Linux":
			bateria = _bateria_linux()
		"Windows":
			# PowerShell tarda ~1 s: se consulta en un hilo para no trabar el visor
			if _hilo_bat == null or not _hilo_bat.is_alive():
				if _hilo_bat != null:
					_hilo_bat.wait_to_finish()
				_hilo_bat = Thread.new()
				_hilo_bat.start(_bateria_windows)


# Android (visor standalone, p. ej. Quest): BatteryManager.getIntProperty(BATTERY_PROPERTY_CAPACITY = 4).
func _bateria_android() -> int:
	if not Engine.has_singleton("AndroidRuntime"):
		return -1
	var ctx = Engine.get_singleton("AndroidRuntime").getApplicationContext()
	if ctx == null:
		return -1
	var bm = ctx.getSystemService("batterymanager")
	return int(bm.getIntProperty(4)) if bm != null else -1


# Linux (visor con SteamOS u otro Linux): /sys/class/power_supply/<bateria>/capacity
func _bateria_linux() -> int:
	var base := "/sys/class/power_supply"
	for d in DirAccess.get_directories_at(base):
		var tipo := FileAccess.get_file_as_string("%s/%s/type" % [base, d]).strip_edges()
		if tipo == "Battery":
			var cap := FileAccess.get_file_as_string("%s/%s/capacity" % [base, d]).strip_edges()
			if cap.is_valid_int():
				return int(cap)
	return -1


# Windows (solo para probar en la laptop con --atm-bateria-pc). Corre en un hilo.
func _bateria_windows() -> void:
	var salida := []
	OS.execute("powershell", ["-NoProfile", "-Command", "(Get-CimInstance Win32_Battery).EstimatedChargeRemaining"], salida)
	var txt := (salida[0] as String).strip_edges() if salida.size() > 0 else ""
	set_deferred("bateria", int(txt) if txt.is_valid_int() else -1)


func _exit_tree() -> void:
	if _hilo_bat != null:
		_hilo_bat.wait_to_finish()


# Panel VR: orientacion filtrada con zona muerta. Dentro de la zona muerta no se mueve; fuera, se acerca a la cabeza con
# q <- slerp(q, q_cabeza, 1 - e^(-dt/tau)) (filtro de un polo) hasta quedar a menos de 1 grado, y ahi se detiene.
func _seguir_panel(delta: float) -> void:
	var cab: Transform3D = core.cam.global_transform
	var q_cab := cab.basis.get_rotation_quaternion()
	if not giro_iniciado:
		giro_suave = q_cab
		giro_iniciado = true
	var ang := rad_to_deg(giro_suave.angle_to(q_cab))
	if ang > PANEL_ZONA_MUERTA_GRADOS:
		siguiendo = true
	if siguiendo:
		giro_suave = giro_suave.slerp(q_cab, 1.0 - exp(-delta / PANEL_SUAVIZADO_S))
		if ang < 1.0:
			siguiendo = false
	panel_3d.global_transform = Transform3D(Basis(giro_suave), cab.origin) * panel_local


# Sol en la posicion del jugador. En el rover, el de la ruta. A pie, el del punto de la ruta mas cercano; como la ruta
# pasa varias veces por el mismo lugar en sols distintos, el sol nuevo solo se acepta si se mantiene CAMBIO_SOL_S
# seguidos (si no, los valores saltan ida y vuelta al caminar).
const CAMBIO_SOL_S := 1.5
var _sol_candidato := -1.0
var _t_candidato := 0.0

func _sol(p: Vector3) -> float:
	if sol_forzado >= 0.0:
		return sol_forzado
	if core.riding:
		return float(world.route_sol_at(core.ride_s))
	var nuevo := float(world.route_sol_at(world.route_nearest_s(Vector2(p.x, p.z))))
	if sol_actual <= 0.0 or nuevo == sol_actual:
		_sol_candidato = -1.0
		return nuevo
	var ahora := Time.get_ticks_msec() / 1000.0
	if nuevo != _sol_candidato:
		_sol_candidato = nuevo
		_t_candidato = ahora
	if ahora - _t_candidato >= CAMBIO_SOL_S:
		_sol_candidato = -1.0
		return nuevo
	return sol_actual


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
		var p2 := Vector2(p.x, p.z)
		var fijo := tramo_ok and tramo_caja.grow(TRAMO_MARGEN_M).has_point(p2)
		var objetivo := tramo_caja.get_center() if fijo else p2
		var centro := campo_origen + Vector2.ONE * (N * CELDA * 0.5)
		var mover := centro.distance_to(objetivo) > (CELDA if fijo else RECENTRAR_M)
		if mover or absf(sol_actual - campo_sol) >= CAMBIO_SOL_REGEN:
			gen_origen = (objetivo - Vector2.ONE * (N * CELDA * 0.5)).snapped(Vector2(CELDA, CELDA))
			gen_sol = sol_actual
			gen_img = Image.create_empty(N, N, false, Image.FORMAT_RGBAF)
			gen2_img = Image.create_empty(N, N, false, Image.FORMAT_RGF)
			gen_h.resize(N * N)
			gen_fila = 0
			gen_fase = 0
		return
	var fin := mini(gen_fila + FILAS_POR_FRAME, N)
	# Hasta FILAS_POR_FRAME filas, pero sin pasar de PRESUPUESTO_US por cuadro (al menos una fila): 6 filas de la fase 1
	# costaban ~4 ms (picos de 15 ms) en un x86 de escritorio, varias veces eso en el arm64 del Frame -> tirones al recentrar.
	var t0 := Time.get_ticks_usec()
	if gen_fase == 0:
		for j in range(gen_fila, fin):
			for i in N:
				gen_h[j * N + i] = world.height_at(gen_origen.x + (i + 0.5) * CELDA, gen_origen.y + (j + 0.5) * CELDA)
			if Time.get_ticks_usec() - t0 > PRESUPUESTO_US:
				fin = j + 1
				break
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
			if Time.get_ticks_usec() - t0 > PRESUPUESTO_US:
				fin = j + 1
				break
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
				mat_vista.set_shader_parameter("campo", campo_tex)
				mat_vista.set_shader_parameter("campo2", campo2_tex)
			else:
				campo_tex.update(campo_img)
				campo2_tex.update(campo2_img)
			mat.set_shader_parameter("campo_origen", campo_origen)
			mat.set_shader_parameter("campo_tam", N * CELDA)
			_calcular_rangos()
			if modo >= 0:
				mat.set_shader_parameter("rango_suelo", rangos[modo])
			_subir_rango_local()
			_subir_vista()


const MUESTRA := 7              # para los percentiles basta con 1 de cada 7 casillas (~3600 por canal)

# Percentiles 50 y 95 de cada canal del mapa: el shader resalta en el suelo lo que esta por encima de la mediana
# (zonas relativas a lo que te rodea; el color sigue siendo el valor de la leyenda).
# Presion y temperatura: ademas, la escala de color se centra en la mediana del mapa (+-25 Pa, +-6 K).
func _calcular_rangos() -> void:
	var d1 := campo_img.get_data().to_float32_array()       # RGBA por casilla
	var d2 := campo2_img.get_data().to_float32_array()      # RG por casilla
	campo_d1 = d1
	campo_d2 = d2
	var n := (N * N + MUESTRA - 1) / MUESTRA
	var crudos: Array = []
	for c in 5:
		var a := PackedFloat32Array()
		a.resize(n)
		var o := PackedFloat32Array()
		o.resize(n)
		for s in n:
			var k := s * MUESTRA
			a[s] = d1[k * 4 + c] if c < 3 else d2[k * 2 + c - 3]
			o[s] = _orientado(c, k)
		a.sort()
		o.sort()
		crudos.append(a)
		pcts[c] = Vector4(o[n * 5 / 100], o[n / 2], o[n * 90 / 100], o[n * 95 / 100])
	rango_pres = _escala_local(crudos[PRES], Modelo.PRES_MEDIO_RANGO)   # (claro = mas, oscuro = menos)
	rango_temp = _escala_local(crudos[TEMP], Modelo.TEMP_MEDIO_RANGO)
	var at: PackedFloat32Array = crudos[TEMP]
	temp_mediana = at[n / 2]
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


# Valor de la casilla k "orientado": mas alto = mas de ese parametro (O2 se guarda como falta, por eso 1 - valor).
func _orientado(c: int, k: int) -> float:
	match c:
		POLVO: return campo_d1[k * 4]
		RAD: return campo_d1[k * 4 + 1]
		O2: return 1.0 - campo_d1[k * 4 + 2]
		PRES: return campo_d2[k * 2]
	return campo_d2[k * 2 + 1]


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


func _crear_vista() -> void:
	mat_vista = ShaderMaterial.new()
	mat_vista.shader = SHADER_VISTA
	mat_vista.render_priority = 15                  # despues de la neblina: la reemplaza mientras la vista esta activa
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	vista_q = MeshInstance3D.new()
	vista_q.name = "VistaAtmosfera"
	vista_q.mesh = q
	vista_q.material_override = mat_vista
	vista_q.extra_cull_margin = 16384.0
	vista_q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	vista_q.position = Vector3(0, 0, -1)
	vista_q.visible = false
	core.cam.add_child(vista_q)


# Escalas de color de las vistas (como una camara termica con ganancia automatica):
#   calor: centrada en la temperatura del suelo plano a esta hora, +-14 K
#   las demas: del 5 % al 95 % del mapa alrededor (con un ancho minimo para no exagerar diferencias pequenias)
func _subir_vista() -> void:
	if mat_vista == null:
		return
	var d := m.factor_dia(hora)
	mat_vista.set_shader_parameter("campo_origen", campo_origen)
	mat_vista.set_shader_parameter("campo_tam", N * CELDA)
	mat_vista.set_shader_parameter("sol_vec", sol_vec)
	mat_vista.set_shader_parameter("dia", d)
	mat_vista.set_shader_parameter("temp_aire", temp_mediana)
	# centro de la escala = suelo plano a esta hora (aire + lo que calienta el sol); +-14 K alrededor
	var plano := temp_mediana + 35.0 * d * maxf(sol_vec.y, 0.0) - 8.0 * (1.0 - d)
	mat_vista.set_shader_parameter("escala_calor", Vector2(plano - 14.0, plano + 14.0))
	if vista > VISTA_CALOR:
		var c: int = VISTA_CANAL[vista]
		var pc: Vector4 = pcts[c]
		var lo := pc.x
		var hi := pc.w
		var minimo: float = ANCHO_MIN_VISTA[c]
		if hi - lo < minimo:
			lo = pc.y - minimo * 0.5
			hi = pc.y + minimo * 0.5
		var margen := (hi - lo) * 0.1
		mat_vista.set_shader_parameter("escala", Vector2(lo - margen, hi + margen))
		mat_vista.set_shader_parameter("mediana", pc.y)
		mat_vista.set_shader_parameter("cielo_t", CIELO_VISTA[vista])


func _subir_remolinos() -> void:
	var arr := PackedVector4Array()
	for r in remol:
		arr.append(r)
	mat.set_shader_parameter("n_remolinos", arr.size())
	while arr.size() < 16:
		arr.append(Vector4.ZERO)
	mat.set_shader_parameter("remolinos", arr)
	mat_vista.set_shader_parameter("n_remolinos", remol.size())
	mat_vista.set_shader_parameter("remolinos", arr)


# ---------------------------------------------------------------- sonido (J)

func _crear_audio() -> void:
	var g := AudioStreamGenerator.new()
	g.mix_rate = AUDIO_HZ
	g.buffer_length = 0.12
	reproductor = AudioStreamPlayer.new()
	reproductor.name = "SonidoAtmosfera"
	reproductor.stream = g
	reproductor.volume_db = -10.0
	add_child(reproductor)


# 0 = lejos (o fuera del mapa) .. 1 = dentro de una zona alta. "Zona alta" = casillas sobre el percentil 90 del mapa.
# Canal: el de la vista activa; sin vista, el mas cercano de los cinco.
func _nivel_cercania(p: Vector3) -> float:
	if campo_d1.is_empty():
		return 0.0
	var ci := int((p.x - campo_origen.x) / CELDA)
	var cj := int((p.z - campo_origen.y) / CELDA)
	if ci < 0 or cj < 0 or ci >= N or cj >= N:
		return 0.0
	var canales: Array = [VISTA_CANAL[vista]] if vista >= 0 else [POLVO, RAD, O2, PRES, TEMP]
	var r := int(RADIO_SONIDO_M / CELDA)
	var mejor := 0.0
	for c in canales:
		var umbral: float = pcts[c].z
		var d2min := INF
		for j in range(maxi(cj - r, 0), mini(cj + r + 1, N), 2):           # una de cada 2 casillas: 40 m
			for i in range(maxi(ci - r, 0), mini(ci + r + 1, N), 2):
				if _orientado(c, j * N + i) >= umbral:
					d2min = minf(d2min, float((i - ci) * (i - ci) + (j - cj) * (j - cj)))
		if _orientado(c, cj * N + ci) >= umbral:
			d2min = 0.0
		if d2min < INF:
			mejor = maxf(mejor, 1.0 - clampf(sqrt(d2min) * CELDA / RADIO_SONIDO_M, 0.0, 1.0))
	return mejor


# Oscilador: la fase avanza 2*pi*f/fs por muestra (NCO). La frecuencia sigue a f_obj con un filtro de un polo
# (y[n] = y[n-1] + a (x[n] - y[n-1]), polo en z = 1 - a) para que el tono se deslice sin saltos.
func _llenar_audio() -> void:
	if audio_pb == null:
		return
	var a := 1.0 - exp(-1.0 / (AUDIO_HZ * GLIDE_S))
	for k in audio_pb.get_frames_available():
		f_act += a * (f_obj - f_act)
		fase = fmod(fase + TAU * f_act / AUDIO_HZ, TAU)
		var muestra := 0.22 * sin(fase) + 0.03 * (_rng.randf() * 2.0 - 1.0)
		audio_pb.push_frame(Vector2(muestra, muestra))


# ---------------------------------------------------------------- panel

func _crear_panel() -> void:
	ui = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.02, 0.04, 0.85)       # casi opaco: el texto se lee sobre las vistas de colores brillantes
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	ui.add_theme_stylebox_override("panel", sb)
	ui.custom_minimum_size = Vector2(ANCHO_PANEL, 0)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	ui.add_child(vb)
	for canal in FILAS_PANEL:
		var fila := _label()                            # "Oxigeno: 0.16 %"
		vb.add_child(fila)
		valores_lbl[canal] = fila
	sonido_lbl = _label()
	sonido_lbl.visible = false
	vb.add_child(sonido_lbl)
	estado_lbl = _label()
	estado_lbl.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	vb.add_child(estado_lbl)
	if en_3d:
		# en 3D el panel se mezcla antes del tonemapping: con fondo semitransparente, los colores HDR de las vistas
		# se filtraban (franja de color sobre el horizonte). Fondo opaco; solo las esquinas redondeadas quedan transparentes.
		sb.bg_color.a = 1.0
		vista_vr = SubViewport.new()
		vista_vr.transparent_bg = true
		vista_vr.disable_3d = true
		vista_vr.render_target_update_mode = SubViewport.UPDATE_ONCE   # se re-renderiza al cambiar el texto (_actualizar_panel, 5 Hz)
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
		panel_3d.top_level = true                       # no va pegado a la camara: _seguir_panel lo mueve suave
		add_child(panel_3d)
		panel_local = Transform3D(Basis(Vector3.UP, PANEL_VR_GIRO), Vector3(PANEL_VR_X, PANEL_VR_ARRIBA - 0.08, -PANEL_VR_DIST))
	else:
		canvas = CanvasLayer.new()
		canvas.layer = 5
		add_child(canvas)
		canvas.add_child(ui)


func _marcar_fila() -> void:
	var activo: int = VISTA_CANAL[vista] if vista >= 0 else -1
	for c in FILAS_PANEL:
		valores_lbl[c].add_theme_color_override("font_color", COLOR_ACTIVO if c == activo else COLOR_TEXTO)
	_t_ui = 0.0


func _label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", LETRA)
	l.add_theme_color_override("font_color", Color(0.95, 0.95, 0.92))
	return l


# Ajusta el tamanio del panel flotante (VR) al contenido: 1 px = 1 mm, a 1 m de los ojos, a la derecha.
func _ajustar_panel_3d() -> void:
	var tam := ui.get_combined_minimum_size()
	var ancho := maxi(int(ceil(maxf(tam.x, ancho_fijo))), ANCHO_PANEL)
	var alto := maxi(int(ceil(tam.y)), 50)
	if vista_vr.size_2d_override != Vector2i(ancho, alto):
		vista_vr.size = Vector2i(ancho, alto) * 2          # el doble de pixeles para que se lea nitido en el visor
		vista_vr.size_2d_override = Vector2i(ancho, alto)
		vista_vr.size_2d_override_stretch = true
		ui.size = Vector2(ancho, alto)
	var k := 0.001
	(panel_3d.mesh as QuadMesh).size = Vector2(ancho * k, alto * k)
	panel_local = Transform3D(Basis(Vector3.UP, PANEL_VR_GIRO), Vector3(PANEL_VR_X, PANEL_VR_ARRIBA - alto * k * 0.5, -PANEL_VR_DIST))


const COLOR_TEXTO := Color(0.95, 0.95, 0.92)
const COLOR_ACTIVO := Color(1.0, 0.83, 0.47)

# Solo el valor de cada parametro en la posicion del jugador. La fila de la vista activa va resaltada.
func _actualizar_panel() -> void:
	if not ver_panel or v.is_empty():
		return
	var e: Dictionary = ETIQUETAS[idioma]
	var textos := {
		# oxigeno: fraccion local (pO2 / p), con la misma variacion de lugar que la presion parcial
		O2: "%s: %.3f %%" % [e["o2"], float(v["po2"]) / float(v["presion"]) * 100.0],
		RAD: "%s: %.3f %s" % [e["rad"], float(v["rad"]), e["msv"]],
		TEMP: "%s: %.1f °C" % [e["temp"], float(v["temp"]) - 273.15],
		PRES: "%s: %.1f Pa" % [e["pres"], float(v["presion"])],
		POLVO: "%s: τ %.2f" % [e["polvo"], float(v["tau"])],
	}
	var activo: int = VISTA_CANAL[vista] if vista >= 0 else -1
	for c in FILAS_PANEL:
		valores_lbl[c].text = ("▶ " if c == activo else "") + textos[c]
	if sonido_on:
		sonido_lbl.text = "%s: %.0f Hz" % [e["sonido"], f_obj]
	var t := Time.get_time_dict_from_system()
	var estado := "%s: %02d:%02d" % [e["hora"], t["hour"], t["minute"]]
	if bateria_ok and bateria >= 0:
		estado += " · %s: %d %%" % [e["bateria"], bateria]
	estado_lbl.text = estado
	# ancho estable: solo crece (con el texto alineado a la derecha, encogerse lo haria saltar de lado)
	ancho_fijo = maxf(ancho_fijo, ui.get_combined_minimum_size().x)
	ui.custom_minimum_size.x = ancho_fijo
	if en_3d:
		_ajustar_panel_3d.call_deferred()
		vista_vr.render_target_update_mode = SubViewport.UPDATE_ONCE

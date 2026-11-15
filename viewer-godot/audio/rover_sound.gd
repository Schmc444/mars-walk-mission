extends Node
## Sonido de proximidad del Perseverance (Autoload "RoverSound", ver [autoload] en project.godot).
##
## Audio: primeros sonidos grabados en Marte con el ruido propio del rover (micrófono del costado del
## Perseverance, 20 feb 2021). Crédito: NASA/JPL-Caltech. Ver audio/CREDITOS.md.
##
## Un AudioStreamPlayer3D en loop, hijo del nodo del rover: lo sigue solo y Godot calcula el paneo.
## Se oye a menos de RADIO_M metros de la cámara activa (la del jugador, en escritorio y en XR).
## Sin tocar archivos del equipo: el rover lo crea el visor (main.gd / layers/ruta) después de arrancar este
## Autoload, así que se busca cada cuadro hasta encontrarlo y se vuelve a buscar si desaparece:
##   modo mundo  -> core/capa_ruta.rover (se mueve con ride_s; el visor lo crea una sola vez)
##   modo parche -> core/Perseverance    (fijo en el waypoint)
## Bus propio "Rover" (VOLUME_DB). Montado en el rover (core.riding) suena RIDING_DB más bajo, con fade.
## Respeta --norover (sin rover, sin sonido) y --no-ambient (apaga también este sonido).

const STREAM_PATH := "res://audio/rover_selfnoise_norm.wav"   # copia normalizada (RMS -16 dBFS, pico -1 dBFS); original: rover_selfnoise.wav
const BUS_NAME := "Rover"
const RADIO_M := 5.0          # m: más allá no se oye (max_distance)
const FADE_START_M := 2.5     # m: desde aquí el volumen baja hasta cero justo en RADIO_M (sin corte seco)
const VOLUME_DB := 0.0        # volumen del bus Rover; el nivel ya viene normalizado en el archivo
const RIDING_DB := 0.0        # dB extra mientras el jugador va montado (0 = igual que a pie; poner p. ej. -6 para bajarlo)
const RIDING_FADE_S := 0.4    # s: constante de tiempo del cambio montado <-> a pie
const MIC_HEIGHT := 0.8       # m sobre el origen del rover (micrófono del costado)
const SILENT_DB := -80.0

var player: AudioStreamPlayer3D
var rover: Node3D
var _riding_db := 0.0         # offset actual (suavizado)
var _disabled := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--no-ambient" in args or "--norover" in args:
		_disabled = true
		print("RoverSound: desactivado (%s)" % ("--no-ambient" if "--no-ambient" in args else "--norover"))
		set_process(false)
		return
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS_NAME)
		AudioServer.set_bus_send(idx, &"Master")
	AudioServer.set_bus_volume_db(idx, VOLUME_DB)


## Gana (dB) por cercanía: 0 dB hasta FADE_START_M, baja suave (smoothstep) hasta SILENT_DB en RADIO_M.
static func edge_db(dist: float) -> float:
	var t := clampf((dist - FADE_START_M) / (RADIO_M - FADE_START_M), 0.0, 1.0)
	var lin := 1.0 - t * t * (3.0 - 2.0 * t)
	return maxf(linear_to_db(lin), SILENT_DB) if lin > 0.0 else SILENT_DB


func _core() -> Node:
	var cs := get_tree().current_scene
	if cs != null and cs.get("world_mode") != null:
		return cs
	for c in get_tree().root.get_children():
		if c.get("world_mode") != null and c.get("riding") != null:
			return c
	return null


func _find_rover(core: Node) -> Node3D:
	var r = core.get_node_or_null("capa_ruta")
	if r != null and r.get("rover") != null and is_instance_valid(r.get("rover")):
		return r.get("rover")
	return core.get_node_or_null("Perseverance") as Node3D


func _ensure_player(core: Node) -> bool:
	var r := _find_rover(core)
	if r == null:
		return false
	if is_instance_valid(player) and player.get_parent() == r:
		return true
	if is_instance_valid(player):      # el rover cambió o se recreó: nada de reproductores huérfanos/duplicados
		player.queue_free()
	var st := load(STREAM_PATH) as AudioStreamWAV
	if st == null:
		push_warning("RoverSound: no se pudo cargar " + STREAM_PATH)
		set_process(false)
		return false
	st.loop_mode = AudioStreamWAV.LOOP_FORWARD
	st.loop_begin = 0
	st.loop_end = int(st.get_length() * st.mix_rate)
	player = AudioStreamPlayer3D.new()
	player.name = "RoverSoundPlayer"
	player.stream = st
	player.bus = BUS_NAME
	player.max_distance = RADIO_M
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.unit_size = RADIO_M          # ganancia >= 0 dB dentro de todo el radio: el único fade es el de edge_db()
	player.max_db = 0.0                 # nunca por encima del nivel del archivo (sin clipping)
	player.attenuation_filter_cutoff_hz = 20500.0   # sin pasa-bajos por distancia (por defecto 5 kHz y -24 dB)
	player.attenuation_filter_db = 0.0
	player.volume_db = SILENT_DB
	player.position = Vector3(0, MIC_HEIGHT, 0)
	r.add_child(player)
	player.play()
	rover = r
	return true


func _process(delta: float) -> void:
	var core := _core()
	if core == null or not _ensure_player(core):
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or not rover.is_visible_in_tree():
		player.stream_paused = true       # rover oculto: sin sonido
		return
	player.stream_paused = false
	var want := RIDING_DB if core.get("riding") == true else 0.0
	_riding_db = lerpf(_riding_db, want, 1.0 - exp(-delta / RIDING_FADE_S))
	player.volume_db = maxf(edge_db(cam.global_position.distance_to(player.global_position)) + _riding_db, SILENT_DB)

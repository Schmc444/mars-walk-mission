extends Node
## Sonido ambiente de Marte, siempre activo (Autoload "AmbientAudio", ver [autoload] en project.godot).
##
## Grabación real del viento en Marte: micrófono de SuperCam del rover Perseverance, sol 4.
## Crédito: NASA/JPL-Caltech/LANL/CNES/CNRS/ISAE-Supaero, SuperCam Mars microphone.
##
## Un solo reproductor global en loop continuo. Es un Autoload: vive fuera de las escenas y de las capas,
## así que no se reinicia ni se duplica al cambiar de vista. Va por un bus propio "Ambient" (creado aquí por código)
## con VOLUME_DB moderado para que quede por debajo de otros sonidos. No hay mute: siempre suena.
## Desarrollo: el argumento de usuario --no-ambient (godot ... -- --no-ambient) lo desactiva.

const STREAM_PATH := "res://audio/mars_ambient_wind.mp3"
const BUS_NAME := "Ambient"
const VOLUME_DB := -12.0   # volumen del bus Ambient (0 dB = máximo del archivo)
const LOOP_OFFSET := 0.04   # s: se salta el silencio inicial del mp3 (~20 ms de relleno del codificador) al volver a empezar
const DISABLE_ARG := "--no-ambient"

var player: AudioStreamPlayer


func _ready() -> void:
	if DISABLE_ARG in OS.get_cmdline_user_args() or DISABLE_ARG in OS.get_cmdline_args():
		print("AmbientAudio: desactivado (--no-ambient)")
		return
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS_NAME)
		AudioServer.set_bus_send(idx, &"Master")
	AudioServer.set_bus_volume_db(idx, VOLUME_DB)
	var stream := load(STREAM_PATH) as AudioStreamMP3
	if stream == null:
		push_warning("AmbientAudio: no se pudo cargar " + STREAM_PATH)
		return
	stream.loop = true
	stream.loop_offset = LOOP_OFFSET
	player = AudioStreamPlayer.new()
	player.name = "AmbientPlayer"
	player.stream = stream
	player.bus = BUS_NAME
	player.process_mode = Node.PROCESS_MODE_ALWAYS   # sigue sonando aunque el árbol se pause
	add_child(player)
	player.play()

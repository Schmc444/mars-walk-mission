extends Node
## Sonido ambiente de Marte, siempre activo (Autoload "AmbientAudio", ver [autoload] en project.godot).
##
## Grabación real del viento en Marte: micrófono de SuperCam del rover Perseverance, sol 4.
## Crédito: NASA/JPL-Caltech/LANL/CNES/CNRS/ISAE-Supaero, SuperCam Mars microphone.
##
## Un solo reproductor global en loop continuo. Es un Autoload: vive fuera de las escenas y de las capas,
## así que no se reinicia ni se duplica al cambiar de vista. Va por un bus propio "Ambient" (creado aquí por código)
## (VOLUME_DB, 0 dB: el archivo ya está normalizado). No hay mute: siempre suena.
## Desarrollo: el argumento de usuario --no-ambient (godot ... -- --no-ambient) lo desactiva.

const STREAM_PATH := "res://audio/mars_ambient_wind_norm.wav"   # copia normalizada (RMS -24 dBFS, pico -1 dBFS, bucle con crossfade); original: mars_ambient_wind.mp3
const BUS_NAME := "Ambient"
const VOLUME_DB := 0.0     # volumen del bus Ambient; el nivel ya viene normalizado en el archivo
const MASTER_CEILING_DB := -1.0   # limitador de seguridad en Master: viento + rover suman picos > 0 dBFS (medido +0.6) y recortarían
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
	_master_limiter()
	var stream := load(STREAM_PATH) as AudioStreamWAV
	if stream == null:
		push_warning("AmbientAudio: no se pudo cargar " + STREAM_PATH)
		return
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD   # el crossfade del bucle ya está horneado en el archivo
	stream.loop_begin = 0
	stream.loop_end = int(stream.get_length() * stream.mix_rate)
	player = AudioStreamPlayer.new()
	player.name = "AmbientPlayer"
	player.stream = stream
	player.bus = BUS_NAME
	player.process_mode = Node.PROCESS_MODE_ALWAYS   # sigue sonando aunque el árbol se pause
	add_child(player)
	player.play()


## Techo en Master: solo actúa sobre picos por encima de MASTER_CEILING_DB; no baja el nivel medio.
func _master_limiter() -> void:
	for i in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, i) is AudioEffectHardLimiter:
			return
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = MASTER_CEILING_DB
	lim.pre_gain_db = 0.0
	AudioServer.add_bus_effect(0, lim)

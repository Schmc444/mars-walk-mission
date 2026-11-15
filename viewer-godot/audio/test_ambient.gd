extends SceneTree
## Sonido ambiente: un solo reproductor, bus Ambient, loop, sigue tras recargar la escena, --no-ambient lo desactiva.
##   godot --headless --path viewer-godot --script res://audio/test_ambient.gd
## (el propio test lanza otra instancia con --no-ambient). Sale con código 0 si todo pasa.
var fails := 0


func check(c: bool, what: String) -> void:
	print(("OK    " if c else "FALLO ") + what)
	if not c:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _players() -> Array:
	var out := []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AudioStreamPlayer and n.stream is AudioStreamMP3:
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _run() -> void:
	await process_frame
	var off := "--no-ambient" in OS.get_cmdline_user_args()
	var amb := root.get_node_or_null("AmbientAudio")
	check(amb != null, "Autoload AmbientAudio registrado")
	if off:
		check(amb != null and amb.player == null and _players().is_empty(), "--no-ambient: no hay reproductor")
		check(AudioServer.get_bus_index("Ambient") < 0, "--no-ambient: no se crea el bus")
		quit(0 if fails == 0 else 1)
		return
	var ps := _players()
	check(ps.size() == 1, "un solo reproductor (%d)" % ps.size())
	var p: AudioStreamPlayer = amb.player
	check(AudioServer.get_bus_index("Ambient") >= 0, "bus Ambient existe")
	check(p.bus == &"Ambient", "el reproductor usa el bus Ambient")
	check(is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Ambient")), amb.VOLUME_DB), "volumen = VOLUME_DB (%.0f dB)" % amb.VOLUME_DB)
	check((p.stream as AudioStreamMP3).loop, "loop activo")
	check(p.playing, "está sonando")
	# recargar la escena: el reproductor es el mismo y no se reinicia ni se duplica
	var id0 := p.get_instance_id()
	await create_timer(0.5).timeout
	var pos0 := p.get_playback_position()
	for i in 2:
		var sc := Node3D.new()
		sc.name = "escena_%d" % i
		var ps2 := PackedScene.new()
		ps2.pack(sc)
		change_scene_to_packed(ps2)
		await process_frame
		await process_frame
	await create_timer(0.5).timeout   # la posición avanza en tiempo real, no por cuadro
	check(p.get_instance_id() == id0 and _players().size() == 1, "tras recargar la escena: mismo reproductor, sin duplicados")
	check(p.playing and p.get_playback_position() > pos0, "tras recargar la escena: sigue sonando sin reiniciarse (%.2f -> %.2f s)" % [pos0, p.get_playback_position()])
	# --no-ambient en otra instancia
	var out := []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://audio/test_ambient.gd", "--", "--no-ambient"], out, true)
	if code != 0:
		print("".join(out))
	check(code == 0, "--no-ambient lo desactiva (instancia aparte, código %d)" % code)
	print("RESULTADO: ", "todo OK" if fails == 0 else "%d fallos" % fails)
	quit(0 if fails == 0 else 1)

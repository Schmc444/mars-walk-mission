extends SceneTree
## Sonido de proximidad del rover (modo parche, sin datos world):
##   godot --headless --path viewer-godot --script res://audio/test_rover_sound.gd
## Lanza instancias aparte con --norover y --no-ambient. Sale con código 0 si todo pasa.
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
		if n is AudioStreamPlayer3D:
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var main := (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await create_timer(2.0).timeout
	var rs := root.get_node("RoverSound")
	var ps := _players()
	if "--norover" in args or "--no-ambient" in args:
		check(ps.is_empty() and rs.player == null, "%s: no se crea el reproductor 3D" % args)
		quit(0 if fails == 0 else 1)
		return
	check(ps.size() == 1, "un solo AudioStreamPlayer3D (%d)" % ps.size())
	var p: AudioStreamPlayer3D = rs.player
	var rover: Node3D = main.get_node("Perseverance")
	check(p.get_parent() == rover, "es hijo del nodo del rover (Perseverance)")
	check((p.stream as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_FORWARD, "loop activo")
	check(is_equal_approx(p.max_distance, 5.0), "max_distance = 5 m")
	check(p.attenuation_filter_cutoff_hz >= 20500.0 and p.max_db == 0.0 and p.unit_size >= 5.0, "sin pasa-bajos por distancia y sin recorte 3D (unit_size >= radio)")
	check(rs.VOLUME_DB == 0.0 and rs.RIDING_DB == 0.0 and is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Rover")), 0.0), "bus Rover a 0 dB y sin recorte al ir montado")
	check(AudioServer.get_bus_index("Rover") >= 0 and p.bus == &"Rover", "bus Rover existe y lo usa el reproductor")
	check(get_root().get_camera_3d() == main.cam, "el listener 3D es la camara del jugador (core.cam)")
	# curva de cercania: plena hasta el inicio del fade, sin saltos, silencio exacto en el borde
	var prev := 0.0
	var maxstep := 0.0
	var d := 0.0
	while d <= 5.0:
		var db: float = rs.edge_db(d)
		if d > 0.0:
			maxstep = maxf(maxstep, absf(db_to_linear(prev) - db_to_linear(db)))
		prev = db
		d += 0.05
	check(rs.edge_db(1.0) == 0.0 and rs.edge_db(2.5) == 0.0, "0 dB dentro de %.1f m" % rs.FADE_START_M)
	check(rs.edge_db(5.0) <= -79.0 and rs.edge_db(6.0) <= -79.0, "silencio en el borde (5 m) y fuera")
	check(rs.edge_db(4.0) < rs.edge_db(3.0) and rs.edge_db(3.0) < 0.0, "baja de forma monotona entre 2.5 y 5 m")
	check(maxstep < 0.05, "sin interruptor: mayor cambio de amplitud entre pasos de 5 cm = %.1f %%" % (maxstep * 100.0))
	# volumen en vivo: cerca a pie / montado / lejos
	main.riding = false
	main.origin.global_position = rover.global_position + Vector3(1.5, 0, 0)
	await create_timer(1.5).timeout
	var v_pie: float = p.volume_db
	main.riding = true
	main.origin.global_position = rover.global_position + Vector3(1.5, 0, 0)
	await create_timer(2.0).timeout
	var v_mont: float = p.volume_db
	check(v_pie > -1.0 and absf(v_pie - v_mont) < 0.5, "a pie %.1f dB, montado %.1f dB (mismo nivel, RIDING_DB = 0)" % [v_pie, v_mont])
	main.riding = false
	main.origin.global_position = rover.global_position + Vector3(30, 0, 0)
	await create_timer(1.0).timeout
	check(p.volume_db <= -79.0, "a 30 m: silencio (%.1f dB)" % p.volume_db)
	# el reproductor sigue al rover si se mueve, y no se duplica si desaparece
	rover.global_position += Vector3(10, 0, 0)
	await process_frame
	check(p.global_position.distance_to((rover.global_transform * Vector3(0, 0.8, 0))) < 0.01, "sigue al rover cuando se reposiciona")
	p.queue_free()
	await create_timer(0.3).timeout
	check(_players().size() == 1 and is_instance_valid(rs.player) and rs.player.playing, "si el reproductor desaparece se recrea uno solo, sonando")
	var out := []
	for flag in ["--norover", "--no-ambient"]:
		out.clear()
		var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://audio/test_rover_sound.gd", "--", flag], out, true)
		if code != 0:
			print("".join(out))
		check(code == 0, "%s: no se crea el reproductor (instancia aparte)" % flag)
	print("RESULTADO: ", "todo OK" if fails == 0 else "%d fallos" % fails)
	quit(0 if fails == 0 else 1)

extends Node3D
# Capa espejo: con --espejo sirve la vista del visor como MJPEG por HTTP para proyectarla desde otro equipo.
# Abrir http://<ip-del-visor>:8090/ en un navegador (pantalla completa). Opciones: --espejo-puerto=N, --espejo-fps=N, --espejo-ancho=N

var port := 8090
var fps := 15.0
var ancho := 1280
var alto := 720
var core: Node
var vp: SubViewport
var cam2: Camera3D
var acumulado := 0.0
var server := TCPServer.new()
var hilo := Thread.new()
var mutex := Mutex.new()
var pendiente: Image = null
var ultimo_jpg := PackedByteArray()
var salir := false


func setup(_w: WorldStreamer, c: Node) -> void:
	core = c
	var args := OS.get_cmdline_user_args()
	if not "--espejo" in args:
		set_process(false)
		return
	for a in args:
		if a.begins_with("--espejo-puerto="):
			port = int(a.get_slice("=", 1))
		elif a.begins_with("--espejo-fps="):
			fps = clampf(float(a.get_slice("=", 1)), 1.0, 60.0)
		elif a.begins_with("--espejo-ancho="):
			ancho = clampi(int(a.get_slice("=", 1)), 320, 3840)
	alto = ancho * 9 / 16
	vp = SubViewport.new()
	vp.size = Vector2i(ancho, alto)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_2X
	add_child(vp)
	cam2 = Camera3D.new()
	cam2.far = 150000.0
	cam2.fov = 80.0
	vp.add_child(cam2)
	cam2.global_transform = core.cam.global_transform
	if server.listen(port) != OK:
		push_warning("espejo: no pude abrir el puerto %d" % port)
		set_process(false)
		return
	hilo.start(_servir)
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			print("ESPEJO http://%s:%d/" % [ip, port])


func _process(dt: float) -> void:
	var xf: Transform3D = core.cam.global_transform
	var k := 1.0 - exp(-10.0 * dt)
	cam2.global_transform = Transform3D(cam2.global_basis.orthonormalized().slerp(xf.basis.orthonormalized(), k), xf.origin)
	acumulado += dt
	if acumulado < 1.0 / fps:
		return
	acumulado = 0.0
	var img := vp.get_texture().get_image()
	if img == null:
		return
	mutex.lock()
	pendiente = img
	mutex.unlock()


func _exit_tree() -> void:
	salir = true
	if hilo.is_started():
		hilo.wait_to_finish()
	server.stop()


const PAGINA := "<!doctype html><meta charset=utf-8><title>Mars Walk Mission</title><body style='margin:0;background:#000'><img src=/stream style='width:100vw;height:100vh;object-fit:contain'></body>"


func _servir() -> void:
	var nuevos: Array = []   # {peer, t0}
	var stream: Array = []
	while not salir:
		while server.is_connection_available():
			nuevos.append({"peer": server.take_connection(), "t0": Time.get_ticks_msec()})
		for n in nuevos.duplicate():
			var p: StreamPeerTCP = n["peer"]
			p.poll()
			var st := p.get_status()
			if st != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - n["t0"] > 3000:
				nuevos.erase(n)
				continue
			if p.get_available_bytes() <= 0:
				continue
			var req := p.get_utf8_string(p.get_available_bytes())
			nuevos.erase(n)
			var linea := req.get_slice("\r\n", 0)
			if linea.begins_with("GET /stream"):
				p.put_data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=f\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".to_utf8_buffer())
				stream.append(p)
			elif linea.begins_with("GET /snap"):
				mutex.lock()
				var j := ultimo_jpg
				mutex.unlock()
				p.put_data(("HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % j.size()).to_utf8_buffer())
				p.put_data(j)
				p.disconnect_from_host()
			else:
				var cuerpo := PAGINA.to_utf8_buffer()
				p.put_data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % cuerpo.size()).to_utf8_buffer())
				p.put_data(cuerpo)
				p.disconnect_from_host()
		mutex.lock()
		var img := pendiente
		pendiente = null
		mutex.unlock()
		if img != null:
			var jpg := img.save_jpg_to_buffer(0.75)
			mutex.lock()
			ultimo_jpg = jpg
			mutex.unlock()
			for p in stream.duplicate():
				p.poll()
				if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
					stream.erase(p)
					continue
				var cab := ("--f\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % jpg.size()).to_utf8_buffer()
				if p.put_data(cab) != OK or p.put_data(jpg) != OK or p.put_data("\r\n".to_utf8_buffer()) != OK:
					stream.erase(p)
		OS.delay_msec(4)

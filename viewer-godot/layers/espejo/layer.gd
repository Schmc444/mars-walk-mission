extends Node3D
# Capa espejo: con --espejo sirve la vista del visor como MJPEG por HTTP para proyectarla desde otro equipo.
# Abrir http://<ip-del-visor>:8090/ en un navegador (pantalla completa). Opciones: --espejo-puerto=N, --espejo-fps=N, --espejo-ancho=N, --espejo-bind=IP, --espejo-raw (BMP sin comprimir, para enlaces rapidos)

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
var bind := "*"
var raw := false
var espera := 0


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
		elif a == "--espejo-raw":
			raw = true
		elif a.begins_with("--espejo-bind="):
			bind = a.get_slice("=", 1)
		elif a.begins_with("--espejo-ancho="):
			ancho = clampi(int(a.get_slice("=", 1)), 320, 3840)
	alto = ancho * 9 / 16
	vp = SubViewport.new()
	vp.size = Vector2i(ancho, alto)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	cam2 = Camera3D.new()
	cam2.far = 150000.0
	cam2.fov = 80.0
	vp.add_child(cam2)
	cam2.global_transform = core.cam.global_transform
	if server.listen(port, bind) != OK:
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
	if espera > 0:
		espera -= 1
		if espera == 0:
			var img := vp.get_texture().get_image()
			if img != null:
				mutex.lock()
				pendiente = img
				mutex.unlock()
		return
	acumulado += dt
	if acumulado < 1.0 / fps:
		return
	acumulado = 0.0
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	espera = 2


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
				stream.append({"peer": p, "resto": PackedByteArray(), "off": 0})
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
		var paquete := PackedByteArray()
		if img != null:
			var tipo := "image/jpeg"
			var cuerpo: PackedByteArray
			if raw:
				tipo = "image/bmp"
				cuerpo = _bmp(img)
			else:
				cuerpo = img.save_jpg_to_buffer(0.8)
				mutex.lock()
				ultimo_jpg = cuerpo
				mutex.unlock()
			paquete = ("--f\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n" % [tipo, cuerpo.size()]).to_utf8_buffer()
			paquete.append_array(cuerpo)
			paquete.append_array("\r\n".to_utf8_buffer())
		for c in stream.duplicate():
			var p: StreamPeerTCP = c["peer"]
			p.poll()
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				stream.erase(c)
				continue
			if c["resto"].size() - c["off"] <= 0 and not paquete.is_empty():
				c["resto"] = paquete
				c["off"] = 0
			if c["resto"].size() - c["off"] > 0:
				var r: Array = p.put_partial_data(c["resto"].slice(c["off"]))
				if r[0] != OK:
					stream.erase(c)
				else:
					c["off"] += r[1]
		OS.delay_msec(3)


func _bmp(img: Image) -> PackedByteArray:
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var datos := img.get_data()
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(0x42)
	b.put_u8(0x4D)
	b.put_u32(122 + datos.size())
	b.put_u32(0)
	b.put_u32(122)
	b.put_u32(108)
	b.put_32(img.get_width())
	b.put_32(-img.get_height())
	b.put_u16(1)
	b.put_u16(32)
	b.put_u32(3)
	b.put_u32(datos.size())
	b.put_u32(2835)
	b.put_u32(2835)
	b.put_u32(0)
	b.put_u32(0)
	b.put_u32(0x000000FF)
	b.put_u32(0x0000FF00)
	b.put_u32(0x00FF0000)
	b.put_u32(0)
	b.put_u32(0x57696E20)
	for _i in 12:
		b.put_u32(0)
	var out := b.data_array
	out.append_array(datos)
	return out

extends Node3D
# Un cartel flotante (sin poste) junto a una muestra. Cada pagina se renderiza UNA vez a una textura con mipmaps y se muestra en un quad.
# Cada frame: se coloca del lado OPUESTO del hueco respecto a la cabeza (nunca mas cerca de la cabeza que distancia_min_cabeza_m)
# y se gira SOLO alrededor de la vertical hacia la cabeza.
# Cabeza = la camara 3D activa del viewport (en VR es la XRCamera3D); si no hay, core.cam.
#
# Estados (un solo boton/tecla los recorre en ciclo): 0 = compacto, 1..n = paginas del modo ampliado.
# TOPE DURO de tamano: el quad mide SIEMPRE ancho_compacto_m x alto_compacto_m (o los del ampliado); el contenido se ajusta
# dentro (la letra se reduce hasta caber) y lo que no cabe en el ampliado pasa a otra pagina. El cartel nunca crece.
#
# Depuracion (SOLO con argumentos; apagada por defecto):
#   --cartel-debug-orbita[=radio_m,vel_mps]   simula caminar en circulo alrededor del hueco (2 m, 1 m/s por defecto), imprime
#                                             el error de orientacion y la distancia, y cierra el visor tras 2 vueltas.
#   --cartel-modo=ampliado                    arranca en la primera pagina del modo ampliado.

var world: WorldStreamer
var core: Node
var M: Dictionary
var C: Dictionary
var xz := Vector2.ZERO
var estados: Array = []            # cada uno: {"tex": ImageTexture, "w": m, "h": m}
var idx := 0
var idx_ini := 0
var quad: MeshInstance3D
var mat: StandardMaterial3D
var ang := 0.0
var ang_ok := false
var yaw := 0.0
var yaw_ok := false
var objy_prev := 0.0
var pitch := 0.0
var vel_yaw := 0.0
var y_cart := 0.0
var y_cart_ok := false
var y_suelo := 0.0
var y_ok := false
var t_suelo := 0.0
var alfa := 0.0
var listo := false
var llegada_impresa := false
var tecla := KEY_I
var dbg := false
var dbg_r := 2.0
var dbg_v := 1.0
var dbg_a := 0.0
var dbg_next := 0.0
var dbg_max_yaw := 0.0
var dbg_max_3d := 0.0
var dbg_min_dist := 1e9
var cabeza_impresa := false


func setup(w: WorldStreamer, c: Node, m: Dictionary, pos_xz: Vector2) -> void:
	world = w
	core = c
	M = m
	C = m["cartel"]
	xz = pos_xz
	if str(C.get("modo_inicial", "compacto")) == "ampliado":
		idx_ini = 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cartel-modo="):
			idx_ini = 1 if a.get_slice("=", 1) == "ampliado" else 0
		elif a.begins_with("--cartel-debug-orbita"):
			dbg = true
			if "=" in a:
				var v := a.get_slice("=", 1).split_floats(",")
				dbg_r = v[0]
				if v.size() > 1:
					dbg_v = v[1]
	tecla = OS.find_keycode_from_string(str(C.get("tecla_modo", "I")))
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.disable_receive_shadows = true
	quad = MeshInstance3D.new()
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.material_override = mat
	quad.visible = false
	add_child(quad)
	_conectar_vr()
	_construir_todo()


func _conectar_vr() -> void:
	var nombre := str(C.get("boton_vr_modo", "grip_click"))
	for mano in [core.get("left"), core.get("right")]:
		if mano != null and mano.has_signal("button_pressed"):
			mano.button_pressed.connect(func(n: String): if n == nombre: _alternar())


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == tecla:
		_alternar()


# Compacto -> pagina 1 -> ... -> pagina n -> compacto (solo si este cartel se ve).
func _alternar() -> void:
	if not listo or alfa < 0.05:
		return
	_poner_estado((idx + 1) % estados.size())


func _poner_estado(i: int) -> void:
	idx = i
	var e: Dictionary = estados[idx]
	var qm := QuadMesh.new()
	qm.size = Vector2(float(e["w"]), float(e["h"]))
	quad.mesh = qm
	mat.albedo_texture = e["tex"]


# ---------------------------------------------------------------- contenido
func _construir_todo() -> void:
	var ppm := float(C["textura_px_por_m"])
	# compacto: 1 pagina de tamano fijo
	var wc := float(C["ancho_compacto_m"])
	var hc := float(C["alto_compacto_m"])
	var lineas: Array = M["compacto"]
	var bloques_c: Array = []
	for i in range(1, lineas.size()):
		bloques_c.append(["", str(lineas[i])])
	var fc := {"tit": int(C["fuente_compacto_titulo_px"]), "et": 0, "cu": int(C["fuente_compacto_cuerpo_px"]), "pie": int(C["fuente_compacto_pie_px"])}
	var r := await _pagina(int(wc * ppm), int(hc * ppm), str(lineas[0]), bloques_c, str(M["pie_compacto"]), fc, true)
	estados.append({"tex": r["tex"], "w": wc, "h": hc})
	print("cartel_muestras: compacto %.2f x %.2f m (tope %.2f x %.2f m); letra final cuerpo %d px, cabe=%s" % [wc, hc, wc, hc, r["fs_cu"], str(r["cabe"])])
	# ampliado: paginas de tamano fijo (se puede apagar con "ampliado_activo": false)
	if bool(C.get("ampliado_activo", true)):
		var wa := float(C["ancho_ampliado_m"])
		var ha := float(C["alto_ampliado_m"])
		var fa := {"tit": int(C["fuente_ampliado_titulo_px"]), "et": int(C["fuente_ampliado_etiqueta_px"]), "cu": int(C["fuente_ampliado_cuerpo_px"]), "pie": int(C["fuente_ampliado_pie_px"])}
		var paginas: Array = await _paginar(int(wa * ppm), int(ha * ppm), M["ampliado"], fa)
		for i in paginas.size():
			var pie := ("Página %d/%d · " % [i + 1, paginas.size()]) + str(M["pie_ampliado" if i < paginas.size() - 1 else "pie_ampliado_ultima"])
			if i == paginas.size() - 1 and M.has("creditos"):
				pie = str(M["creditos"]) + "\n" + pie
			var ra := await _pagina(int(wa * ppm), int(ha * ppm), str(M["titulo"]), paginas[i], pie, fa, false)
			estados.append({"tex": ra["tex"], "w": wa, "h": ha})
			print("cartel_muestras: ampliado pagina %d/%d %.2f x %.2f m (tope %.2f x %.2f m); %d bloques; cabe=%s" % [i + 1, paginas.size(), wa, ha, wa, ha, paginas[i].size(), str(ra["cabe"])])
	listo = true
	_poner_estado(clampi(idx_ini, 0, estados.size() - 1))


func _col(clave: String, def: Array) -> Color:
	var a: Array = C.get(clave, def)
	return Color(a[0], a[1], a[2], a[3] if a.size() > 3 else 1.0)


func _label(texto: String, px: int, col: Color) -> Label:
	var l := Label.new()
	l.text = texto
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", col)
	return l


# Arma el panel (fondo + contenido). f = tamanos de letra {"tit","et","cu","pie"}; bloques = [[etiqueta, texto], ...].
func _panel(pw: int, titulo: String, bloques: Array, pie: String, f: Dictionary, centrado: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = _col("color_fondo", [0.04, 0.045, 0.06, 0.88])
	sb.border_color = _col("color_borde", [0.85, 0.55, 0.35, 0.8])
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(int(pw * 0.025))
	sb.set_content_margin_all(int(pw * 0.03))
	sb.anti_aliasing = true
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = Vector2.ZERO
	panel.size = Vector2(pw, 10)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(f["cu"] * 0.35))
	if centrado:
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vb)
	vb.add_child(_label(titulo, f["tit"], _col("color_titulo", [1, 0.86, 0.58])))
	var sep := ColorRect.new()
	sep.custom_minimum_size = Vector2(0, 4)
	sep.color = _col("color_borde", [0.85, 0.55, 0.35, 0.8])
	vb.add_child(sep)
	for b in bloques:
		if str(b[0]) == "":
			vb.add_child(_label(str(b[1]), f["cu"], _col("color_cuerpo", [0.97, 0.97, 0.97])))
		else:
			var bl := VBoxContainer.new()
			bl.add_theme_constant_override("separation", 2)
			bl.add_child(_label(str(b[0]).to_upper(), f["et"], _col("color_etiqueta", [1, 0.64, 0.42])))
			bl.add_child(_label(str(b[1]), f["cu"], _col("color_cuerpo", [0.97, 0.97, 0.97])))
			vb.add_child(bl)
	if pie != "":
		vb.add_child(_label(pie, f["pie"], _col("color_pie", [0.72, 0.74, 0.8])))
	return panel


func _subvp(pw: int, ph: int) -> SubViewport:
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.msaa_2d = Viewport.MSAA_4X
	vp.size = Vector2i(pw, ph)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	return vp


# Altura minima (px) que necesita el contenido con esas letras.
func _alto_min(pw: int, titulo: String, bloques: Array, pie: String, f: Dictionary) -> float:
	var vp := _subvp(pw, 4000)
	var panel := _panel(pw, titulo, bloques, pie, f, false)
	vp.add_child(panel)
	for i in 3:
		await get_tree().process_frame
	var h := panel.get_combined_minimum_size().y
	vp.queue_free()
	return h


# Reparte los bloques del modo ampliado en paginas que quepan en ph (voraz). Se mide con el pie mas largo posible.
func _paginar(pw: int, ph: int, bloques: Array, f: Dictionary) -> Array:
	var pie_max := str(M.get("creditos", "")) + "\nPágina 9/9 · " + str(M["pie_ampliado_ultima"])
	var paginas: Array = []
	var actual: Array = []
	for b in bloques:
		var prueba := actual.duplicate()
		prueba.append(b)
		var h: float = await _alto_min(pw, str(M["titulo"]), prueba, pie_max, f)
		if h > ph and not actual.is_empty():
			paginas.append(actual)
			actual = [b]
		else:
			actual = prueba
	if not actual.is_empty():
		paginas.append(actual)
	return paginas


# Renderiza UNA pagina en una textura de pw x ph px (tamano fijo). Si el contenido no cabe, reduce la letra (hasta 55 %).
func _pagina(pw: int, ph: int, titulo: String, bloques: Array, pie: String, f0: Dictionary, centrado: bool) -> Dictionary:
	var k := 1.0
	var f := f0.duplicate()
	var cabe := false
	for it in 8:
		for kk in ["tit", "et", "cu", "pie"]:
			f[kk] = int(float(f0[kk]) * k)
		var h: float = await _alto_min(pw, titulo, bloques, pie, f)
		if h <= ph:
			cabe = true
			break
		k *= 0.93
		if k < 0.55:
			break
	var vp := _subvp(pw, ph)
	var panel := _panel(pw, titulo, bloques, pie, f, centrado)
	panel.clip_contents = true
	panel.size = Vector2(pw, ph)
	vp.add_child(panel)
	for i in 4:
		await get_tree().process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	img.generate_mipmaps()
	return {"tex": ImageTexture.create_from_image(img), "cabe": cabe, "fs_cu": f["cu"]}


# ---------------------------------------------------------------- orientacion y colocacion
func _cabeza() -> Node3D:
	var c := get_viewport().get_camera_3d()
	if c == null:
		c = core.get("cam") as Camera3D
	return c


func _process(d: float) -> void:
	if not listo:
		return
	if dbg:
		_debug_orbita(d)
	var cam := _cabeza()
	if cam == null:
		return
	var cab := cam.global_position
	if not cabeza_impresa:
		cabeza_impresa = true
		print("cartel_muestras: cabeza = %s (%s), XR=%s, es core.cam: %s" % [cam.get_path(), cam.get_class(), str(cam is XRCamera3D), str(cam == core.get("cam"))])
	var dx := xz.x - cab.x
	var dz := xz.y - cab.z
	var dist := Vector2(dx, dz).length()
	var r := float(C["radio_visible_m"])
	var fu := maxf(float(C["fundido_m"]), 0.01)
	alfa = 1.0 - smoothstep(r - fu, r, dist)
	quad.visible = alfa > 0.01
	if not quad.visible:
		return
	mat.albedo_color = Color(1, 1, 1, alfa * float(C["opacidad"]))
	t_suelo -= d
	if t_suelo <= 0.0:
		t_suelo = 0.5
		var hy := world.height_at(xz.x, xz.y)
		if not y_ok:
			y_suelo = hy
			y_ok = true
		else:
			y_suelo = lerpf(y_suelo, hy, 1.0 - exp(-0.5 / maxf(float(C["suavizado_altura_s"]), 0.01)))
	# lado opuesto del hueco; si estas casi encima del hueco se conserva la ultima direccion
	if dist > float(C["dist_min_direccion_m"]) or not ang_ok:
		var obj := atan2(dx, dz)
		if not ang_ok:
			ang = obj
			ang_ok = true
		else:
			ang = lerp_angle(ang, obj, 1.0 - exp(-d / maxf(float(C["suavizado_orbita_s"]), 0.01)))
	var dh := float(C["distancia_hueco_m"])
	# altura del centro: proporcional a la altura de tus ojos sobre el suelo del hueco (altura_factor_ojos), entre altura_min_m y altura_max_m:
	var h_obj := clampf(float(C["altura_factor_ojos"]) * (cab.y - y_suelo), float(C["altura_min_m"]), float(C["altura_max_m"])) + y_suelo
	if not y_cart_ok:
		y_cart = h_obj
		y_cart_ok = true
	else:
		y_cart = lerpf(y_cart, h_obj, 1.0 - exp(-d / maxf(float(C["suavizado_altura_s"]), 0.01)))
	var pos := Vector3(xz.x + sin(ang) * dh, y_cart, xz.y + cos(ang) * dh)
	# distancia minima a la cabeza: si estas mas cerca, el cartel se aleja (mismo tamano aparente como minimo)
	var dmin := float(C["distancia_min_cabeza_m"])
	var dy := pos.y - cab.y
	var hmin := sqrt(maxf(dmin * dmin - dy * dy, 0.0))
	var hv := Vector2(pos.x - cab.x, pos.z - cab.z)
	if hv.length() < hmin:
		var u := hv.normalized() if hv.length() > 1e-4 else Vector2(sin(ang), cos(ang))
		pos.x = cab.x + u.x * hmin
		pos.z = cab.z + u.y * hmin
	global_position = pos
	# giro SOLO alrededor de la vertical, mirando a la cabeza (la cara de lectura del quad es +Z)
	var objy := atan2(cab.x - pos.x, cab.z - pos.z)
	var tau := maxf(float(C["suavizado_giro_s"]), 0.01)
	if not yaw_ok:
		yaw = objy
		objy_prev = objy
		yaw_ok = true
	else:
		# el suavizado solo se retrasa respecto a un objetivo que se mueve: se compensa con la velocidad (filtrada) del objetivo
		var v := angle_difference(objy_prev, objy) / maxf(d, 1e-4)
		objy_prev = objy
		vel_yaw = lerpf(vel_yaw, clampf(v, -3.0, 3.0), 1.0 - exp(-d / 0.15))
		yaw = lerp_angle(yaw, objy + vel_yaw * tau, 1.0 - exp(-d / tau))
	# inclinacion arriba/abajo hacia la cabeza (suavizada y limitada); con "inclinar": false el cartel queda siempre vertical
	var pit_obj := 0.0
	if bool(C.get("inclinar", true)):
		var lim := deg_to_rad(float(C.get("inclinacion_max_deg", 70.0)))
		pit_obj = clampf(atan2(cab.y - pos.y, Vector2(cab.x - pos.x, cab.z - pos.z).length()), -lim, lim)
	pitch = lerpf(pitch, pit_obj, 1.0 - exp(-d / tau))
	rotation = Vector3(-pitch, yaw, 0.0)      # orden YXZ: primero el giro vertical, luego la inclinacion
	if not llegada_impresa:
		llegada_impresa = true
		print("cartel_muestras: al llegar, distancia cabeza-cartel = %.2f m (minimo configurado %.2f m)" % [cab.distance_to(pos), dmin])


# ---------------------------------------------------------------- depuracion: caminar en circulo alrededor del hueco
func _debug_orbita(d: float) -> void:
	var o := core.get("origin") as Node3D
	if o == null or not world.is_ready():
		return
	dbg_a += dbg_v / dbg_r * d
	o.position = Vector3(xz.x + sin(dbg_a) * dbg_r, o.position.y, xz.y + cos(dbg_a) * dbg_r)
	core.set("yaw", dbg_a)                  # en escritorio la camara mira el hueco: forward = (-sin a, -cos a)
	core.set("pitch", deg_to_rad(-8.0))
	if not yaw_ok:
		return
	var cam := _cabeza()
	var normal := global_transform.basis.z   # cara de lectura
	var a_cam := cam.global_position - global_position
	var e3 := rad_to_deg(normal.angle_to(a_cam))
	var nh := Vector2(normal.x, normal.z)
	var ah := Vector2(a_cam.x, a_cam.z)
	var ey := rad_to_deg(absf(nh.angle_to(ah)))
	var dist_c := a_cam.length()
	var grados := rad_to_deg(dbg_a)
	if grados > 360.0:                       # la primera vuelta es de asentamiento
		dbg_max_yaw = maxf(dbg_max_yaw, ey)
		dbg_max_3d = maxf(dbg_max_3d, e3)
		dbg_min_dist = minf(dbg_min_dist, dist_c)
	if grados >= dbg_next:
		dbg_next += 30.0
		print("cartel_debug: giro %4.0f deg | error de giro (horizontal) %.2f deg | error 3D %.2f deg | dist cabeza-cartel %.2f m | cartel %.2f x %.2f m | espejado=%s" % [
			grados, ey, e3, dist_c, float((estados[idx] as Dictionary)["w"]), float((estados[idx] as Dictionary)["h"]), str(global_transform.basis.determinant() < 0.0)])
	if grados >= 720.0:
		print("cartel_debug: RESUMEN 2a vuelta (asentado): error horizontal max %.2f deg | error 3D max %.2f deg | dist minima cabeza-cartel %.2f m" % [dbg_max_yaw, dbg_max_3d, dbg_min_dist])
		get_tree().quit()

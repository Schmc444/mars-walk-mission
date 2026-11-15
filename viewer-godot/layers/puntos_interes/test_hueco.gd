extends Node3D
# PASO 1: solo la GEOMETRIA del hueco de la perforacion (muestra 24 "Comet Geyser") sobre un suelo plano. Sin texturas ni roca.
# Abrir test_hueco.tscn en el editor de Godot y pulsar F6. No toca el nucleo ni layer.gd.
# Todos los valores salen de puntos.json -> "perforacion".
#
# Teclas:  C = acercar a ~20 cm del hueco   P = acercar al parche   V = volver a la vista general   S = corte (seccion) si/no
#          Q / E = girar alrededor   + / - o rueda = acercar / alejar   Esc = salir
# Argumentos opcionales (despues de --):  --cerca  --seccion  --yaw=grados

var P: Dictionary
var cam: Camera3D
var suelo: CSGBox3D
var corte: CSGBox3D
var anillo: MeshInstance3D
var hud: Label
var hv := 0.0                    # hade medido desde la vertical (rad)
var d_in := Vector3.DOWN         # eje del taladro, hacia DENTRO (escena)
var n_out := Vector3.UP          # eje hacia fuera (normal de la boca)
var dh := Vector3.RIGHT          # direccion horizontal hacia la que se inclina el hueco al profundizar
var n_corte := Vector3.BACK      # lado que se quita en el corte
var prof := 0.058
var cerca := false
var en_parche := false
var pos_parche := Vector3.ZERO
var seccion := false
var yaw := 0.0
var zoom := 1.0
var dist_gen := 0.45
var dist_cer := 0.20


func _ready() -> void:
	var datos = JSON.parse_string(FileAccess.get_file_as_string("res://layers/puntos_interes/puntos.json"))
	if datos == null:
		push_error("test_hueco: puntos.json no es JSON valido")
		return
	for p in datos:
		if p.has("perforacion"):
			P = p["perforacion"]
			break
	if P.is_empty():
		push_error("test_hueco: puntos.json no tiene el bloque 'perforacion'")
		return
	for a in OS.get_cmdline_user_args():
		if a == "--cerca":
			cerca = true
		elif a == "--seccion":
			seccion = true
		elif a.begins_with("--yaw="):
			yaw = deg_to_rad(float(a.substr(6)))
	var R := float(P["diametro_mm"]) * 0.0005
	prof = float(P["profundidad_mm"]) * 0.001
	dist_cer = float(P["prueba"]["camara_cerca_cm"]) * 0.01
	dist_gen = float(P["prueba"]["camara_general_cm"]) * 0.01

	# ---------------- convencion y conversion SITE -> escena (SUPUESTOS, ver puntos.json) ----------------
	var hade := float(P["hade_deg"])
	var hade_v := (90.0 - hade) if bool(P.get("hade_desde_horizontal", false)) else hade
	var az := float(P["azimuth_deg"])
	if bool(P.get("azimuth_es_hacia_afuera", false)):
		az += 180.0
	hv = deg_to_rad(hade_v)
	var ar := deg_to_rad(az)
	var comp_n := sin(hv) * cos(ar)          # SITE X (norte)
	var comp_e := sin(hv) * sin(ar)          # SITE Y (este)
	var comp_d := cos(hv)                    # SITE Z (abajo)
	d_in = Vector3(comp_e, -comp_d, -comp_n).normalized()   # escena: x = este, y = arriba, z = sur
	n_out = -d_in
	dh = Vector3(d_in.x, 0.0, d_in.z)
	dh = dh.normalized() if dh.length() > 1e-6 else Vector3.RIGHT
	n_corte = dh.cross(Vector3.UP)

	_entorno()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.33, 0.22)
	mat.roughness = 1.0
	_suelo_con_hueco(R, mat)
	var col: Array = P["polvo"]["color"]
	anillo = _anillo(R, Color(col[0], col[1], col[2]))
	add_child(anillo)
	_ayudas(R)
	cam = Camera3D.new()
	cam.near = 0.002                       # 2 mm: no recorta nada de 13 mm a 20 cm
	cam.far = 50.0
	cam.fov = 55.0
	add_child(cam)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 14)
	var sbx := StyleBoxFlat.new()
	sbx.bg_color = Color(0, 0, 0, 0.55)
	sbx.content_margin_left = 8
	sbx.content_margin_right = 8
	sbx.content_margin_top = 4
	sbx.content_margin_bottom = 4
	hud.add_theme_stylebox_override("normal", sbx)
	add_child(hud)
	_set_seccion(seccion)
	_imprimir(R, hade_v, az)


func _entorno() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.85, 0.6, 0.45)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.7, 0.6)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -40, 0)
	sun.shadow_enabled = true
	add_child(sun)


# Suelo = bloque CSG (cara superior en y = 0) menos el cilindro inclinado del hueco, menos el parche, menos (opcional) el corte.
func _suelo_con_hueco(R: float, mat: StandardMaterial3D) -> void:
	suelo = CSGBox3D.new()
	suelo.size = Vector3(4.0, 0.3, 4.0)
	suelo.position = Vector3(0.0, -0.15, 0.0)
	suelo.material = mat
	add_child(suelo)
	var extra := 0.03                                  # el cilindro sobresale 3 cm por encima del suelo
	# hueco: el eje pasa por el origen; va de s = -extra (fuera) a s = prof (fondo), a lo largo de d_in
	var hole := CSGCylinder3D.new()
	hole.operation = CSGShape3D.OPERATION_SUBTRACTION
	hole.radius = R
	hole.height = prof + extra
	hole.sides = 64
	hole.material = mat
	hole.basis = Basis(Quaternion(Vector3.UP, n_out))
	hole.position = d_in * ((prof - extra) * 0.5) - suelo.position
	suelo.add_child(hole)
	# parche abrasionado: disco vertical poco profundo
	var ab: Dictionary = P["abrasion"]
	var pr := float(ab["diametro_mm"]) * 0.0005
	var pd := float(ab["profundidad_mm"]) * 0.001
	var pos: Array = ab["pos_m"]
	var patch := CSGCylinder3D.new()
	patch.operation = CSGShape3D.OPERATION_SUBTRACTION
	patch.radius = pr
	patch.height = pd + extra
	patch.sides = 64
	patch.material = mat
	patch.position = Vector3(pos[0], (extra - pd) * 0.5, pos[1]) - suelo.position
	pos_parche = Vector3(pos[0], 0.0, pos[1])
	suelo.add_child(patch)
	# corte: caja que quita el lado +n_corte del plano vertical que contiene el eje (fuera de escena = apagado)
	corte = CSGBox3D.new()
	corte.operation = CSGShape3D.OPERATION_SUBTRACTION
	corte.size = Vector3(4.0, 4.0, 4.0)
	var mc := StandardMaterial3D.new()
	mc.albedo_color = Color(0.85, 0.62, 0.45)       # cara del corte: color distinto para distinguirla
	mc.roughness = 1.0
	corte.material = mc
	corte.basis = Basis(dh, Vector3.UP, n_corte)
	suelo.add_child(corte)


# Anillo plano de polvo claro (tailings): borde interior = la elipse de entrada, borde exterior irregular.
func _anillo(R: float, color: Color) -> MeshInstance3D:
	var pv: Dictionary = P["polvo"]
	var ro_base := float(pv["radio_externo_mm"]) * 0.001
	var irr := float(pv["irregularidad"])
	var n2 := FastNoiseLite.new()
	n2.seed = int(pv["semilla"])
	n2.frequency = 1.0
	var a_maj := R / cos(hv)                           # semieje mayor de la elipse de entrada (a lo largo de dh)
	var w := n_corte                                   # horizontal, perpendicular a dh (semieje menor = R)
	var N := 128
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in N:
		var ph := TAU * float(i) / float(N)
		var c := cos(ph)
		var s := sin(ph)
		var inner := dh * (a_maj * c) + w * (R * s)
		var ro := maxf(ro_base * (1.0 + irr * n2.get_noise_2dv(Vector2(c, s) * 2.0)), a_maj * 1.4)
		var outer := (dh * c + w * s) * ro
		inner.y = 0.0007
		outer.y = 0.0007
		verts.append(inner)
		verts.append(outer)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
	for i in N:
		var j := (i + 1) % N
		idx.append(2 * i)
		idx.append(2 * i + 1)
		idx.append(2 * j)
		idx.append(2 * i + 1)
		idx.append(2 * j + 1)
		idx.append(2 * j)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = m
	mi.name = "anillo_polvo"
	return mi


func _plano(color: Color, sin_luz := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if sin_luz:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _etiqueta(txt: String, pos: Vector3, tam := 0.00022) -> void:
	var l := Label3D.new()
	l.text = txt
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = tam
	l.font_size = 36
	l.outline_size = 8
	l.position = pos
	add_child(l)


func _cil(r: float, h: float, pos: Vector3, eje: Vector3, mat: Material, r_top := -1.0) -> void:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r
	cm.top_radius = r if r_top < 0.0 else r_top
	cm.height = h
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = mat
	mi.basis = Basis(Quaternion(Vector3.UP, eje))
	mi.position = pos
	add_child(mi)


# Ayudas para verificar: flecha del eje, vertical, norte/este, proyeccion horizontal del eje, regla de 1 y 10 cm.
func _ayudas(R: float) -> void:
	var fuera := 0.15
	var cian := _plano(Color(0.1, 0.9, 1.0))
	_cil(0.0006, prof + fuera, n_out * ((fuera - prof) * 0.5), n_out, cian)             # eje (la parte interior se ve por la boca / en el corte)
	_cil(0.004, 0.02, n_out * (fuera + 0.01), n_out, cian, 0.0)                          # punta de la flecha
	_etiqueta("eje del taladro (hacia fuera)", n_out * (fuera + 0.04))
	_cil(0.0004, 0.15, Vector3(0, 0.075, 0), Vector3.UP, _plano(Color(1.0, 0.9, 0.2)))   # vertical
	_etiqueta("vertical", Vector3(0, 0.16, 0))
	# direcciones sobre el suelo
	var gris := _plano(Color(0.15, 0.15, 0.15))
	_cil(0.0005, 0.22, Vector3(0, 0.0005, -0.11), Vector3(0, 0, 1), gris)                # norte = -z
	_etiqueta("N (norte = -z)", Vector3(0, 0.012, -0.235))
	_cil(0.0005, 0.22, Vector3(0.11, 0.0005, 0), Vector3(1, 0, 0), gris)                 # este = +x
	_etiqueta("E (este = +x)", Vector3(0.235, 0.012, 0))
	_cil(0.0007, 0.20, dh * 0.10 + Vector3(0, 0.0008, 0), dh, _plano(Color(0.9, 0.2, 0.9)))
	_etiqueta("hacia donde se inclina al profundizar (azimuth)", dh * 0.21 + Vector3(0, 0.012, 0))
	# regla de 10 cm en tramos de 1 cm, junto al hueco
	var pr: Dictionary = P["prueba"]
	var rl := float(pr["regla_largo_cm"]) * 0.01
	var rp: Array = pr["regla_pos_m"]
	var nseg := int(round(rl / 0.01))
	for i in nseg:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.01, 0.0012, 0.006)
		b.mesh = bm
		b.material_override = _plano(Color(0.05, 0.05, 0.05) if i % 2 == 0 else Color(0.95, 0.95, 0.95), false)
		b.position = Vector3(rp[0] + 0.01 * (i + 0.5), 0.0006, rp[1])
		add_child(b)
	var tk := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.0008, 0.004, 0.012)
	tk.mesh = tm
	tk.material_override = _plano(Color(1.0, 0.1, 0.1))
	tk.position = Vector3(rp[0] + rl, 0.002, rp[1])
	add_child(tk)
	_etiqueta("1 cm", Vector3(rp[0] + 0.005, 0.009, rp[1] + 0.012), 0.00018)
	_etiqueta("%d cm" % int(round(rl * 100.0)), Vector3(rp[0] + rl, 0.009, rp[1] + 0.012), 0.00018)


func _set_seccion(on: bool) -> void:
	seccion = on
	if on:
		corte.position = n_corte * 2.0 - suelo.position
	else:
		corte.position = Vector3(0.0, 1000.0, 0.0)       # lejos: no resta nada
	if anillo:
		anillo.visible = not on


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed:
		match e.keycode:
			KEY_C:
				cerca = true
				en_parche = false
			KEY_P:
				cerca = true
				en_parche = true
				_set_seccion(false)
			KEY_V:
				cerca = false
				en_parche = false
			KEY_S:
				en_parche = false
				_set_seccion(not seccion)
			KEY_Q: yaw -= 0.3
			KEY_E: yaw += 0.3
			KEY_EQUAL, KEY_KP_ADD: zoom = maxf(zoom * 0.8, 0.1)
			KEY_MINUS, KEY_KP_SUBTRACT: zoom = minf(zoom * 1.25, 5.0)
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = maxf(zoom * 0.85, 0.1)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = minf(zoom * 1.15, 5.0)


func _process(_d: float) -> void:
	if cam == null:
		return
	var dist := (dist_cer if cerca else dist_gen) * zoom
	var elev := deg_to_rad(20.0) if seccion else deg_to_rad(40.0)
	var base := n_corte if seccion else Vector3.BACK
	var hdir := base.rotated(Vector3.UP, yaw)
	var target := Vector3.ZERO
	if seccion:
		target = d_in * prof * 0.5
	elif en_parche:
		target = pos_parche
	cam.position = target + hdir * dist * cos(elev) + Vector3.UP * dist * sin(elev)
	cam.look_at(target, Vector3.UP)
	hud.text = "PASO 1: geometria del hueco (sin texturas ni roca). Suelo horizontal.   Vista: %s%s, camara a %.0f cm\nC acercar al hueco (20 cm) | P al parche | V volver | S corte | Q/E girar | +/- o rueda zoom\nCian = eje del taladro, amarillo = vertical, magenta = proyeccion horizontal del eje, regla: 1 cm por tramo, marca roja = 10 cm.\nSUPUESTOS: convencion hade/azimuth, profundidad del parche y forma del fondo (ver salida y puntos.json)." % [
		("cerca (parche)" if en_parche else "cerca (hueco)") if cerca else "general", " + CORTE" if seccion else "", dist * 100.0]
	hud.position = Vector2(10.0, get_viewport().get_visible_rect().size.y - hud.size.y - 10.0)


func _imprimir(R: float, hade_v: float, az_usado: float) -> void:
	var a_maj := R / cos(hv)
	var az_check := fposmod(rad_to_deg(atan2(dh.x, -dh.z)), 360.0)
	print("test_hueco: ================ CONVENCION Y CONVERSION (SUPUESTOS, NO VERIFICADOS) ================")
	print("test_hueco: hade dado = %.2f deg  -> usado como angulo desde la %s = %.2f deg" % [
		float(P["hade_deg"]), "HORIZONTAL (convertido)" if bool(P.get("hade_desde_horizontal", false)) else "VERTICAL", hade_v])
	print("test_hueco: azimuth dado = %.2f deg (norte -> este, horario); %s -> rumbo del eje hacia dentro = %.2f deg" % [
		float(P["azimuth_deg"]), "interpretado como rumbo hacia AFUERA (+180)" if bool(P.get("azimuth_es_hacia_afuera", false)) else "interpretado como rumbo hacia DENTRO", az_usado])
	print("test_hueco: SITE (N, E, abajo) del eje hacia dentro = (%.4f, %.4f, %.4f)" % [sin(hv) * cos(deg_to_rad(az_usado)), sin(hv) * sin(deg_to_rad(az_usado)), cos(hv)])
	print("test_hueco: escena (x este, y arriba, z sur): x = E, y = -abajo, z = -N")
	print("test_hueco: eje hacia DENTRO (escena) = (%.4f, %.4f, %.4f)" % [d_in.x, d_in.y, d_in.z])
	print("test_hueco: eje hacia FUERA  (escena) = (%.4f, %.4f, %.4f)  [angulo con la vertical = %.2f deg]" % [n_out.x, n_out.y, n_out.z, rad_to_deg(acos(n_out.y))])
	print("test_hueco: horizontal hacia donde se inclina al profundizar = (%.4f, 0, %.4f); rumbo comprobado = %.2f deg desde el norte" % [dh.x, dh.z, az_check])
	print("test_hueco: ================ DIMENSIONES FINALES ================")
	print("test_hueco: diametro = %.1f mm (radio %.2f mm); profundidad a lo largo del eje = %.1f mm" % [R * 2000.0, R * 1000.0, prof * 1000.0])
	print("test_hueco: profundidad VERTICAL = %.1f mm; el fondo queda desplazado %.1f mm en horizontal respecto a la boca" % [prof * cos(hv) * 1000.0, prof * sin(hv) * 1000.0])
	print("test_hueco: entrada elíptica sobre suelo horizontal: semieje menor = %.2f mm, semieje mayor = %.2f mm (a lo largo de la direccion de inclinacion)" % [R * 1000.0, a_maj * 1000.0])
	var ab: Dictionary = P["abrasion"]
	print("test_hueco: parche abrasionado: diametro = %.1f mm, profundidad = %.1f mm (SUPUESTO provisional), pos = %s m" % [float(ab["diametro_mm"]), float(ab["profundidad_mm"]), str(ab["pos_m"])])
	print("test_hueco: anillo de polvo: radio exterior medio = %.1f mm, irregularidad = %.2f (forma/color planos, sin textura)" % [float(P["polvo"]["radio_externo_mm"]), float(P["polvo"]["irregularidad"])])
	print("test_hueco: forma del fondo: plano y perpendicular al eje (SUPUESTO; los datos no definen el interior)")

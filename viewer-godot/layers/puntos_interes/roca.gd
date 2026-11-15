extends Node3D
# Capa puntos_interes: RECREACION APROXIMADA de la roca "Bunsen Peak" junto al hueco de la muestra 24 (NO es un escaneo).
# UNA SOLA malla continua (ArrayMesh): una superficie de alturas en el marco de la losa, sin piezas ni solapes.
#  - Contorno irregular y asimetrico de la linea roja de refs/ref_panel_c_contorno.png (cerrado), estirado a ancho_m x largo_m.
#  - Cara superior: suave, con la normal = -eje del taladro (el plano pasa por la boca del futuro hueco) y ondulacion leve de ruido.
#    Un circulo de ~15 cm alrededor del futuro hueco es EXACTAMENTE plano.
#  - Borde redondeado que baja en una pared continua hasta quedar enterrada enterrado_m bajo el terreno (sin aletas ni voladizos).
#  - Textura: recorte de refs/ref_panel_c.png proyectado desde arriba (los costados toman la misma textura estirada hacia abajo).
#  - Colision (malla de triangulos) y bloqueo de paso.
# Marco de la losa: u = a la derecha (rumbo), v = hacia donde sube la losa (en su plano), n = normal = -eje del taladro.
# La malla es LOCAL a la boca del futuro hueco (a ~7 km del origen un float de 32 bits solo distingue ~0.5 mm).
# Todos los valores estan en puntos.json -> "roca" (lo "estimado" no sale de datos).
# Depuracion (despues de --): --roca-elevar=m   --roca-cam=dx,dy,dz,tx,ty,tz,fov (relativos a la boca)

var world: WorldStreamer
var core: Node
var Pr: Dictionary
var perf: Dictionary
var xz0 := Vector2.ZERO
var armada := false
var H := Vector3.ZERO
var g_ref := 0.0
var e_n := Vector3.UP
var e_u := Vector3.RIGHT
var e_v := Vector3.FORWARD
var poly := PackedVector2Array()
var ruido := FastNoiseLite.new()
var r_plano := 0.075
var r_trans := 0.2
var amp := 0.025
var r_borde := 0.06
var w_pared := 0.05
var ent := 0.10
var paso_max := 0.25
var t_espera := 0.0
var t_listo := 0.0
var ok_prev := Vector3.ZERO
var tiene_prev := false


func setup(w: WorldStreamer, c: Node, params: Dictionary, pos_xz: Vector2, perforacion: Dictionary) -> void:
	world = w
	core = c
	Pr = params
	xz0 = pos_xz
	perf = perforacion
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--roca-elevar="):
			Pr["elevar_hueco_m"] = float(a.substr(14))
	print("roca: lista; espera a que cargue el terreno")


func _process(d: float) -> void:
	if not armada:
		t_espera -= d
		if t_espera <= 0.0:
			t_espera = 0.5
			_intentar()
		return
	_bloquear()


func _intentar() -> void:
	var px := xz0.x / world.sx + world.opx
	var py := xz0.y / world.sz + world.opy
	var k := Vector2i(floori(px / world.block), floori(py / world.block))
	if not world.tiles.has(k) or (world.tiles[k]["h1"] as PackedFloat32Array).is_empty():
		return
	t_listo += 0.5
	if t_listo < 2.0:
		return
	var hade := float(perf["hade_deg"])
	var hv := deg_to_rad((90.0 - hade) if bool(perf.get("hade_desde_horizontal", false)) else hade)
	var az := float(perf["azimuth_deg"])
	if bool(perf.get("azimuth_es_hacia_afuera", false)):
		az += 180.0
	var ar := deg_to_rad(az)
	var d_in := Vector3(sin(hv) * sin(ar), -cos(hv), -sin(hv) * cos(ar)).normalized()    # eje del taladro, igual que el hueco
	_construir(d_in)
	armada = true


# ---- geometria ----
func _ondul(u: float, v: float) -> float:
	var r := sqrt(u * u + v * v)
	return amp * ruido.get_noise_2d(u * 100.0, v * 100.0) * smoothstep(r_plano, r_trans, r)


# distancia con signo al contorno (negativa dentro)
func _sd(p: Vector2) -> float:
	var m := 1e9
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var e := b - a
		var t := clampf((p - a).dot(e) / maxf(e.length_squared(), 1e-12), 0.0, 1.0)
		m = minf(m, p.distance_to(a + e * t))
	return -m if Geometry2D.is_point_in_polygon(p, poly) else m


func _plano_y(u: float, v: float) -> float:        # altura (vertical, relativa a la boca) del plano de la losa
	return u * e_u.y + v * e_v.y


func _suelo(u: float, v: float) -> float:          # altura del terreno (relativa a la boca) bajo el punto (u, v) del plano
	var x := H.x + u * e_u.x + v * e_v.x
	var z := H.z + u * e_u.z + v * e_v.z
	return world.height_at(x, z) - H.y


func _construir(d_in: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	e_n = -d_in
	var e_vh := Vector3(d_in.x, 0.0, d_in.z).normalized()
	e_u = e_vh.cross(Vector3.UP).normalized()
	e_v = e_n.cross(e_u).normalized()
	ruido.seed = int(Pr.get("semilla", 5))
	ruido.frequency = float(Pr.get("ondulacion_frecuencia", 1.3)) * 0.01
	r_plano = float(Pr.get("plano_radio_m", 0.075))
	r_trans = float(Pr.get("plano_transicion_m", 0.2))
	amp = float(Pr.get("ondulacion_m", 0.025))
	r_borde = float(Pr.get("radio_borde_m", 0.06))
	w_pared = float(Pr.get("pared_ancho_m", 0.05))
	ent = float(Pr.get("enterrado_m", 0.10))
	paso_max = float(Pr.get("paso_max_m", 0.25))
	# contorno: normalizado [0,1]^2 -> metros, con el futuro hueco en (0, 0)
	var W := float(Pr["ancho_m"])
	var L := float(Pr["largo_m"])
	var fx := float(Pr["hueco_desde_izquierda"])
	var fy := 1.0 - float(Pr["hueco_desde_arriba"])
	poly.clear()
	for q in Pr["contorno"]:
		poly.append(Vector2((float(q[0]) - fx) * W, (float(q[1]) - fy) * L))
	# boca del futuro hueco: terreno + elevar (automatico: el borde mas bajo de la losa queda a ras del suelo)
	g_ref = world.height_at(xz0.x, xz0.y)
	H = Vector3(xz0.x, g_ref, xz0.y)
	var elev = Pr.get("elevar_hueco_m", null)
	var auto := elev == null
	if auto:
		var mn := 1e9
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			for s in 4:
				var p := a.lerp(b, s * 0.25)
				mn = minf(mn, _plano_y(p.x, p.y) - _suelo(p.x, p.y))
		elev = maxf(-mn, 0.0)
	var elevar := float(elev)
	H.y = g_ref + elevar
	position = H
	# malla de alturas sobre el plano de la losa
	var h_cel := float(Pr.get("malla_cm", 1.5)) * 0.01
	var mn2 := Vector2(1e9, 1e9)
	var mx2 := Vector2(-1e9, -1e9)
	for p in poly:
		mn2 = Vector2(minf(mn2.x, p.x), minf(mn2.y, p.y))
		mx2 = Vector2(maxf(mx2.x, p.x), maxf(mx2.y, p.y))
	var pad := w_pared + 0.06
	mn2 -= Vector2(pad, pad)
	mx2 += Vector2(pad, pad)
	var nu := int(ceil((mx2.x - mn2.x) / h_cel)) + 1
	var nv := int(ceil((mx2.y - mn2.y) / h_cel)) + 1
	var P := PackedVector3Array()
	var UV := PackedVector2Array()
	var DD := PackedFloat32Array()
	P.resize(nu * nv)
	UV.resize(nu * nv)
	DD.resize(nu * nv)
	var tile: Array = Pr["textura_mosaico_m"]
	for i in nu:
		for j in nv:
			var u := mn2.x + i * h_cel
			var v := mn2.y + j * h_cel
			var d := _sd(Vector2(u, v))
			var h := 0.0
			if d <= -r_borde:
				h = _ondul(u, v)
			elif d <= 0.0:
				h = _ondul(u, v) - (r_borde - sqrt(maxf(r_borde * r_borde - (d + r_borde) * (d + r_borde), 0.0)))      # borde redondeado
			else:
				var y_pl := _plano_y(u, v) + _ondul(u, v) * e_n.y
				var h_bot := (_suelo(u, v) - ent - y_pl) / e_n.y                  # h con el que el vertice queda 'enterrado' bajo el terreno
				var dn := maxf(-h_bot, r_borde + 0.02)
				var tt := clampf(d / w_pared, 0.0, 1.0)
				h = _ondul(u, v) - (r_borde + tt * (dn - r_borde)) - (0.03 if tt >= 1.0 else 0.0)
			P[i * nv + j] = e_u * u + e_v * v + e_n * h
			UV[i * nv + j] = Vector2(u / float(tile[0]), -v / float(tile[1]))
			DD[i * nv + j] = d
	var N := PackedVector3Array()
	N.resize(nu * nv)
	for i in nu:
		for j in nv:
			var i0 := maxi(i - 1, 0)
			var i1 := mini(i + 1, nu - 1)
			var j0 := maxi(j - 1, 0)
			var j1 := mini(j + 1, nv - 1)
			var nn := (P[i1 * nv + j] - P[i0 * nv + j]).cross(P[i * nv + j1] - P[i * nv + j0])
			N[i * nv + j] = nn.normalized() if nn.length_squared() > 1e-18 else e_n
	var idx := PackedInt32Array()
	for i in nu - 1:
		for j in nv - 1:
			var a := i * nv + j
			var b := (i + 1) * nv + j
			var c := i * nv + j + 1
			var d2 := (i + 1) * nv + j + 1
			if minf(minf(DD[a], DD[b]), minf(DD[c], DD[d2])) > w_pared + 0.02:
				continue                                                          # lejos del contorno: ya esta bajo tierra
			idx.append_array([a, c, b, b, c, d2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = P
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UV
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var m := ShaderMaterial.new()
	m.shader = load("res://layers/puntos_interes/losa.gdshader") as Shader
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://layers/puntos_interes/" + String(Pr["textura"])))
	img.generate_mipmaps()
	m.set_shader_parameter("tex", ImageTexture.create_from_image(img))
	var tn: Array = Pr.get("tono", [1.0, 1.0, 1.0])
	m.set_shader_parameter("tono", Vector3(float(tn[0]), float(tn[1]), float(tn[2])))
	var dt: Dictionary = Pr.get("detalle", {})          # capa de detalle superficial (WATSON): intensidad, escalas y rotaciones en puntos.json
	if not dt.is_empty():
		var di := Image.load_from_file(ProjectSettings.globalize_path("res://layers/puntos_interes/" + String(dt["imagen"])))
		di.generate_mipmaps()
		m.set_shader_parameter("detalle", ImageTexture.create_from_image(di))
		m.set_shader_parameter("det_int", float(dt["intensidad"]))
		m.set_shader_parameter("det_a", Vector4(float(dt["capa_a"]["escala_m"]), deg_to_rad(float(dt["capa_a"]["rotacion_deg"])), float(dt["capa_a"]["desplazamiento"][0]), float(dt["capa_a"]["desplazamiento"][1])))
		m.set_shader_parameter("det_b", Vector4(float(dt["capa_b"]["escala_m"]), deg_to_rad(float(dt["capa_b"]["rotacion_deg"])), float(dt["capa_b"]["desplazamiento"][0]), float(dt["capa_b"]["desplazamiento"][1])))
		m.set_shader_parameter("tri_base", Vector2(float(dt.get("triplanar_base", 0.0)), float(dt.get("base_mosaico_m", 1.5))))
		m.set_shader_parameter("n_losa", e_n)
	var mi := MeshInstance3D.new()
	mi.name = "roca_malla"
	mi.mesh = am
	mi.material_override = m
	add_child(mi)
	var sb := StaticBody3D.new()
	sb.name = "colision_roca"
	var cs := CollisionShape3D.new()
	cs.shape = am.create_trimesh_shape()
	sb.add_child(cs)
	add_child(sb)
	var cmd := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--roca-cam="):
			cmd = a.substr(11)
	if cmd != "":
		var v := cmd.split_floats(",")
		var cam := Camera3D.new()
		cam.near = 0.005
		cam.far = 4000.0
		cam.fov = v[6]
		add_child(cam)
		cam.global_position = H + Vector3(v[0], v[1], v[2])
		cam.look_at(H + Vector3(v[3], v[4], v[5]), Vector3.UP)
		cam.make_current()
	_informe(t0, elevar, auto, nu, nv, idx.size() / 3)


func _informe(t0: int, elevar: float, auto: bool, nu: int, nv: int, tris: int) -> void:
	var amin := 1e9
	var amax := -1e9
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		for s in 4:
			var p := a.lerp(b, s * 0.25)
			var al := _plano_y(p.x, p.y) - _suelo(p.x, p.y)                  # altura del borde de la losa sobre el suelo
			amin = minf(amin, al)
			amax = maxf(amax, al)
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for p in poly:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	print("roca: ================ RECREACION APROXIMADA de Bunsen Peak, UNA SOLA malla (no es un escaneo) ================")
	print("roca: construida en %d ms: malla %d x %d, %d triangulos, 1 MeshInstance3D + 1 colision" % [Time.get_ticks_msec() - t0, nu, nv, tris])
	print("roca: boca del futuro hueco: x = %.2f, y = %.3f, z = %.2f (terreno %.3f + elevar %.3f%s); el hueco NO se muestra" % [H.x, H.y, H.z, g_ref, elevar, " AUTOMATICO" if auto else ""])
	print("roca: normal de la losa = (%.4f, %.4f, %.4f) = -eje del taladro; inclinacion = %.2f deg" % [e_n.x, e_n.y, e_n.z, rad_to_deg(acos(e_n.y))])
	print("roca: contorno %d puntos, %.2f m de ancho x %.2f m de largo (en el plano; largo estimado)" % [poly.size(), mx.x - mn.x, mx.y - mn.y])
	print("roca: altura del borde de la losa sobre el suelo: minima %.2f m, maxima %.2f m (referencia estimada del lado alto: %.2f m)" % [amin, amax, float(Pr["alto_lado_alto_m"])])
	print("roca: circulo plano alrededor del futuro hueco: radio %.1f cm (diametro %.0f cm), ondulacion maxima %.1f cm; borde enterrado %.0f cm bajo el terreno" % [r_plano * 100.0, r_plano * 200.0, amp * 100.0, ent * 100.0])


# ---- bloqueo de paso (el visor camina siguiendo el terreno, sin fisica) ----
func altura_sobre_suelo(x: float, z: float) -> float:
	var dx := x - H.x
	var dz := z - H.z
	var e_vh := Vector3(e_v.x, 0.0, e_v.z)
	var u := dx * e_u.x + dz * e_u.z
	var v := (dx * e_vh.x + dz * e_vh.z) / maxf(e_vh.length_squared(), 1e-9)
	if _sd(Vector2(u, v)) > 0.03:
		return 0.0
	return _plano_y(u, v) - (world.height_at(x, z) - H.y)


func _bloquear() -> void:
	var o = core.get("origin")
	if o == null:
		return
	var p: Vector3 = o.position
	if absf(p.x - H.x) > 3.0 or absf(p.z - H.z) > 3.0:
		tiene_prev = false
		return
	if altura_sobre_suelo(p.x, p.z) > paso_max:
		if tiene_prev:
			if altura_sobre_suelo(p.x, ok_prev.z) <= paso_max:
				o.position = Vector3(p.x, p.y, ok_prev.z)
			elif altura_sobre_suelo(ok_prev.x, p.z) <= paso_max:
				o.position = Vector3(ok_prev.x, p.y, p.z)
			else:
				o.position = Vector3(ok_prev.x, p.y, ok_prev.z)
	else:
		ok_prev = p
		tiene_prev = true

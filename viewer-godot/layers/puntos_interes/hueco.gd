extends Node3D
# PASO 2: el hueco de la perforacion (muestra 24 "Comet Geyser") colocado en el terreno real del visor.
# Lo crea layer.gd cuando un punto de puntos.json trae el bloque "perforacion". Sin texturas ni roca.
#
# El terreno es un mapa de 1 m por punto: NO se talla. En su lugar:
#  1. se lanza un rayo contra la malla real del terreno y se toma el TRIANGULO que hay bajo el punto (altura y normal exactas);
#  2. el terreno se recorta por shader (terrain.gdshader) dentro de la elipse del hueco y del disco del parche;
#  3. se insertan piezas pequenas alineadas con ese plano: tubo del hueco, parche, anillo de polvo (con borde difuminado).
# PRECISION: el hueco esta a ~7 km del origen del visor, donde un float de 32 bits solo distingue pasos de ~0.5 mm (el radio del
# hueco es de 6.5 mm). Por eso las piezas cuelgan de un nodo colocado en el hueco y los shaders trabajan en coordenadas LOCALES
# (numeros pequenos y exactos), nunca en coordenadas del mundo.
# El eje del taladro (hade/azimuth) es absoluto: respecto a la vertical y al norte, NO a la superficie del suelo.
#
# Teclas (no chocan con las del visor: W A S D, Shift, H, G, Esc):
#   C = inspeccionar el hueco a ~20 cm   V = volver a la camara del visor   Z = corte si/no
#   En inspeccion: Q / E girar, + / - o rueda = acercar / alejar
# Argumentos opcionales (despues de --): --hueco-cerca  --hueco-corte  --hueco-yaw=grados  --hueco-zoom=0.4

const EXTRA := 0.02                    # el cilindro sobresale 2 cm por encima del suelo (se recorta por shader)

var world: WorldStreamer
var core: Node
var P: Dictionary
var xz := Vector2.ZERO
var armado := false
var t_espera := 0.0
var t_unif := 0.0
var R := 0.0
var prof := 0.058
var hv := 0.0
var d_in := Vector3.DOWN
var dh := Vector3.RIGHT
var n_c := Vector3.BACK                # lado que se quita en el corte (horizontal)
var H := Vector3.ZERO                  # punto de entrada del eje sobre el terreno
var n_s := Vector3.UP                  # normal del terreno ahi (triangulo)
var a_s := 0.0
var b_s := 0.0
var rec_a := Vector4.ZERO
var rec_a_m := Vector3.ZERO           # forma del recorte del terreno (radio del hueco + margen)
var forma_r := Vector3.ZERO            # forma de la elipse de entrada exacta (radio del hueco)
var anillo_mat: StandardMaterial3D          # material del anillo de polvo (para ocultarlo en el corte)
var rec_b := Vector4.ZERO
var rec_b_m := Vector3.ZERO
var corte_r := 0.14
var corte_on := false
var inspect := false
var yaw := 0.0
var zoom := 1.0
var dist_cer := 0.20
var cam_i: Camera3D
var cara: MeshInstance3D
var tubo_mat: ShaderMaterial
var hud: Label
var arg_cerca := false
var arg_corte := false
var cont: Node3D
var t_val := 0.0
var roca: Node3D = null                # roca (roca.gd) sobre la que va el hueco; null = hueco en el suelo, como antes
var H0 := Vector3.ZERO                 # boca sobre el terreno (antes de pasar a la roca)


func setup(w: WorldStreamer, c: Node, perf: Dictionary, pos_xz: Vector2, roca_nodo: Node3D = null) -> void:
	world = w
	roca = roca_nodo
	core = c
	P = perf
	xz = pos_xz
	R = float(P["diametro_mm"]) * 0.0005
	prof = float(P["profundidad_mm"]) * 0.001
	dist_cer = float(P["prueba"]["camara_cerca_cm"]) * 0.01
	corte_r = float(P["terreno"]["corte_radio_m"])
	# ---- convencion y conversion SITE -> escena (SUPUESTOS, ver puntos.json) ----
	var hade := float(P["hade_deg"])
	var hade_v := (90.0 - hade) if bool(P.get("hade_desde_horizontal", false)) else hade
	var az := float(P["azimuth_deg"])
	if bool(P.get("azimuth_es_hacia_afuera", false)):
		az += 180.0
	hv = deg_to_rad(hade_v)
	var ar := deg_to_rad(az)
	d_in = Vector3(sin(hv) * sin(ar), -cos(hv), -sin(hv) * cos(ar)).normalized()   # x = E, y = -abajo, z = -N
	dh = Vector3(d_in.x, 0.0, d_in.z)
	dh = dh.normalized() if dh.length() > 1e-6 else Vector3.RIGHT
	n_c = dh.cross(Vector3.UP)
	for a in OS.get_cmdline_user_args():
		if a == "--hueco-cerca":
			arg_cerca = true
		elif a == "--hueco-corte":
			arg_corte = true
		elif a.begins_with("--hueco-yaw="):
			yaw = deg_to_rad(float(a.substr(12)))
		elif a.begins_with("--hueco-zoom="):
			zoom = float(a.substr(13))
	print("hueco: esperando a que cargue el terreno en x=%.1f z=%.1f ..." % [xz.x, xz.y])


func _process(d: float) -> void:
	if not armado:
		t_espera -= d
		if t_espera <= 0.0:
			t_espera = 0.5
			_intentar_armar()
		return
	t_val -= d
	if t_val <= 0.0:
		t_val = 1.5
		_validar()
	t_unif -= d
	if t_unif <= 0.0:
		t_unif = 1.0
		_aplicar_uniformes()
	if inspect:
		_actualizar_camara()
	_poner_hud()


# El terreno se carga y se reemplaza por distancia: si cambia el triangulo bajo el hueco (otra resolucion), se recolocan las piezas.
func _validar() -> void:
	if roca != null:                    # sobre la roca la boca queda fija una vez armada
		return
	var h := _terreno_hit(xz.x, xz.y)
	if h.is_empty() or float(h["area"]) > 1.5:
		return
	if absf(float(h["p"].y) - H.y) > 0.0003 or float(h["n"].dot(n_s)) < 0.99999:
		_intentar_armar()


# ---------------------------------------------------------------- terreno
# Rayo vertical contra la malla del terreno. Devuelve {"p": punto, "n": normal hacia arriba, "area": area del triangulo}
# del triangulo mas pequeno que haya bajo (x, z) (el de mayor resolucion), o {} si el terreno aun no esta cargado.
func _terreno_hit(x: float, z: float) -> Dictionary:
	var mejor := {}
	for c in world.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not (mi.mesh is ArrayMesh):
			continue
		var bb := mi.mesh.get_aabb()
		var off := mi.position
		if x < bb.position.x + off.x or x > bb.end.x + off.x or z < bb.position.z + off.z or z > bb.end.z + off.z:
			continue
		var arr := (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var from := Vector3(x - off.x, 100000.0, z - off.z)
		for t in range(0, ix.size(), 3):
			var a := vs[ix[t]]
			var b := vs[ix[t + 1]]
			var cc := vs[ix[t + 2]]
			if x - off.x < minf(a.x, minf(b.x, cc.x)) or x - off.x > maxf(a.x, maxf(b.x, cc.x)):
				continue
			if z - off.z < minf(a.z, minf(b.z, cc.z)) or z - off.z > maxf(a.z, maxf(b.z, cc.z)):
				continue
			var h = Geometry3D.ray_intersects_triangle(from, Vector3.DOWN, a, b, cc)
			if h != null:
				var nn := (b - a).cross(cc - a)
				var area := nn.length() * 0.5
				if nn.y < 0.0:
					nn = -nn
				if mejor.is_empty() or area < float(mejor["area"]):
					mejor = {"p": (h as Vector3) + off, "n": nn.normalized(), "area": area,
						"tri": [a + off, b + off, cc + off]}
	return mejor


# forma cuadratica del recorte en xz: w = (x-x0, z-z0); la distancia 3D al eje d desde el plano y = a u + b v es sqrt(w^T S w)
func _forma(a: float, b: float, d: Vector3, rr: float) -> Vector3:
	var cu := Vector3(1.0, a, 0.0)
	var cv := Vector3(0.0, b, 1.0)
	var suu := cu.length_squared() - pow(cu.dot(d), 2.0)
	var suv := cu.dot(cv) - cu.dot(d) * cv.dot(d)
	var svv := cv.length_squared() - pow(cv.dot(d), 2.0)
	var k := 1.0 / (rr * rr)
	return Vector3(suu * k, suv * k, svv * k)


func _dist_a_aristas(h: Dictionary) -> float:
	var tri: Array = h["tri"]
	var pxz := Vector2(h["p"].x, h["p"].z)
	var mn := 1e9
	for i in 3:
		var a := Vector2(tri[i].x, tri[i].z)
		var b := Vector2(tri[(i + 1) % 3].x, tri[(i + 1) % 3].z)
		var e := b - a
		var t := clampf((pxz - a).dot(e) / maxf(e.length_squared(), 1e-9), 0.0, 1.0)
		mn = minf(mn, pxz.distance_to(a + e * t))
	return mn


func _intentar_armar() -> void:
	if roca != null and not roca.armada:
		return                          # espera a que la roca este construida
	var h := _terreno_hit(xz.x, xz.y)
	if h.is_empty() or float(h["area"]) > 1.5:     # 1.5 m2: solo la malla de 1 m (la de 5 m aun es la tosca, aun no cargo la fina)
		return
	H = h["p"]
	n_s = h["n"]
	H0 = H
	if roca != null:
		# MODO ROCA: misma posicion horizontal (x, z = lat/lon); solo cambia la altura (la boca de la roca) y el plano (la cara superior de la roca,
		# cuya normal es el eje del taladro).
		H = roca.H
		n_s = -d_in
	a_s = -n_s.x / n_s.y
	b_s = -n_s.z / n_s.y
	var ab: Dictionary = P["abrasion"]
	var pr := float(ab["diametro_mm"]) * 0.0005
	var pd := float(ab["profundidad_mm"]) * 0.001
	var pp: Array = ab["pos_m"]
	var hp := _terreno_hit(xz.x + float(pp[0]), xz.y + float(pp[1]))
	if hp.is_empty() or float(hp["area"]) > 1.5:
		return
	if roca != null:
		hp = h                          # sin parche (Castle Geyser no se modela)
	var Hp: Vector3 = hp["p"]
	var n_p: Vector3 = hp["n"]
	if roca != null:
		n_p = n_s
	var a_p := -n_p.x / n_p.y
	var b_p := -n_p.z / n_p.y
	var primera := not armado
	armado = true
	if cont != null:
		cont.queue_free()
	cont = Node3D.new()
	cont.name = "piezas"
	cont.position = H                       # origen local de todas las piezas: el punto de entrada del eje
	add_child(cont)
	var rel_p := Hp - H                     # centro del parche relativo al hueco (numeros pequenos)
	var tr: Dictionary = P["terreno"]
	var sep := float(tr["separacion_mm"]) * 0.001
	# ---- recortes del terreno (shader) ----
	rec_a = Vector4(H.x, H.z, 0.0 if roca != null else 1.0, 0.0)      # sobre la roca no se recorta el suelo
	forma_r = _forma(a_s, b_s, d_in, R)
	# El recorte del suelo es 1.5 mm mas grande que el hueco: a 7 km del origen cada objeto redondea su posicion por separado
	# (~0.5 mm) y, si coincidieran exactamente, asomarian tiras de suelo dentro de la boca. Ese margen lo tapa el anillo de polvo (opaco cerca de la boca)
	# , que va en la MISMA malla que el tubo (misma posicion, sin desajuste).
	var margen := float(tr["margen_recorte_mm"]) * 0.001
	rec_a_m = _forma(a_s, b_s, d_in, R + margen)
	var parche_visible := bool(ab.get("visible", true)) and roca == null      # "visible": false en puntos.json (o roca) -> sin parche ni recorte del suelo
	rec_b = Vector4(Hp.x, Hp.z, 1.0 if parche_visible else 0.0, 0.0)
	rec_b_m = _forma(a_p, b_p, n_p, pr)
	# ---- tubo del hueco ----
	var sh := load("res://layers/puntos_interes/tubo.gdshader") as Shader
	tubo_mat = ShaderMaterial.new()
	tubo_mat.shader = sh
	tubo_mat.set_shader_parameter("prof_total", prof)
	tubo_mat.set_shader_parameter("color_arriba", _col(tr["color_interior_arriba"]))
	tubo_mat.set_shader_parameter("color_fondo", _col(tr["color_interior_fondo"]))
	var anillo_d := _anillo(sep, float(tr["opaco_mm"]) * 0.001)
	anillo_mat = anillo_d["mat"]
	var pc: Array = P["polvo"]["color"]
	_cilindro(R, prof + EXTRA, d_in * ((prof - EXTRA) * 0.5), d_in, tubo_mat, n_s, Vector3.ZERO, prof, anillo_d, sep)
	var info_pared := _paredes(tubo_mat)
	# ---- parche abrasionado: cilindro corto perpendicular al suelo local ----
	var pm := ShaderMaterial.new()
	pm.shader = sh
	pm.set_shader_parameter("prof_total", pd)
	pm.set_shader_parameter("color_arriba", _col(tr["color_parche_arriba"]))
	pm.set_shader_parameter("color_fondo", _col(tr["color_parche_fondo"]))
	if parche_visible:
		_cilindro(pr, pd + EXTRA, rel_p - n_p * ((pd - EXTRA) * 0.5), -n_p, pm, n_p, rel_p, pd)
	# ---- cara del corte (coordenadas locales: q = q0 + B * vertice, todo relativo al hueco) ----
	var cm := ShaderMaterial.new()
	cm.shader = load("res://layers/puntos_interes/cara.gdshader") as Shader
	cara = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(corte_r * 2.0 * 0.95, 0.22)
	cara.mesh = qm
	cara.material_override = cm
	cara.basis = Basis(dh, Vector3.UP, n_c)
	cara.position = Vector3(0.0, -0.06, 0.0)
	cm.set_shader_parameter("q0", cara.position)
	cm.set_shader_parameter("bx", cara.basis.x)
	cm.set_shader_parameter("by", cara.basis.y)
	cm.set_shader_parameter("bz", cara.basis.z)
	cm.set_shader_parameter("plano_n", n_s)
	cm.set_shader_parameter("eje", d_in)
	cm.set_shader_parameter("radio", R)
	cm.set_shader_parameter("prof_total", prof)
	cm.set_shader_parameter("color", _col(tr["color_corte"]))
	cara.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cara.visible = false
	cont.add_child(cara)
	# ---- camara de inspeccion y texto (una sola vez) ----
	if primera:
		cam_i = Camera3D.new()
		cam_i.near = 0.002                  # 2 mm: no recorta nada de 13 mm a 20 cm
		cam_i.far = 3000.0
		cam_i.fov = 55.0
		add_child(cam_i)
		var cl := CanvasLayer.new()
		add_child(cl)
		hud = Label.new()
		hud.add_theme_font_size_override("font_size", 14)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.55)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		hud.add_theme_stylebox_override("normal", sb)
		cl.add_child(hud)
		_imprimir(h, hp, sep)
		print(info_pared)
		if roca != null:
			_informe_roca()
	else:
		print("hueco: el terreno fino cambio; piezas recolocadas sobre el triangulo actual")
	_aplicar_uniformes()
	if corte_on:
		_set_corte(true)
	if primera and arg_corte:
		_set_corte(true)
	if primera and arg_cerca:
		_set_inspeccion(true)


# PASO 3: texturiza SOLO las paredes interiores del hueco (la geometria y el fondo no cambian).
# APROXIMACION: usa la superficie de la roca antes de perforar (WATSON sol 1088); no hay imagen del interior real.
# Devuelve el texto que se imprime al cargar.
func _paredes(mat: ShaderMaterial) -> String:
	var pw: Dictionary = P.get("paredes", {})
	if pw.is_empty():
		return "hueco: paredes sin textura (no hay bloque 'paredes' en puntos.json)"
	var ruta := ProjectSettings.globalize_path("res://layers/puntos_interes/" + String(pw["imagen"]))
	var img := Image.load_from_file(ruta)
	if img == null:
		push_error("hueco: no pude cargar la textura de las paredes: " + ruta)
		return "hueco: ERROR al cargar la textura de las paredes"
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var um := float(pw["um_por_px"]) * 1.0e-6
	var tw := float(img.get_width()) * um
	var th := float(img.get_height()) * um
	var circ := TAU * R
	var nu := maxi(2, 2 * int(round(circ / (2.0 * tw))))      # numero PAR de anchos de textura en la vuelta: sin costura
	mat.set_shader_parameter("usa_pared", true)
	mat.set_shader_parameter("tex_pared", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("radio_pared", R)
	mat.set_shader_parameter("tex_w", tw)
	mat.set_shader_parameter("tex_h", th)
	mat.set_shader_parameter("tex_px", um)
	mat.set_shader_parameter("n_u", float(nu))
	mat.set_shader_parameter("brillo", float(pw["brillo"]))
	mat.set_shader_parameter("saturacion", float(pw["saturacion"]))
	mat.set_shader_parameter("degradado", float(pw["degradado"]))
	mat.set_shader_parameter("relieve", float(pw["relieve"]))
	var esc_real := circ / (float(nu) * tw)                    # 1.0 = escala fisica exacta
	return ("hueco: PAREDES texturizadas (SUPUESTO: aproximacion, no hay imagen del interior real; se usa la superficie de la roca ANTES de perforar, WATSON sol 1088)
"
		+ "hueco:   textura %dx%d px = %.1f x %.1f mm a %.0f um/px (medido con la barra de 5 mm = 41 px; el original es de 31.7 um/px, este archivo esta reducido ~3.85x: NO hay detalle por debajo de ~0.12 mm)
" % [img.get_width(), img.get_height(), tw * 1000.0, th * 1000.0, um * 1.0e6]
		+ "hueco:   circunferencia = %.1f mm = %d anchos de textura en espejo (sin costura); factor de escala respecto a la fisica = %.3f; profundidad = %.1f anchos de alto
" % [circ * 1000.0, nu, esc_real, prof / th]
		+ "hueco:   brillo %.2f | saturacion %.2f | degradado %.2f | relieve %.2f | mate (sin especular)" % [float(pw["brillo"]), float(pw["saturacion"]), float(pw["degradado"]), float(pw["relieve"])])


func _col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


func _aplicar_uniformes() -> void:
	var rc := Vector4(H.x, H.z, n_c.x, n_c.z)
	for t in world.tiles.values():
		var m = t["mat"]
		if m == null:
			continue
		var sm := m as ShaderMaterial
		sm.set_shader_parameter("rec_a", rec_a)
		sm.set_shader_parameter("rec_a_m", rec_a_m)
		sm.set_shader_parameter("rec_b", rec_b)
		sm.set_shader_parameter("rec_b_m", rec_b_m)
		sm.set_shader_parameter("rec_c", rc)
		sm.set_shader_parameter("rec_c_r", 0.0 if roca != null else (corte_r if corte_on else 0.0))
	if roca != null:
		roca.poner_corte(corte_r if corte_on else 0.0, Vector2(n_c.x, n_c.z))


# Cilindro (tubo del hueco o parche). Todo en coordenadas relativas al hueco. El shader trabaja en el espacio LOCAL de la malla
# (el eje del cilindro es +Y local, hacia dentro del suelo), y aqui se le pasan, ya calculados, el plano del suelo y el plano del
# corte expresados en ese espacio local: dot(v, plano_n_loc) + plano_c > clip_eps => por encima del suelo.
#   centro: centro del cilindro; eje: hacia dentro; plano_n / plano_pt: normal y un punto del suelo; depth: profundidad.
# Si se pasa 'anillo' ({"arr", "mat"}), el anillo de polvo se mete como segunda superficie de ESTA MISMA malla: asi el tubo y el
# anillo comparten posicion y no se desalinean entre si (a 7 km del origen cada objeto redondea su posicion por separado, ~0.5 mm).
func _cilindro(rad: float, alto: float, centro: Vector3, eje: Vector3, mat: ShaderMaterial, plano_n: Vector3, plano_pt: Vector3, depth: float,
		anillo := {}, clip_eps := 0.0002) -> void:
	var B := Basis(Quaternion(Vector3.UP, eje))
	var Bi := B.inverse()
	mat.set_shader_parameter("plano_n_loc", Bi * plano_n)
	mat.set_shader_parameter("plano_c", (centro - plano_pt).dot(plano_n))
	mat.set_shader_parameter("corte_n_loc", Bi * n_c)
	mat.set_shader_parameter("corte_c", centro.dot(n_c))              # el corte pasa por el eje del hueco (origen local)
	mat.set_shader_parameter("ref_loc", Bi * n_c)                      # origen del angulo para el mapeo de las paredes
	mat.set_shader_parameter("s_c", (depth - EXTRA) * 0.5)             # profundidad (sobre el eje) del centro del cilindro
	mat.set_shader_parameter("clip_eps", clip_eps)
	var cm := CylinderMesh.new()
	cm.top_radius = rad
	cm.bottom_radius = rad
	cm.height = alto
	cm.radial_segments = 64
	cm.rings = 1
	cm.cap_top = true                       # +Y del cilindro apunta hacia dentro del suelo: ahi va el fondo
	cm.cap_bottom = false
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cm.get_mesh_arrays())
	am.surface_set_material(0, mat)
	if not anillo.is_empty():
		var arr: Array = anillo["arr"]
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for k in vs.size():
			vs[k] = Bi * (vs[k] - centro)                       # de relativo-al-hueco a espacio local de esta malla
			ns[k] = Bi * ns[k]
		arr[Mesh.ARRAY_VERTEX] = vs
		arr[Mesh.ARRAY_NORMAL] = ns
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		am.surface_set_material(1, anillo["mat"])
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.basis = B
	mi.position = centro
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cont.add_child(mi)


# Anillo de polvo claro (relativo al hueco, sobre el plano del suelo). Borde interior = la elipse de entrada. Es OPACO los primeros
# 'opaco' metros (ahi queda oculto el borde del recorte del suelo, que es algo mayor que el hueco) y despues se difumina (alfa -> 0)
# hasta un borde irregular, para fundirse con el terreno. Color plano (SUPUESTO). Devuelve {"arr", "mat"}.
func _anillo(sep: float, opaco: float) -> Dictionary:
	var pv: Dictionary = P["polvo"]
	var ro_base := float(pv["radio_externo_mm"]) * 0.001
	var irr := float(pv["irregularidad"])
	var n2 := FastNoiseLite.new()
	n2.seed = int(pv["semilla"])
	n2.frequency = 1.0
	# La pared se corta a 'sep' sobre el plano del suelo. Como el eje esta inclinado respecto a la normal, ahi la boca queda
	# desplazada: es el punto en que el eje cruza ese plano. El anillo se centra ahi para que su borde interior coincida con la pared.
	var pm := d_in * (sep / d_in.dot(n_s))
	var pm_off := Vector2(pm.x, pm.z)
	var N := 128
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in N:
		var ph := TAU * float(i) / float(N)
		var c := cos(ph)
		var s := sin(ph)
		var e := Vector2(c, s)
		var q := forma_r
		var rin := 1.0 / sqrt(q.x * c * c + 2.0 * q.y * c * s + q.z * s * s)    # radio de la elipse en esa direccion (en xz)
		var rop := rin * (R + opaco) / R                                        # fin de la zona opaca
		var ro := maxf(ro_base * (1.0 + irr * n2.get_noise_2dv(e * 2.0)), rop * 1.6)
		# difuminado suave hacia fuera (opaco y claro junto a la boca; alfa y tono bajan poco a poco hasta fundirse con el suelo)
		var rs := [rin, rop, rop + (ro - rop) * 0.25, rop + (ro - rop) * 0.5, rop + (ro - rop) * 0.75, ro]
		var al := [1.0, 1.0, 0.85, 0.6, 0.3, 0.0]
		var tono := [1.0, 1.0, 0.97, 0.93, 0.9, 0.88]
		for k in 6:
			var r: float = rs[k]
			var u: float = pm_off.x + c * r
			var v: float = pm_off.y + s * r
			verts.append(Vector3(u, a_s * u + b_s * v + sep / n_s.y, v))
			norms.append(n_s)
			cols.append(Color(tono[k], tono[k], tono[k], al[k]))
	for i in N:
		var j := (i + 1) % N
		for k in 5:
			var p0 := 6 * i + k
			var p1 := 6 * i + k + 1
			var p2 := 6 * j + k
			var p3 := 6 * j + k + 1
			idx.append(p0)
			idx.append(p1)
			idx.append(p2)
			idx.append(p1)
			idx.append(p3)
			idx.append(p2)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var m := StandardMaterial3D.new()
	var pc: Array = pv["color"]
	m.albedo_color = Color(float(pc[0]), float(pc[1]), float(pc[2]))
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return {"arr": arr, "mat": m}


# ---------------------------------------------------------------- teclas, corte y camara
func _set_corte(on: bool) -> void:
	corte_on = on
	tubo_mat.set_shader_parameter("corte_on", on)
	cara.visible = on
	var cc := anillo_mat.albedo_color
	anillo_mat.albedo_color = Color(cc.r, cc.g, cc.b, 0.0 if on else 1.0)   # el anillo se oculta en el corte
	_aplicar_uniformes()


func _set_inspeccion(on: bool) -> void:
	inspect = on
	if on:
		cam_i.make_current()
		_actualizar_camara()
	else:
		var cc = core.get("cam")
		if cc != null:
			(cc as Camera3D).make_current()


func _unhandled_input(e: InputEvent) -> void:
	if not armado:
		return
	if e is InputEventKey and e.pressed:
		match e.keycode:
			KEY_C: _set_inspeccion(true)
			KEY_V: _set_inspeccion(false)
			KEY_Z: _set_corte(not corte_on)
			KEY_Q:
				if inspect:
					yaw -= 0.3
			KEY_E:
				if inspect:
					yaw += 0.3
			KEY_EQUAL, KEY_KP_ADD:
				if inspect:
					zoom = maxf(zoom * 0.8, 0.1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				if inspect:
					zoom = minf(zoom * 1.25, 5.0)
	elif inspect and e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = maxf(zoom * 0.85, 0.1)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = minf(zoom * 1.15, 5.0)


func _actualizar_camara() -> void:
	var dist := dist_cer * zoom
	var elev := deg_to_rad(20.0) if corte_on else deg_to_rad(40.0)
	var base := n_c if corte_on else Vector3.BACK
	var hdir := base.rotated(Vector3.UP, yaw)
	var target := H + (d_in * prof * 0.5 if corte_on else Vector3.ZERO)
	cam_i.global_position = target + hdir * dist * cos(elev) + Vector3.UP * dist * sin(elev)
	cam_i.look_at(target, Vector3.UP)


func _poner_hud() -> void:
	if hud == null:
		return
	if inspect:
		hud.text = "Hueco de la muestra 24 (13 mm). Reconstruccion aproximada; paredes con textura APROXIMADA (WATSON sol 1088).   V volver | Z corte | Q/E girar | +/- zoom"
	else:
		hud.text = "Hueco de la muestra 24: C inspeccionar | Z corte"
	hud.position = Vector2(10.0, get_viewport().get_visible_rect().size.y - hud.size.y - 10.0)


# PASO 2: posicion del hueco antes (sobre el terreno) y despues (sobre la roca), y diametro medido en su malla.
func _informe_roca() -> void:
	var ll0 := world.world_to_lonlat(H0.x, H0.z)
	var ll1 := world.world_to_lonlat(H.x, H.z)
	print("hueco: ======== PASO 2: el hueco pasa a la roca ========")
	print("hueco: ANTES  (sobre el terreno): x = %.3f, y = %.3f, z = %.3f | lon = %.7f, lat = %.7f" % [H0.x, H0.y, H0.z, ll0.x, ll0.y])
	print("hueco: DESPUES (sobre la roca)  : x = %.3f, y = %.3f, z = %.3f | lon = %.7f, lat = %.7f" % [H.x, H.y, H.z, ll1.x, ll1.y])
	print("hueco: cambio: dx = %.4f m, dz = %.4f m (lat/lon iguales), dy = %+.3f m (solo la altura)" % [H.x - H0.x, H.z - H0.z, H.y - H0.y])
	var rmax := 0.0
	for ch in cont.get_children():
		var mi := ch as MeshInstance3D
		if mi != null and mi.mesh is ArrayMesh and mi.mesh.get_surface_count() > 0:
			var vsa: PackedVector3Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var rr := 0.0
			for v in vsa:
				rr = maxf(rr, Vector2(v.x, v.z).length())
			if rr > 0.004 and rr < 0.01:
				rmax = rr
				break
	print("hueco: diametro medido en la malla del tubo = %.2f mm (debe ser 13.00); profundidad = %.1f mm; eje = (%.4f, %.4f, %.4f) = -normal de la cara superior" % [rmax * 2000.0, prof * 1000.0, d_in.x, d_in.y, d_in.z])
	print("hueco: instancias de hueco en la escena: %d (nodo '%s')" % [get_parent().find_children("hueco_muestra", "", false, false).size(), name])
	roca.verificar()


func _imprimir(h: Dictionary, hp: Dictionary, sep: float) -> void:
	var th := rad_to_deg(acos(clampf(n_s.y, -1.0, 1.0)))
	var cos_t := absf(d_in.dot(n_s))
	var q := forma_r
	var tr := (q.x + q.z) * 0.5
	var dd := sqrt(pow((q.x - q.z) * 0.5, 2.0) + q.y * q.y)
	var sa := 1.0 / sqrt(tr - dd)          # semieje mayor en proyeccion xz (m)
	var sb := 1.0 / sqrt(tr + dd)          # semieje menor en proyeccion xz (m)
	var datum := float(world.W["datum_m"])
	var elev: float = float(P["elevacion_m"])
	print("hueco: ================ PASO 2: hueco en el terreno real ================")
	print("hueco: posicion en el mundo: x = %.2f, z = %.2f (origen = primer punto de la ruta; x este, z sur)" % [H.x, H.z])
	print("hueco: altura del terreno bajo el hueco = %.3f m (visor)  |  esperada por tu dato de elevacion = %.3f m (%.3f - datum %.3f)  |  diferencia = %.3f m" % [H.y, elev - datum, elev, datum, H.y - (elev - datum)])
	print("hueco: triangulo del terreno bajo el hueco: normal = (%.4f, %.4f, %.4f), pendiente = %.2f deg; borde mas cercano a %.2f m" % [n_s.x, n_s.y, n_s.z, th, _dist_a_aristas(h)])
	print("hueco: triangulo bajo el parche: pendiente = %.2f deg; borde mas cercano a %.2f m" % [rad_to_deg(acos(clampf(hp["n"].y, -1.0, 1.0))), _dist_a_aristas(hp)])
	print("hueco: eje del taladro hacia dentro (x este, y arriba, z sur) = (%.4f, %.4f, %.4f)  [absoluto: vertical + norte, NO sigue la pendiente]" % [d_in.x, d_in.y, d_in.z])
	print("hueco: angulo entre el eje del taladro y la VERTICAL = %.2f deg; entre el eje y la NORMAL del suelo = %.2f deg" % [rad_to_deg(hv), rad_to_deg(acos(clampf(cos_t, 0.0, 1.0)))])
	print("hueco: entrada sobre el suelo inclinado: semieje menor = %.2f mm, semieje mayor = %.2f mm (en el plano del suelo); proyectada en xz: %.2f x %.2f mm" % [R * 1000.0, R / cos_t * 1000.0, sb * 1000.0, sa * 1000.0])
	print("hueco: profundidad a lo largo del eje = %.1f mm; vertical = %.1f mm; desplazamiento horizontal del fondo = %.1f mm" % [prof * 1000.0, prof * cos(hv) * 1000.0, prof * sin(hv) * 1000.0])
	print("hueco: parche: diametro = %.1f mm, profundidad = %.1f mm (SUPUESTO), centro a %s m del hueco (este, sur)%s" % [float(P["abrasion"]["diametro_mm"]), float(P["abrasion"]["profundidad_mm"]), str(P["abrasion"]["pos_m"]), "" if bool(P["abrasion"].get("visible", true)) else "  [OCULTO: visible=false]"])
	print("hueco: separacion de las piezas sobre el plano = %.1f mm (anti z-fighting). Colores planos = SUPUESTO." % (sep * 1000.0))

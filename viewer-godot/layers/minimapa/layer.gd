extends Node3D
# Capa MINIMAPA: ruta de Perseverance en gris claro y el rover como un punto que se mueve sobre ella.
# Usa los vertices reales de la ruta (en el tramo van cada ~0.8 m), sin remuestrear.
#   - Pequeno: esquina inferior derecha, tramo de ~1.2 km alrededor del rover. Clic o tecla M lo agranda.
#   - Grande, con dos pestanas (clic o teclas 1 y 2):
#       1 · Ruta Completa                     2 · Ruta Ingenuity (solo la ruta del sol 1063 al 1116)
#     En ambas: rueda = zoom (hacia el cursor), arrastrar = mover, doble clic o R = encuadrar,
#     puntos blancos = fin de cada conduccion con su sol (pasa el cursor sobre uno para ver "Sol N").
#   - En VR: panel pegado a la mano izquierda (core.left), siempre pequeno.
# API usada: world.route_pos/route_s_of_sol/route_length/route_nearest_s/lonlat_to_world, los arreglos publicos
# world.route_xz / route_s / route_sol; core.origin, core.ride_s, core.riding, core.in_xr.

# Tramos especificos por sol (cada uno es una pestana despues de "Toda la ruta"). sol_ini y sol_fin inclusivos.
const TRAMOS := [
	{"nombre": "Ruta Ingenuity", "sol0": 1063, "sol1": 1116},
]

# Ingenuity: posicion del vuelo 72 (18 ene 2024, Airfield Chi, Valinor Hills). Fuente: lista de vuelos de Wikipedia
# (List of Ingenuity flights) y la guia del equipo (docs/EQUIPO.md); queda ~364 m al norte de la ruta, a la altura del sol 1114.
# Marcas sobre el mapa (pin con punta en la posicion). "tipo": "helicoptero" o "muestra".
const MARCAS := [
	{"tipo": "helicoptero", "texto": "Ingenuity", "lon": 77.322539, "lat": 18.497263},
	# Muestra 24: lat 18.49186664 N, lon 77.3272192 E, elevacion -2382.434036 m (dato dado por el equipo).
	{"tipo": "muestra", "texto": "Muestra 24", "lon": 77.3272192, "lat": 18.49186664},
]

const TAM_CHICO := 256
const TAM_GRANDE := 720
const TRAMO_M := 1200.0                # metros de ruta que muestra el minimapa pequeno
const SOLAPE_M := 150.0
const MARGEN := 18.0
const ALTO_PESTANAS := 34.0
# Pulido de la pestana de tramo (la linea original trae temblor de <1 m, puntos repetidos y saltos de ~7 m):
const PUL_DMIN := 0.30                 # m: se descartan vertices a menos de esto del anterior
const PUL_ANG := 150.0                 # grados: vuelta casi en U ...
const PUL_LMAX := 1.2                  # m: ... con una pata corta = "punta" de ruido, se quita
const PUL_CHAIKIN := 3                 # pasadas de suavizado (no se mueven los extremos de cada conduccion)
const ESC_MAX := 40.0                  # px por metro maximo (a 0.8 m entre vertices = ~32 px)

const C_FONDO := Color(0.05, 0.05, 0.06, 0.74)
const C_BORDE := Color(1, 1, 1, 0.35)
const C_RUTA := Color(0.86, 0.86, 0.88)        # gris claro
const C_RUTA_HECHA := Color(0.55, 0.55, 0.58)  # ya recorrido
const C_PUNTO := Color(1.0, 0.35, 0.12)
const C_MARCA := Color(0.45, 0.85, 1.0)

var world: WorldStreamer
var core: Node
var vp: SubViewport
var lienzo: Control
var panel: TextureRect

var grande := false
var modo := 0                          # 0 = toda la ruta, 1+ = TRAMOS[modo - 1]
var _tam := TAM_CHICO

# Mapa pequeno.
var _tramo := -1
var _pts := PackedVector2Array()
var _s_pts := PackedFloat32Array()
var _min := Vector2.ZERO
var _escala := 1.0

# Mapa grande: por pestana se guarda el rango de vertices, los fines de conduccion y la vista (centro, px/m).
var _rango: Array = []                 # [Vector2i(i0, i1)] por pestana
var _src_pts: Array = []               # por pestana: vertices originales del rango
var _src_s: Array = []
var _pul_pts: Array = []               # por pestana de tramo: linea pulida (vacia en la de toda la ruta)
var _pul_s: Array = []
var _pulido := true                    # P alterna pulida / original
var _fines: Array = []                 # por pestana: Array de [Vector2 mundo, int sol]
var _centro: Array = []                # Vector2 (mundo) en el centro de la vista
var _esc: Array = []                   # px por metro
var _esc_fit: Array = []               # px por metro que encuadra todo
var _vista_ok := false                 # false = hay que rehacer los puntos en pantalla
var _k_px := PackedVector2Array()      # vertices ya en pantalla (se descartan los casi iguales)
var _k_s := PackedFloat32Array()
var _k_tam := 0
var _k_modo := -1

var _tabs: Array = []                  # Rect2 de cada pestana
var _rc_cerrar := Rect2()
var _arrastre := false
var _mouse := Vector2(-100, -100)
var _pos := Vector2.ZERO
var _s_actual := 0.0
var _t_busca := 0.0
var _zoom_prueba := 0.0                # solo pruebas (--minimapa-zoom=N)
var _cuadros := 0


func setup(w: WorldStreamer, c: Node) -> void:
	world = w
	core = c

	vp = SubViewport.new()
	vp.size = Vector2i(_tam, _tam)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	lienzo = Control.new()
	lienzo.size = Vector2(_tam, _tam)
	lienzo.draw.connect(_dibujar)
	vp.add_child(lienzo)

	_preparar_pestanas()
	if core.in_xr:
		_montar_en_mano()
	else:
		_montar_en_pantalla()
	_actualizar(true)
	var args := OS.get_cmdline_user_args()
	if "--minimapa=ruta" in args or "--minimapa=grande" in args:
		alternar()
	elif "--minimapa=tramo" in args:
		alternar()
		modo = 1
	# Para pruebas: --minimapa-zoom=6 acerca la vista (x veces el encuadre), centrada en el rover.
	for a in args:
		if a.begins_with("--minimapa-zoom="):
			_zoom_prueba = float(a.get_slice("=", 1))


# ---------------------------------------------------------------- datos por pestana

func _preparar_pestanas() -> void:
	var n := world.route_sol.size()
	for m in 1 + TRAMOS.size():
		var i0 := 0
		var i1 := n - 1
		if m >= 1:
			var t: Dictionary = TRAMOS[m - 1]
			i0 = n
			i1 = 0
			for i in n:
				var so := int(world.route_sol[i])
				if so >= int(t["sol0"]) and so <= int(t["sol1"]):
					i0 = mini(i0, i)
					i1 = maxi(i1, i)
			if i0 > i1:
				i0 = 0
				i1 = n - 1
		_rango.append(Vector2i(i0, i1))
		var rp := PackedVector2Array()
		var rs := PackedFloat32Array()
		for i in range(i0, i1 + 1):
			rp.append(world.route_xz[i])
			rs.append(world.route_s[i])
		_src_pts.append(rp)
		_src_s.append(rs)
		if m >= 1:
			var pl := _pulir_tramo(i0, i1)
			_pul_pts.append(pl[0])
			_pul_s.append(pl[1])
		else:
			_pul_pts.append(PackedVector2Array())
			_pul_s.append(PackedFloat32Array())
		var fin: Array = []
		for i in range(i0, i1 + 1):
			if i == i1 or world.route_sol[i + 1] != world.route_sol[i]:
				fin.append([world.route_xz[i], int(world.route_sol[i])])
		_fines.append(fin)
		_centro.append(Vector2.ZERO)
		_esc.append(1.0)
		_esc_fit.append(1.0)


func _encuadrar(m: int) -> void:
	var fp: PackedVector2Array = _src_pts[m]
	var mn: Vector2 = fp[0]
	var mx := mn
	for v in fp:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	for mk in MARCAS:
		var q := world.lonlat_to_world(float(mk["lon"]), float(mk["lat"]))
		mn = Vector2(minf(mn.x, q.x), minf(mn.y, q.y))
		mx = Vector2(maxf(mx.x, q.x), maxf(mx.y, q.y))
	var ext := Vector2(maxf(mx.x - mn.x, 1.0), maxf(mx.y - mn.y, 1.0))
	var util := _util()
	_esc_fit[m] = minf(util.size.x / ext.x, util.size.y / ext.y)
	_esc[m] = _esc_fit[m]
	_centro[m] = (mn + mx) * 0.5
	_vista_ok = false


func _util() -> Rect2:
	# Arriba queda sitio para el pin de Ingenuity y su texto; abajo, para la escala y las coordenadas.
	var pad := MARGEN + 14.0
	var top := ALTO_PESTANAS + 72.0
	var bajo := 76.0
	return Rect2(pad, top, _tam - 2.0 * pad, _tam - top - bajo)


func _mundo_a_px(v: Vector2) -> Vector2:
	return (v - _centro[modo]) * _esc[modo] + _util().get_center()


func _px_a_mundo(p: Vector2) -> Vector2:
	return (p - _util().get_center()) / _esc[modo] + _centro[modo]


# Rehace los vertices en pantalla; descarta los que quedan a menos de ~0.7 px del anterior.
func _rehacer_vista() -> void:
	var fp: PackedVector2Array = _fuente_pts(modo)
	var fs: PackedFloat32Array = _fuente_s(modo)
	_k_px = PackedVector2Array()
	_k_s = PackedFloat32Array()
	var ult := Vector2(-1e9, -1e9)
	var n := fp.size()
	for i in n:
		var p := _mundo_a_px(fp[i])
		if i == 0 or i == n - 1 or p.distance_squared_to(ult) >= 0.5:
			_k_px.append(p)
			_k_s.append(fs[i])
			ult = p
	_k_modo = modo
	_k_tam = _tam
	_vista_ok = true


# ---------------------------------------------------------------- pulido de la linea del tramo

func _fuente_pts(m: int) -> PackedVector2Array:
	return _pul_pts[m] if (m >= 1 and _pulido) else _src_pts[m]


func _fuente_s(m: int) -> PackedFloat32Array:
	return _pul_s[m] if (m >= 1 and _pulido) else _src_s[m]


# Posicion sobre la linea que se esta dibujando (pulida u original) a s metros de ruta.
func _fuente_pos(m: int, s: float) -> Vector2:
	var fp: PackedVector2Array = _fuente_pts(m)
	var fs: PackedFloat32Array = _fuente_s(m)
	if fp.size() < 2:
		return fp[0]
	var i := clampi(fs.bsearch(s), 1, fp.size() - 1)
	var a := fs[i - 1]
	var b := fs[i]
	return fp[i - 1].lerp(fp[i], 0.0 if b <= a else clampf((s - a) / (b - a), 0.0, 1.0))


func _vuelta(a: Vector2, b: Vector2, c: Vector2) -> float:
	var v1 := b - a
	var v2 := c - b
	if v1.length_squared() < 1e-10 or v2.length_squared() < 1e-10:
		return 0.0
	return absf(rad_to_deg(v1.angle_to(v2)))


# Pule cada conduccion por separado (vertices i0..i1 de la ruta): sus extremos no se mueven, asi los fines de
# conduccion y el metraje siguen siendo los reales. No altera world.route_*; solo cambia lo que se dibuja.
func _pulir_tramo(i0: int, i1: int) -> Array:
	var out_p := PackedVector2Array()
	var out_s := PackedFloat32Array()
	var g0 := i0
	for i in range(i0, i1 + 1):
		if i == i1 or world.route_sol[i + 1] != world.route_sol[i]:
			var r := _pulir_una(g0, i)
			var p: PackedVector2Array = r[0]
			var ss: PackedFloat32Array = r[1]
			for k in p.size():
				if k == 0 and not out_p.is_empty() and out_p[out_p.size() - 1].distance_to(p[0]) < 0.01:
					continue
				out_p.append(p[k])
				out_s.append(ss[k])
			g0 = i + 1
	return [out_p, out_s]


func _pulir_una(a: int, b: int) -> Array:
	var q: Array = [Vector3(world.route_xz[a].x, world.route_xz[a].y, world.route_s[a])]
	if b > a:
		# 1) fuera vertices repetidos o casi (< PUL_DMIN).
		for i in range(a + 1, b):
			var v: Vector2 = world.route_xz[i]
			if v.distance_to(Vector2(q[-1].x, q[-1].y)) >= PUL_DMIN:
				q.append(Vector3(v.x, v.y, world.route_s[i]))
		var fin := Vector3(world.route_xz[b].x, world.route_xz[b].y, world.route_s[b])
		if q.size() > 1 and Vector2(fin.x, fin.y).distance_to(Vector2(q[-1].x, q[-1].y)) < PUL_DMIN:
			q[-1] = fin
		else:
			q.append(fin)
		# 2) fuera las "puntas" de ruido: vuelta casi en U con una pata corta.
		for _pasada in 8:
			var cambio := false
			var j := 1
			while j < q.size() - 1:
				var pa := Vector2(q[j - 1].x, q[j - 1].y)
				var pb := Vector2(q[j].x, q[j].y)
				var pc := Vector2(q[j + 1].x, q[j + 1].y)
				if _vuelta(pa, pb, pc) > PUL_ANG and minf(pa.distance_to(pb), pb.distance_to(pc)) < PUL_LMAX:
					q.remove_at(j)
					cambio = true
				else:
					j += 1
			if not cambio:
				break
		# 3) suavizado de esquinas (Chaikin) con los extremos fijos.
		for _it in PUL_CHAIKIN:
			if q.size() < 3:
				break
			var o: Array = [q[0]]
			for j in q.size() - 1:
				if j > 0:
					o.append(q[j] * 0.75 + q[j + 1] * 0.25)
				if j < q.size() - 2:
					o.append(q[j] * 0.25 + q[j + 1] * 0.75)
			o.append(q[q.size() - 1])
			q = o
	var rp := PackedVector2Array()
	var rs := PackedFloat32Array()
	for v in q:
		rp.append(Vector2(v.x, v.y))
		rs.append(v.z)
	return [rp, rs]


# ---------------------------------------------------------------- montaje

func _montar_en_pantalla() -> void:
	var cl := CanvasLayer.new()
	panel = TextureRect.new()
	panel.texture = vp.get_texture()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.gui_input.connect(_entrada_panel)
	cl.add_child(panel)
	add_child(cl)
	_colocar_panel()


func _colocar_panel() -> void:
	if panel == null:
		return
	panel.custom_minimum_size = Vector2(_tam, _tam)
	panel.size = Vector2(_tam, _tam)
	if grande:
		panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		panel.offset_left = -_tam * 0.5
		panel.offset_right = _tam * 0.5
		panel.offset_top = -_tam * 0.5
		panel.offset_bottom = _tam * 0.5
	else:
		panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		panel.offset_left = -_tam - 16
		panel.offset_top = -_tam - 16
		panel.offset_right = -16
		panel.offset_bottom = -16


func _montar_en_mano() -> void:
	var q := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	q.mesh = quad
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = vp.get_texture()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material_override = m
	q.position = Vector3(0, 0.07, -0.05)
	q.rotation_degrees = Vector3(-60, 0, 0)
	core.left.add_child(q)


func alternar() -> void:
	if core.in_xr:
		return
	grande = not grande
	# El grande ocupa hasta el 85 % del alto de la ventana (nunca mas de TAM_GRANDE).
	_tam = int(minf(TAM_GRANDE, get_viewport().get_visible_rect().size.y * 0.85)) if grande else TAM_CHICO
	vp.size = Vector2i(_tam, _tam)
	lienzo.size = Vector2(_tam, _tam)
	_colocar_panel()
	if grande:
		for m in _rango.size():
			_encuadrar(m)
	_arrastre = false
	lienzo.queue_redraw()


func _nombre_modo(i: int) -> String:
	return "Ruta Completa" if i == 0 else str(TRAMOS[i - 1]["nombre"])


# ---------------------------------------------------------------- entrada

func _entrada_panel(e: InputEvent) -> void:
	if not grande:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			alternar()
		return
	if e is InputEventMouseMotion:
		_mouse = e.position
		if _arrastre:
			_centro[modo] -= e.relative / _esc[modo]
			_vista_ok = false
	elif e is InputEventMouseButton:
		_mouse = e.position
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				if _rc_cerrar.has_point(e.position):
					alternar()
					return
				for i in _tabs.size():
					if (_tabs[i] as Rect2).has_point(e.position):
						modo = i
						_vista_ok = false
						return
				if e.double_click:
					_encuadrar(modo)
				else:
					_arrastre = true
			else:
				_arrastre = false
		elif e.pressed and (e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_zoom(e.position, 1.25 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.25)


# Zoom hacia el cursor: el punto del mapa bajo el cursor no se mueve.
func _zoom(p: Vector2, f: float) -> void:
	var antes := _px_a_mundo(p)
	_esc[modo] = clampf(_esc[modo] * f, _esc_fit[modo] * 0.8, ESC_MAX)
	_centro[modo] = antes - (p - _util().get_center()) / _esc[modo]
	_vista_ok = false


func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.keycode == KEY_M:
		alternar()
	elif grande and e.keycode == KEY_R:
		_encuadrar(modo)
	elif grande and modo >= 1 and e.keycode == KEY_P:
		_pulido = not _pulido
		_vista_ok = false
	elif grande and e.keycode >= KEY_1 and e.keycode < KEY_1 + 1 + TRAMOS.size():
		modo = e.keycode - KEY_1
		_vista_ok = false


func _process(delta: float) -> void:
	if world == null or not world.is_ready():
		return
	_t_busca += delta
	_actualizar(false)
	_cuadros += 1
	if _zoom_prueba > 0.0 and grande and _cuadros == 5:   # el rover ya esta en su sitio
		_esc[modo] = _esc_fit[modo] * _zoom_prueba
		_centro[modo] = world.route_pos(_s_actual)
		_vista_ok = false


func _actualizar(forzar: bool) -> void:
	var p3: Vector3 = core.origin.global_position
	_pos = Vector2(p3.x, p3.z)
	if core.riding:
		_s_actual = core.ride_s
	elif forzar or _t_busca > 0.25:
		_s_actual = world.route_nearest_s(_pos)   # es O(n): no cada cuadro
		_t_busca = 0.0
	var tramo := int(floor(_s_actual / TRAMO_M))
	if tramo != _tramo:
		_construir_tramo(tramo)
	lienzo.queue_redraw()


# Vertices reales de la ruta entre s0 y s1 (m), con los extremos interpolados. Devuelve [puntos, s de cada punto].
func _poli(s0: float, s1: float) -> Array:
	var pts := PackedVector2Array()
	var ss := PackedFloat32Array()
	pts.append(world.route_pos(s0))
	ss.append(s0)
	var n := world.route_s.size()
	var i := world.route_s.bsearch(s0, false)
	while i < n and world.route_s[i] < s1:
		if world.route_s[i] > s0:
			pts.append(world.route_xz[i])
			ss.append(world.route_s[i])
		i += 1
	pts.append(world.route_pos(s1))
	ss.append(s1)
	return [pts, ss]


func _construir_tramo(tramo: int) -> void:
	_tramo = tramo
	var largo := world.route_length()
	var r := _poli(maxf(0.0, tramo * TRAMO_M - SOLAPE_M), minf(largo, (tramo + 1) * TRAMO_M + SOLAPE_M))
	_pts = r[0]
	_s_pts = r[1]
	var mn := _pts[0]
	var mx := _pts[0]
	for v in _pts:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	var ext := maxf(maxf(mx.x - mn.x, mx.y - mn.y), 1.0)
	_escala = (TAM_CHICO - 2.0 * MARGEN) / ext
	_min = (mn + mx) * 0.5 - Vector2(TAM_CHICO, TAM_CHICO) * 0.5 / _escala


# ---------------------------------------------------------------- dibujo

func _dibujar() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(_tam, _tam))
	lienzo.draw_rect(r, C_FONDO)
	if grande:
		_dibujar_grande()
	else:
		_dibujar_chico()
	lienzo.draw_rect(r, C_BORDE, false, 2.0)


func _dibujar_chico() -> void:
	if _pts.size() >= 2:
		var px := PackedVector2Array()
		for v in _pts:
			px.append((v - _min) * _escala)
		_trazar(px, _s_pts, 3.0)
		_punto(((_pos - _min) * _escala).clamp(Vector2(4, 4), Vector2(_tam - 4, _tam - 4)), 5.0)
	lienzo.draw_string(ThemeDB.fallback_font, Vector2(6, _tam - 8), _fmt_lonlat(_pos), HORIZONTAL_ALIGNMENT_LEFT, _tam - 12, 12, Color(1, 1, 1, 0.8))


# Lo recorrido (mas oscuro) hasta el rover y lo que falta (gris claro). ss = metraje de cada punto.
func _trazar(px: PackedVector2Array, ss: PackedFloat32Array, ancho: float) -> void:
	var k := clampi(ss.bsearch(_s_actual), 0, px.size() - 1)
	if k >= 1:
		lienzo.draw_polyline(px.slice(0, k + 1), C_RUTA_HECHA, ancho, true)
	if px.size() - k >= 2:
		lienzo.draw_polyline(px.slice(maxi(k - 1, 0)), C_RUTA, ancho, true)


func _dibujar_grande() -> void:
	if not _vista_ok or _k_modo != modo or _k_tam != _tam:
		_rehacer_vista()
	var f := ThemeDB.fallback_font
	var esc: float = _esc[modo]
	var util := _util()
	_trazar(_k_px, _k_s, 2.5)

	# Fines de conduccion: punto blanco y, si no se amontona, el numero de sol.
	var vis := Rect2(Vector2.ZERO, Vector2(_tam, _tam)).grow(-4)
	var sep := 46.0
	var ultimo := Vector2(-1000, -1000)
	var cerca_p := Vector2.ZERO
	var cerca_sol := -1
	var cerca_d := 14.0
	for e in _fines[modo]:
		var p := _mundo_a_px(e[0])
		if p.y < ALTO_PESTANAS or not vis.has_point(p):
			continue
		var d := p.distance_to(_mouse)
		if d < cerca_d:
			cerca_d = d
			cerca_p = p
			cerca_sol = e[1]
		if esc > 0.12 or modo >= 1:
			lienzo.draw_circle(p, 3.2, Color(0, 0, 0, 0.55))
			lienzo.draw_circle(p, 2.4, Color(1, 1, 1, 0.95))
		if p.distance_to(ultimo) >= sep:
			lienzo.draw_string(f, p + Vector2(6, -6), "%d" % e[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
			ultimo = p

	# Marcas (Ingenuity, muestra 24...), en las dos pestanas, si caen dentro de la vista.
	for mk in MARCAS:
		var pm := _mundo_a_px(world.lonlat_to_world(float(mk["lon"]), float(mk["lat"])))
		if Rect2(Vector2.ZERO, Vector2(_tam, _tam)).grow(-6).has_point(pm) and pm.y > ALTO_PESTANAS + 34.0:
			_pin(pm, str(mk["tipo"]))
			var col := Color(0.75, 0.9, 1.0) if mk["tipo"] == "helicoptero" else Color(0.8, 1.0, 0.8)
			lienzo.draw_string(f, pm + Vector2(14, -22), str(mk["texto"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, col)

	# El rover, si esta dentro del rango de esta pestana.
	var fs: PackedFloat32Array = _fuente_s(modo)
	if _s_actual >= fs[0] and _s_actual <= fs[fs.size() - 1]:
		_punto(_mundo_a_px(_fuente_pos(modo, _s_actual)), 7.0)

	# Etiqueta al pasar el cursor sobre un fin de conduccion.
	if cerca_sol >= 0:
		var txt := "Sol: %d" % cerca_sol
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 14.0
		var rc := Rect2(cerca_p + Vector2(10, -28), Vector2(w, 22))
		lienzo.draw_rect(rc, Color(0, 0, 0, 0.78))
		lienzo.draw_string(f, rc.position + Vector2(7, 16), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1))

	_dibujar_pestanas()
	# Escala, zoom y ayuda.
	var barra_m := _escala_redonda((_tam * 0.2) / esc)
	lienzo.draw_line(Vector2(16, _tam - 20), Vector2(16 + barra_m * esc, _tam - 20), Color(1, 1, 1, 0.9), 3.0)
	lienzo.draw_string(f, Vector2(16, _tam - 28), _fmt_m(barra_m), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.9))
	_dibujar_ayuda(f)
	var info := "%.1f km de ruta" % (world.route_length() / 1000.0) if modo == 0 else "sols %d–%d" % [TRAMOS[modo - 1]["sol0"], TRAMOS[modo - 1]["sol1"]]
	lienzo.draw_string(f, Vector2(_tam - 220, _tam - 28), info, HORIZONTAL_ALIGNMENT_RIGHT, 204, 15, Color(1, 1, 1, 0.8))
	# Longitud y latitud: del cursor si esta sobre el mapa, si no del rover.
	var c_txt := ("Cursor  " + _fmt_lonlat(_px_a_mundo(_mouse))) if util.has_point(_mouse) else ("Rover  " + _fmt_lonlat(_pos))
	lienzo.draw_string(f, Vector2(_tam - 400, _tam - 8), c_txt, HORIZONTAL_ALIGNMENT_RIGHT, 388, 14, Color(1, 1, 1, 0.9))
	lienzo.draw_string(f, Vector2(_tam - 220, _tam - 48), "zoom ×%.1f" % (esc / _esc_fit[modo]), HORIZONTAL_ALIGNMENT_RIGHT, 204, 14, Color(1, 1, 1, 0.6))


# Los controles, en un cuadrito arriba a la derecha.
func _dibujar_ayuda(f: Font) -> void:
	var lineas: Array = ["Rueda: zoom", "Arrastrar: mover", "Doble clic: encuadrar"]
	var ancho := 0.0
	for l in lineas:
		ancho = maxf(ancho, f.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	var rc := Rect2(_tam - ancho - 28.0, ALTO_PESTANAS + 6.0, ancho + 18.0, lineas.size() * 17.0 + 10.0)
	lienzo.draw_rect(rc, Color(0, 0, 0, 0.5))
	lienzo.draw_rect(rc, Color(1, 1, 1, 0.3), false, 1.2)
	for i in lineas.size():
		lienzo.draw_string(f, rc.position + Vector2(9, 18 + i * 17.0), lineas[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.85))


func _dibujar_pestanas() -> void:
	_tabs.clear()
	var f := ThemeDB.fallback_font
	var x := 6.0
	for i in 1 + TRAMOS.size():
		var txt := "%d · %s" % [i + 1, _nombre_modo(i)]
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 18.0
		var rc := Rect2(x, 5, w, ALTO_PESTANAS - 8)
		_tabs.append(rc)
		var act := i == modo
		lienzo.draw_rect(rc, Color(1, 1, 1, 0.28) if act else Color(1, 1, 1, 0.08))
		lienzo.draw_rect(rc, Color(1, 1, 1, 0.7 if act else 0.25), false, 1.5)
		lienzo.draw_string(f, Vector2(x + 9, 5 + 17), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 1.0 if act else 0.7))
		x += w + 6.0
	# Boton cerrar.
	_rc_cerrar = Rect2(_tam - 30, 5, 24, ALTO_PESTANAS - 8)
	lienzo.draw_rect(_rc_cerrar, Color(1, 1, 1, 0.08))
	lienzo.draw_rect(_rc_cerrar, Color(1, 1, 1, 0.25), false, 1.5)
	lienzo.draw_string(f, Vector2(_tam - 30, 5 + 17), "✕", HORIZONTAL_ALIGNMENT_CENTER, 24, 15, Color(1, 1, 1, 0.8))


# "Lon 77.31970°E  Lat 18.48983°N" para una posicion del mundo (x, z).
func _fmt_lonlat(p: Vector2) -> String:
	var ll := world.world_to_lonlat(p.x, p.y)
	return "Lon %.5f°%s  Lat %.5f°%s" % [absf(ll.x), "E" if ll.x >= 0.0 else "W", absf(ll.y), "N" if ll.y >= 0.0 else "S"]


func _fmt_m(m: float) -> String:
	return "%.0f km" % (m / 1000.0) if m >= 1000.0 else ("%.1f m" % m if m < 1.0 else "%d m" % int(m))


func _escala_redonda(m: float) -> float:
	var p := pow(10.0, floor(log(m) / log(10.0)))
	for k in [1.0, 2.0, 5.0, 10.0]:
		if k * p >= m * 0.7:
			return k * p
	return p


# Pin con borde amarillo (como el de NASA); la punta senala la posicion exacta. Azul + helicoptero, o verde + muestra.
func _pin(tip: Vector2, tipo: String) -> void:
	var fondo := C_MARCA if tipo == "helicoptero" else Color(0.35, 0.8, 0.4)
	var c := tip + Vector2(0, -20)
	lienzo.draw_colored_polygon(PackedVector2Array([tip, c + Vector2(-9, 4), c + Vector2(9, 4)]), Color(1.0, 0.9, 0.1))
	lienzo.draw_circle(c, 13.0, Color(1.0, 0.9, 0.1))
	lienzo.draw_colored_polygon(PackedVector2Array([tip + Vector2(0, -2), c + Vector2(-7.5, 5), c + Vector2(7.5, 5)]), fondo)
	lienzo.draw_circle(c, 11.0, fondo)
	var b := Color(1, 1, 1)
	if tipo == "helicoptero":
		lienzo.draw_line(c + Vector2(-8, -6), c + Vector2(8, -6), b, 1.6)      # rotor
		lienzo.draw_line(c + Vector2(0, -6), c + Vector2(0, -3), b, 1.6)       # mastil
		lienzo.draw_circle(c + Vector2(0, -0.5), 3.2, b)                       # cuerpo
		lienzo.draw_line(c + Vector2(3, -0.5), c + Vector2(8, -2), b, 1.4)     # cola
		lienzo.draw_line(c + Vector2(-5, 5), c + Vector2(5, 5), b, 1.4)        # patines
	else:
		# Tubo de muestra: cuerpo con tapa.
		lienzo.draw_rect(Rect2(c + Vector2(-3, -7), Vector2(6, 13)), b)
		lienzo.draw_rect(Rect2(c + Vector2(-4.5, -8.5), Vector2(9, 3)), Color(0.2, 0.45, 0.25))


func _punto(p: Vector2, r: float) -> void:
	lienzo.draw_circle(p, r + 2.0, Color(0, 0, 0, 0.8))
	lienzo.draw_circle(p, r, C_PUNTO)

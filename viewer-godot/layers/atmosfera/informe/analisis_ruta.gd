extends RefCounted
# Analisis del tramo A -> B para el informe (no se usa durante la simulacion normal).
# Se activa con:  godot --path viewer-godot --xr-mode off -- --world=../world --sol=1063 --layers=atmosfera --atm-analisis
# Usa las mismas funciones que el panel de la capa (layer.gd _valores / modelo.gd), asi que los numeros coinciden.
# Escribe CSV en informe/datos/ y un resumen en informe/datos/resumen.txt:
#   punto_a.csv     valores del panel en el punto A (ejemplos trabajados del informe)
#   ruta_real.csv   perfil de la ruta real de Perseverance (polilinea), cada 10 m
#   ruta_recta.csv  perfil de la recta A -> B (secante)
#   ruta_optima.csv perfil de la ruta de menor costo (A* en grilla de 10 m, sin pendientes > 15 grados)
#   caminos.csv     x, z de los tres caminos (para el mapa)

const PASO := 10.0                # m entre muestras y celdas de la grilla
const MARGEN := 150.0             # m alrededor de la caja del tramo
const PEND_MAX := 15.0            # grados (mismo umbral HAZARD_DEG de la capa de peligro H del nucleo)
const VEL_CAMINAR := 1.0          # m/s (para la dosis de una caminata)
# Pesos de la funcion de costo c(x) = 1 + W_RAD r + W_O2 o + W_POLVO p + W_PEND (pendiente / 15)^2
const W_RAD := 1.0
const W_O2 := 1.0
const W_POLVO := 1.0
const W_PEND := 1.0

var capa                          # el nodo de la capa (layer.gd)
var w                             # WorldStreamer
var m                             # modelo.gd
var sol_fijo := 0.0
var dir := ""
var resumen := PackedStringArray()


func ejecutar(c) -> void:
	capa = c
	w = c.world
	m = c.m
	dir = ProjectSettings.globalize_path("res://layers/atmosfera/informe/datos")
	DirAccess.make_dir_recursive_absolute(dir)
	sol_fijo = 0.5 * (c.TRAMO_SOL_A + c.TRAMO_SOL_B)
	resumen.append("Analisis tramo sol %d -> %d (sol de referencia para comparar caminos: %.1f), hora local %.2f" % [c.TRAMO_SOL_A, c.TRAMO_SOL_B, sol_fijo, c.hora])

	var sa: float = w.route_s_of_sol(c.TRAMO_SOL_A)
	var sb: float = w.route_s_of_sol(c.TRAMO_SOL_B + 1)
	var a: Vector2 = w.route_pos(sa)
	var b: Vector2 = w.route_pos(sb)
	_punto_a(a, c.TRAMO_SOL_A)

	# 1) ruta real: polilinea de Perseverance (cada segmento es la recta tangente/secante local)
	var real := PackedVector2Array()
	var s := sa
	while s < sb:
		real.append(w.route_pos(s))
		s += PASO
	real.append(b)
	# 2) recta A -> B
	var recta := PackedVector2Array()
	var n := maxi(int(a.distance_to(b) / PASO), 1)
	for i in n + 1:
		recta.append(a.lerp(b, float(i) / n))
	# 3) ruta optima
	var optima := _ruta_optima(a, b, real)

	var caminos := {"ruta_real": real, "ruta_recta": recta, "ruta_optima": optima}
	var f := FileAccess.open(dir + "/caminos.csv", FileAccess.WRITE)
	f.store_line("camino,x,z")
	for k in caminos:
		for p in caminos[k]:
			f.store_line("%s,%.2f,%.2f" % [k, p.x, p.y])
	f.close()
	for k in caminos:
		_perfil(k, caminos[k])
	var r := FileAccess.open(dir + "/resumen.txt", FileAccess.WRITE)
	r.store_string("\n".join(resumen) + "\n")
	r.close()
	print("\n".join(resumen))
	print("atmosfera: analisis escrito en ", dir)


# Valores del panel en A, con los pasos intermedios del modelo.
func _punto_a(a: Vector2, sol: float) -> void:
	capa.sol_actual = sol
	capa._valores(Vector3(a.x, 0.0, a.y))
	var v: Dictionary = capa.v
	var ls: float = m.ls_de_sol(sol)
	var f := FileAccess.open(dir + "/punto_a.csv", FileAccess.WRITE)
	f.store_line("variable,valor")
	var filas := {
		"sol": sol, "ls_grados": ls, "hora_local": capa.hora, "x": a.x, "z": a.y, "h_m": v["h"],
		"presion_estacion_pa": m.presion_estacion(sol), "presion_pa": v["presion"],
		"fraccion_o2": v["fo2"], "po2_pa": v["po2"], "rad_msv_dia": v["rad"],
		"tau": v["tau"], "tau_fondo": v["tau_fondo"], "luz_bloqueada": m.luz_bloqueada(v["tau"]),
		"temp_k": v["temp"], "temp_base_k": m.temp_base(sol, capa.hora, v["tau_fondo"]),
		"forma_diaria": m.forma_diaria(capa.hora), "factor_dia": m.factor_dia(capa.hora),
		"pendiente_grados": w.slope_deg(a.x, a.y),
	}
	for k in filas:
		f.store_line("%s,%.6f" % [k, float(filas[k])])
	f.close()


# Costo de una celda (sin dimension, >= 1). Normaliza cada parametro a 0..1 con las escalas de la capa.
func _costo(x: float, z: float) -> Dictionary:
	capa.sol_actual = sol_fijo
	capa._valores(Vector3(x, 0.0, z))
	var v: Dictionary = capa.v
	var pend: float = w.slope_deg(x, z)
	var r: float = m.t_rad(v["rad"])
	var o: float = m.t_o2_falta(v["po2"])
	var p: float = m.t_polvo(v["tau"])
	var c := 1.0 + W_RAD * r + W_O2 * o + W_POLVO * p + W_PEND * pow(pend / PEND_MAX, 2.0)
	return {"c": c, "pend": pend, "v": v}


# A* en una grilla de PASO m que cubre el tramo (+ MARGEN). Celdas con pendiente > PEND_MAX: prohibidas.
# AStarGrid2D: costo de pasar a una celda = distancia x peso de esa celda; heuristica euclidiana (admisible: pesos >= 1).
func _ruta_optima(a: Vector2, b: Vector2, real: PackedVector2Array) -> PackedVector2Array:
	var caja := Rect2(a, Vector2.ZERO).expand(b)
	for p in real:
		caja = caja.expand(p)
	caja = caja.grow(MARGEN)
	var g := AStarGrid2D.new()
	g.region = Rect2i(0, 0, int(caja.size.x / PASO) + 1, int(caja.size.y / PASO) + 1)
	g.cell_size = Vector2(PASO, PASO)
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	g.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	g.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	g.update()
	var prohibidas := 0
	for j in g.region.size.y:
		for i in g.region.size.x:
			var x: float = caja.position.x + i * PASO
			var z: float = caja.position.y + j * PASO
			var k := _costo(x, z)
			g.set_point_weight_scale(Vector2i(i, j), k["c"])
			if k["pend"] > PEND_MAX:
				g.set_point_solid(Vector2i(i, j), true)
				prohibidas += 1
	var ia := Vector2i(roundi((a.x - caja.position.x) / PASO), roundi((a.y - caja.position.y) / PASO))
	var ib := Vector2i(roundi((b.x - caja.position.x) / PASO), roundi((b.y - caja.position.y) / PASO))
	g.set_point_solid(ia, false)
	g.set_point_solid(ib, false)
	var celdas := g.get_id_path(ia, ib)
	resumen.append("Grilla A*: %d x %d celdas de %.0f m, %d prohibidas por pendiente > %.0f grados" % [g.region.size.x, g.region.size.y, PASO, prohibidas, PEND_MAX])
	var out := PackedVector2Array()
	for cel in celdas:
		out.append(caja.position + Vector2(cel) * PASO)
	return out


# Perfil a lo largo de un camino + indicadores. J = suma de (largo del segmento x costo al final del segmento).
func _perfil(nombre: String, camino: PackedVector2Array) -> void:
	var f := FileAccess.open(dir + "/" + nombre + ".csv", FileAccess.WRITE)
	f.store_line("s_m,x,z,h_m,pendiente_grados,presion_pa,temp_c,rad_msv_dia,o2_pct,po2_pa,tau,costo")
	var s := 0.0
	var j := 0.0
	var rad_int := 0.0                   # integral de la dosis a lo largo del camino: (mSv/dia) * m
	var pend_max := 0.0
	var po2_min := INF
	var h0 := 0.0
	var h_min := INF
	var h_max := -INF
	for i in camino.size():
		var p := camino[i]
		var ds := 0.0 if i == 0 else camino[i - 1].distance_to(p)
		s += ds
		var k := _costo(p.x, p.y)
		var v: Dictionary = k["v"]
		j += ds * k["c"]
		rad_int += ds * float(v["rad"])
		pend_max = maxf(pend_max, k["pend"])
		po2_min = minf(po2_min, v["po2"])
		h_min = minf(h_min, v["h"])
		h_max = maxf(h_max, v["h"])
		if i == 0:
			h0 = v["h"]
		f.store_line("%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.3f,%.4f" % [s, p.x, p.y, v["h"], k["pend"], v["presion"],
			float(v["temp"]) - 273.15, v["rad"], float(v["fo2"]) * 100.0, v["po2"], v["tau"], k["c"]])
	f.close()
	var t_s := s / VEL_CAMINAR
	var dosis := (rad_int / s) * t_s / 86400.0 if s > 0.0 else 0.0     # mSv: dosis media (mSv/dia terrestre) x dias de caminata
	resumen.append("%s: largo %.0f m, J = %.0f (J/largo = %.3f), dosis caminando a %.1f m/s = %.5f mSv, pO2 min %.3f Pa, pendiente max %.1f grados, desnivel %.1f m" % [
		nombre, s, j, j / maxf(s, 1.0), VEL_CAMINAR, dosis, po2_min, pend_max, h_max - h_min])

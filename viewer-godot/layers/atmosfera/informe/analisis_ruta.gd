extends RefCounted
# Analisis del tramo A -> B para el informe (no se usa durante la simulacion normal).
# Se activa con:  godot --path viewer-godot --xr-mode off -- --world=../world --sol=1063 --layers=atmosfera --atm-analisis
# Usa las mismas funciones que el panel de la capa (layer.gd _valores / modelo.gd), asi que los numeros coinciden.
# Escribe en informe/datos/:
#   punto_a.csv       valores del panel en el punto A con los pasos intermedios (ejemplos trabajados)
#   derivadas.csv     pendiente por diferencias centrales con distintos pasos (convergencia, error O(D^2))
#   incertidumbre.csv propagacion de errores de primer orden vs Monte Carlo (presion, pO2, dosis)
#   ruta_real.csv / ruta_recta.csv / ruta_optima.csv   perfiles cada 10 m
#   caminos.csv       x, z de los caminos (mapa)
#   pareto.csv        A* con distintos pesos de exposicion: largo vs exposicion integrada
#   resumen.txt       resumen legible

const PASO := 10.0                # m entre muestras y celdas de la grilla
const MARGEN := 150.0             # m alrededor de la caja del tramo
const PEND_MAX := 15.0            # grados (mismo umbral HAZARD_DEG de la capa de peligro H del nucleo)
const VEL_CAMINAR := 1.0          # m/s (para la dosis de una caminata)
const W_PEND := 1.0               # peso de la pendiente en el costo
const LAMBDA_BASE := 3.0          # peso de la exposicion de la ruta "optima" (equivale a 1 por cada uno de los 3 terminos)
const LAMBDAS := [0.0, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 50.0, 100.0]
const N_MC := 20000               # muestras de Monte Carlo
const LIMITES_PEND := [6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 15.0, 18.0, 20.0, 25.0, 90.0]

var capa                          # el nodo de la capa (layer.gd)
var w                             # WorldStreamer
var m                             # modelo.gd
var sol_fijo := 0.0
var dir := ""
var resumen := PackedStringArray()
# grilla de A* (se calcula una vez; los pesos se cambian sin recalcular el modelo)
var caja := Rect2()
var gw := 0
var gh := 0
var expo := PackedFloat32Array()  # exposicion normalizada por celda: (rad + falta de O2 + polvo) / 3, en 0..1
var pend := PackedFloat32Array()  # grados


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
	_derivadas(a)

	var real := PackedVector2Array()
	var s := sa
	while s < sb:
		real.append(w.route_pos(s))
		s += PASO
	real.append(b)
	var recta := PackedVector2Array()
	var n := maxi(int(a.distance_to(b) / PASO), 1)
	for i in n + 1:
		recta.append(a.lerp(b, float(i) / n))

	_preparar_grilla(a, b, real)
	var optima := _astar(a, b, LAMBDA_BASE)
	_pareto(a, b)
	_barrido_pendiente(a, b)

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


# ---------------------------------------------------------------- punto A

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
	_incertidumbre(sol, float(v["h"]))


# ---------------------------------------------------------------- derivadas: convergencia de las diferencias centrales

# Pendiente en A y en el punto mas empinado cerca de A con pasos 0.5..32 m. En terreno suave, la diferencia entre pasos
# consecutivos baja ~4 veces al dividir el paso a la mitad (error O(D^2)); con pasos muy chicos domina el ruido del DTM.
func _derivadas(a: Vector2) -> void:
	var pts := {"A": a}
	var mejor := 0.0
	for j in range(-10, 11):
		for i in range(-10, 11):
			var p := a + Vector2(i, j) * 10.0
			var sl: float = w.slope_deg(p.x, p.y)
			if sl > mejor:
				mejor = sl
				pts["empinado"] = p
	var f := FileAccess.open(dir + "/derivadas.csv", FileAccess.WRITE)
	f.store_line("punto,paso_m,hx,hz,pendiente_grados")
	for k in pts:
		var p: Vector2 = pts[k]
		for d in [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0]:
			var hx: float = (w.height_at(p.x + d, p.y) - w.height_at(p.x - d, p.y)) / (2.0 * d)
			var hz: float = (w.height_at(p.x, p.y + d) - w.height_at(p.x, p.y - d)) / (2.0 * d)
			f.store_line("%s,%.1f,%.5f,%.5f,%.3f" % [k, d, hx, hz, rad_to_deg(atan(sqrt(hx * hx + hz * hz)))])
	f.close()


# ---------------------------------------------------------------- incertidumbre

# Entradas con incertidumbre (1 sigma):
#   p0   presion de la estacion: +-15 Pa  (SUPUESTO: diferencia tipica del ajuste de 2 armonicos vs la curva de MEDA)
#   H    altura de escala: +-5 %           (T del aire entre ~200 y ~230 K -> H entre 10.3 y 11.9 km)
#   f    fraccion de O2: +-10 %             (SUPUESTO; SAM midio variaciones estacionales de hasta 30 %)
#   D0   dosis base de RAD: +-19 %          (incertidumbre relativa de la dosis absorbida, 0.210 +- 0.040 mGy/dia)
#   k    coeficiente de blindaje por presion: 0.3 +- 0.1 (ilustrativo)
func _incertidumbre(sol: float, h: float) -> void:
	var p0m: float = m.presion_estacion(sol)
	var sp0 := 15.0
	var Hm := 11100.0
	var sH := 0.05 * Hm
	var fm := 0.0016
	var sf := 0.1 * fm
	var Dm := 0.67
	var sD := 0.19 * Dm
	var km := 0.3
	var sk := 0.1
	# primer orden (derivadas parciales)
	var p := p0m * exp(-h / Hm)
	var dp_dp0 := exp(-h / Hm)
	var dp_dH := p * h / (Hm * Hm)
	var sp := sqrt(pow(dp_dp0 * sp0, 2) + pow(dp_dH * sH, 2))
	var po2 := fm * p
	var spo2 := po2 * sqrt(pow(sf / fm, 2) + pow(sp / p, 2))
	var g := 1.0 - km * (p - 820.0) / 820.0
	var D := Dm * g
	var dD_dD0 := g
	var dD_dk := -Dm * (p - 820.0) / 820.0
	var dD_dp := -Dm * km / 820.0
	var sDt := sqrt(pow(dD_dD0 * sD, 2) + pow(dD_dk * sk, 2) + pow(dD_dp * sp, 2))
	# Monte Carlo
	var rng := RandomNumberGenerator.new()
	rng.seed = 1063
	var ps := PackedFloat32Array()
	var o2s := PackedFloat32Array()
	var ds := PackedFloat32Array()
	for i in N_MC:
		var pi_ := rng.randfn(p0m, sp0) * exp(-h / rng.randfn(Hm, sH))
		var fi := rng.randfn(fm, sf)
		var ki := rng.randfn(km, sk)
		ps.append(pi_)
		o2s.append(fi * pi_)
		ds.append(rng.randfn(Dm, sD) * (1.0 - ki * (pi_ - 820.0) / 820.0))
	var f := FileAccess.open(dir + "/incertidumbre.csv", FileAccess.WRITE)
	f.store_line("magnitud,valor,sigma_1er_orden,media_mc,sigma_mc,unidad")
	f.store_line("presion,%.3f,%.3f,%.3f,%.3f,Pa" % [p, sp, _media(ps), _desv(ps)])
	f.store_line("po2,%.5f,%.5f,%.5f,%.5f,Pa" % [po2, spo2, _media(o2s), _desv(o2s)])
	f.store_line("dosis,%.5f,%.5f,%.5f,%.5f,mSv/dia" % [D, sDt, _media(ds), _desv(ds)])
	f.store_line("aporte_p0_a_presion,%.4f,,,,Pa" % [dp_dp0 * sp0])
	f.store_line("aporte_H_a_presion,%.4f,,,,Pa" % [dp_dH * sH])
	f.close()
	resumen.append("Incertidumbre en A: p = %.1f +- %.1f Pa (MC %.1f +- %.1f); aporte de H solo %.3f Pa. Dosis = %.3f +- %.3f mSv/dia (MC %.3f +- %.3f)" % [
		p, sp, _media(ps), _desv(ps), dp_dH * sH, D, sDt, _media(ds), _desv(ds)])


func _media(a: PackedFloat32Array) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()


func _desv(a: PackedFloat32Array) -> float:
	var mu := _media(a)
	var s := 0.0
	for x in a:
		s += (x - mu) * (x - mu)
	return sqrt(s / (a.size() - 1))


# ---------------------------------------------------------------- costo y A*

# Componentes normalizadas a 0..1 con las escalas de la capa (las mismas de las vistas y la neblina).
func _componentes(x: float, z: float) -> Dictionary:
	capa.sol_actual = sol_fijo
	capa._valores(Vector3(x, 0.0, z))
	var v: Dictionary = capa.v
	var r: float = m.t_rad(v["rad"])
	var o: float = m.t_o2_falta(v["po2"])
	var p: float = m.t_polvo(v["tau"])
	return {"e": (r + o + p) / 3.0, "pend": w.slope_deg(x, z), "v": v}


# c(x) = 1 + lambda e(x) + W_PEND (pendiente/15)^2 ; pendiente > 15 grados prohibida.
func _costo_celda(e: float, pe: float, lam: float) -> float:
	return 1.0 + lam * e + W_PEND * pow(pe / PEND_MAX, 2.0)


func _preparar_grilla(a: Vector2, b: Vector2, real: PackedVector2Array) -> void:
	caja = Rect2(a, Vector2.ZERO).expand(b)
	for p in real:
		caja = caja.expand(p)
	caja = caja.grow(MARGEN)
	gw = int(caja.size.x / PASO) + 1
	gh = int(caja.size.y / PASO) + 1
	expo.resize(gw * gh)
	pend.resize(gw * gh)
	var prohibidas := 0
	for j in gh:
		for i in gw:
			var k := _componentes(caja.position.x + i * PASO, caja.position.y + j * PASO)
			expo[j * gw + i] = k["e"]
			pend[j * gw + i] = k["pend"]
			if k["pend"] > PEND_MAX:
				prohibidas += 1
	resumen.append("Grilla A*: %d x %d celdas de %.0f m, %d prohibidas por pendiente > %.0f grados" % [gw, gh, PASO, prohibidas, PEND_MAX])


# A* (AStarGrid2D): pasar a una celda cuesta distancia x peso de la celda; heuristica euclidiana (admisible: peso >= 1).
func _astar(a: Vector2, b: Vector2, lam: float, lim: float = PEND_MAX) -> PackedVector2Array:
	var g := AStarGrid2D.new()
	g.region = Rect2i(0, 0, gw, gh)
	g.cell_size = Vector2(PASO, PASO)
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	g.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	g.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	g.update()
	for j in gh:
		for i in gw:
			var k := j * gw + i
			g.set_point_weight_scale(Vector2i(i, j), _costo_celda(expo[k], pend[k], lam))
			if pend[k] > lim:
				g.set_point_solid(Vector2i(i, j), true)
	var ia := Vector2i(roundi((a.x - caja.position.x) / PASO), roundi((a.y - caja.position.y) / PASO))
	var ib := Vector2i(roundi((b.x - caja.position.x) / PASO), roundi((b.y - caja.position.y) / PASO))
	g.set_point_solid(ia, false)
	g.set_point_solid(ib, false)
	var out := PackedVector2Array()
	for cel in g.get_id_path(ia, ib):
		out.append(caja.position + Vector2(cel) * PASO)
	return out


# Frente de Pareto: para cada lambda, el camino optimo y sus dos objetivos (largo L y exposicion E = integral de e ds).
func _pareto(a: Vector2, b: Vector2) -> void:
	var f := FileAccess.open(dir + "/pareto.csv", FileAccess.WRITE)
	f.store_line("lambda,largo_m,exposicion_m,exposicion_media,pendiente_max,dosis_msv")
	for lam in LAMBDAS:
		var cam := _astar(a, b, lam)
		var ind := _indicadores(cam)
		f.store_line("%.1f,%.1f,%.2f,%.4f,%.2f,%.6f" % [lam, ind["L"], ind["E"], ind["E"] / maxf(ind["L"], 1.0), ind["pmax"], ind["dosis"]])
		resumen.append("Pareto lambda=%5.1f: L=%.0f m, E=%.1f m (media %.3f), pend max %.1f, dosis %.5f mSv" % [lam, ind["L"], ind["E"], ind["E"] / maxf(ind["L"], 1.0), ind["pmax"], ind["dosis"]])
	f.close()


# Compromiso largo vs pendiente maxima permitida: A* con lambda base y distintos limites de pendiente.
func _barrido_pendiente(a: Vector2, b: Vector2) -> void:
	var f := FileAccess.open(dir + "/barrido_pendiente.csv", FileAccess.WRITE)
	f.store_line("limite_grados,hay_camino,largo_m,pendiente_max,exposicion_media")
	for lim in LIMITES_PEND:
		var cam := _astar(a, b, LAMBDA_BASE, lim)
		if cam.size() < 2:
			f.store_line("%.0f,0,,," % lim)
			resumen.append("Limite %4.0f grados: sin camino" % lim)
			continue
		var ind := _indicadores(cam)
		f.store_line("%.0f,1,%.1f,%.2f,%.4f" % [lim, ind["L"], ind["pmax"], ind["E"] / maxf(ind["L"], 1.0)])
		resumen.append("Limite %4.0f grados: L=%.0f m, pend max %.1f" % [lim, ind["L"], ind["pmax"]])
	f.close()


func _indicadores(cam: PackedVector2Array) -> Dictionary:
	var L := 0.0
	var E := 0.0
	var rad_int := 0.0
	var pmax := 0.0
	for i in cam.size():
		var k := _componentes(cam[i].x, cam[i].y)
		pmax = maxf(pmax, k["pend"])
		if i > 0:
			var ds := cam[i - 1].distance_to(cam[i])
			L += ds
			E += ds * k["e"]
			rad_int += ds * float(k["v"]["rad"])
	var dosis := (rad_int / L) * (L / VEL_CAMINAR) / 86400.0 if L > 0.0 else 0.0
	return {"L": L, "E": E, "pmax": pmax, "dosis": dosis}


# ---------------------------------------------------------------- perfiles

func _perfil(nombre: String, camino: PackedVector2Array) -> void:
	var f := FileAccess.open(dir + "/" + nombre + ".csv", FileAccess.WRITE)
	f.store_line("s_m,x,z,h_m,pendiente_grados,presion_pa,temp_c,rad_msv_dia,o2_pct,po2_pa,tau,exposicion,costo")
	var s := 0.0
	var j := 0.0
	var h_min := INF
	var h_max := -INF
	for i in camino.size():
		var p := camino[i]
		var ds := 0.0 if i == 0 else camino[i - 1].distance_to(p)
		s += ds
		var k := _componentes(p.x, p.y)
		var v: Dictionary = k["v"]
		var c := _costo_celda(k["e"], k["pend"], LAMBDA_BASE)
		j += ds * c
		h_min = minf(h_min, v["h"])
		h_max = maxf(h_max, v["h"])
		f.store_line("%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.3f,%.4f,%.4f" % [s, p.x, p.y, v["h"], k["pend"], v["presion"],
			float(v["temp"]) - 273.15, v["rad"], float(v["fo2"]) * 100.0, v["po2"], v["tau"], k["e"], c])
	f.close()
	var ind := _indicadores(camino)
	resumen.append("%s: largo %.0f m, J = %.0f (J/largo = %.3f), E = %.1f m, dosis a %.1f m/s = %.5f mSv, pendiente max %.1f grados, desnivel %.1f m" % [
		nombre, s, j, j / maxf(s, 1.0), ind["E"], VEL_CAMINAR, ind["dosis"], ind["pmax"], h_max - h_min])

extends RefCounted
# Modelo atmosferico de la capa Atmosfera.
#   - Valores BASE: publicados por NASA/JPL y equipos de los instrumentos (fuentes en LEEME.md y en F5).
#   - Variacion con el SOL (estacion): aproximacion a las curvas publicadas, no datos dia a dia.
#   - Variacion de un LUGAR a otro: SINTETICA (ilustrativa), salvo el efecto de la altura sobre la presion.
# Unidades: Pa, mSv, metros. x = este, z = sur, h = altura del suelo respecto al inicio de la ruta.

const SOL_S := 88775.244            # segundos en un sol
const SOLS_ANIO := 668.6            # sols en un anio marciano
const H_ESCALA := 11100.0           # altura de escala de la atmosfera de Marte (m)

# Sol de Perseverance -> longitud solar Ls (estacion). Anclas: aterrizaje Ls ~5 (Harri et al. 2024);
# sol 16 = Ls 13.3, sol 308 = Ls 150.7, sol 313 = Ls 153, sol 565 = Ls 308 (Sanchez-Lavega et al. 2025).
const LS_ANCLAS := [[0.0, 5.0], [16.0, 13.3], [308.0, 150.7], [313.0, 153.0], [565.0, 308.0], [668.6, 365.0]]

# Valores de referencia
const RAD_GALE := 0.67              # mSv/dia, dosis equivalente GCR en Gale (Hassler et al. 2013, RAD/Curiosity)
const RAD_NASA_SUP := 0.8           # mSv/dia, tope de diseno GCR para sistemas en superficie (NASA OCHMO)
const RAD_CARRERA := 600.0          # mSv, limite de carrera NASA-STD-3001
const O2_FRAC := 0.0016             # 0.16 % O2 en el aire (SAM/Curiosity)
const O2_TIERRA := 21200.0          # Pa, presion parcial de O2 a nivel del mar en la Tierra
const P_TIERRA := 101325.0          # Pa
const P_ARMSTRONG := 6300.0         # Pa, limite de Armstrong (el agua hierve a 37 C)
const DD_POR_KM2 := 2.5             # remolinos de polvo por km2 por sol en Jezero (Hueso 2023, Toledo 2023: 1.3-3.4)
# Encuentros de vortices por hora segun la hora local (LTST), medidos por MEDA en Jezero en los primeros 89 sols
# (Jackson 2022, PSJ, figura 6): casi nada antes de las 10, pico de ~1.5/h a las 13, se apagan hacia las 19.
const ACTIVIDAD_DD := [[8.5, 0.0], [9.0, 0.02], [10.0, 0.19], [11.0, 0.93], [12.0, 1.27], [13.0, 1.49], [14.0, 0.90],
	[15.0, 0.89], [16.0, 0.51], [17.0, 0.21], [18.0, 0.08], [19.0, 0.08], [19.5, 0.0]]
const ACTIVIDAD_DD_SUMA := 6.57     # suma de la tabla (encuentros por sol): reparte DD_POR_KM2 entre las horas
# Cuanto dura un remolino. SUPUESTO (no viene de los articulos citados: MEDA mide ~20 s de paso por el sensor,
# no la vida completa). Con 5 min y el pico de las 13 h salen ~0.05 remolinos por km2 al mismo tiempo.
const VIDA_DD_MIN := 5.0
const MULT_DD := 1.0                # 1 = realista. Subirlo solo para ilustrar (mas remolinos de los que hay de verdad)
const PARCHES_AMPL := 0.15          # τ extra maximo de los parches sinteticos (antes 1.1: exageraba; el fondo real casi no cambia en km)

# Rangos de color (0 = tono claro, 1 = tono oscuro)
const TAU_MIN := 0.2
const TAU_MAX := 3.0
const RAD_MIN := 0.60
const RAD_MAX := 0.82
const PO2_BUENO := 1.45             # Pa (claro)
const PO2_MALO := 1.00              # Pa (oscuro)

# Temperatura del aire a 1.5 m (altura del sensor ATS de MEDA). Aproximacion a las curvas de MEDA en Jezero
# (Munguira et al. 2023, JGR Planets): ~ -85 C de madrugada y ~ -20 C despues del mediodia en buen tiempo.
const T_MEDIA := 220.0              # K, media diaria (aprox.)
const T_AMPL := 33.0                # K, mitad de la diferencia dia-noche (aprox.)
const HORA_MIN := 5.5               # hora local (LMST) del minimo
const HORA_MAX := 13.5              # hora local del maximo
# Escala de color de presion y temperatura: del 5 % al 95 % del mapa alrededor del jugador (la variacion local es
# pequenia), con este ancho minimo a cada lado de la mediana para no exagerar diferencias de ruido
const PRES_MEDIO_RANGO := 4.0       # Pa
const TEMP_MEDIO_RANGO := 1.0       # K

var ruido_polvo := FastNoiseLite.new()
var ruido_rad := FastNoiseLite.new()
var ruido_o2 := FastNoiseLite.new()
var ruido_temp := FastNoiseLite.new()


func _init() -> void:
	ruido_temp.seed = 7
	ruido_temp.frequency = 1.0 / 300.0
	for r in [ruido_polvo, ruido_rad, ruido_o2, ruido_temp]:
		r.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		r.fractal_octaves = 3
	ruido_polvo.seed = 2021
	ruido_polvo.frequency = 1.0 / 450.0
	ruido_rad.seed = 448
	ruido_rad.frequency = 1.0 / 380.0
	ruido_o2.seed = 60
	ruido_o2.frequency = 1.0 / 520.0


# ---------------------------------------------------------------- tiempo

func ls_de_sol(sol: float) -> float:
	var anio := floorf(sol / SOLS_ANIO)
	var s := sol - anio * SOLS_ANIO
	for i in LS_ANCLAS.size() - 1:
		var a: Array = LS_ANCLAS[i]
		var b: Array = LS_ANCLAS[i + 1]
		if s <= b[0]:
			return fposmod(lerpf(a[1], b[1], (s - a[0]) / (b[0] - a[0])), 360.0)
	return fposmod(s * 360.0 / SOLS_ANIO, 360.0)


func _campana(x: float, centro: float, ancho: float) -> float:
	var d := (x - centro) / ancho
	return exp(-d * d)


# ---------------------------------------------------------------- presion

# Ciclo estacional aproximado en Jezero (dos minimos por anio; maximo cerca del perihelio, Ls ~250).
func presion_estacion(sol: float) -> float:
	var ls := deg_to_rad(ls_de_sol(sol))
	return 715.0 + 45.0 * cos(ls - deg_to_rad(255.0)) + 25.0 * cos(2.0 * (ls - deg_to_rad(50.0)))


func presion(sol: float, h: float) -> float:
	return presion_estacion(sol) * exp(-h / H_ESCALA)


# ---------------------------------------------------------------- polvo (opacidad optica tau)

func tau_fondo(sol: float) -> float:
	var ls := ls_de_sol(sol)
	# temporada clara (Ls 0-130) ~0.3-0.4; temporada de polvo (Ls 130-360) mas alta
	var t := 0.35 + 0.30 * smoothstep(125.0, 175.0, ls) * (1.0 - smoothstep(330.0, 359.0, ls))
	# tormentas registradas en el anio marciano 36 (Sanchez-Lavega et al. 2025): DS-1 sols 312-318 (pico ~1.4),
	# DS-A sols ~417-472 (tau >= 1), DS-C desde sol ~565 (pico sol 574)
	t += 1.05 * _campana(sol, 316.0, 3.0)
	t += 0.55 * (smoothstep(395.0, 417.0, sol) * (1.0 - smoothstep(472.0, 520.0, sol)))
	t += 0.60 * _campana(sol, 574.0, 6.0)
	return t


# Zonas de levantamiento por rafagas (SINTETICO)
func tau_parches(sol: float, x: float, z: float) -> float:
	var n := ruido_polvo.get_noise_2d(x, z) * 0.5 + 0.5
	var actividad := 0.7 + 0.6 * smoothstep(0.0, 120.0, ls_de_sol(sol))
	return PARCHES_AMPL * smoothstep(0.52, 0.85, n) * actividad


func t_polvo(tau: float) -> float:
	return clampf(log(maxf(tau, TAU_MIN) / TAU_MIN) / log(TAU_MAX / TAU_MIN), 0.0, 1.0)


func luz_bloqueada(tau: float) -> float:
	return 1.0 - exp(-tau)


# Actividad de remolinos a esa hora local (encuentros por hora, tabla ACTIVIDAD_DD interpolada).
func actividad_dd(hora: float) -> float:
	var h := fposmod(hora, 24.0)
	for i in ACTIVIDAD_DD.size() - 1:
		var a: Array = ACTIVIDAD_DD[i]
		var b: Array = ACTIVIDAD_DD[i + 1]
		if h >= a[0] and h <= b[0]:
			return lerpf(a[1], b[1], (h - a[0]) / (b[0] - a[0]))
	return 0.0


# Remolinos que existen AHORA cerca del jugador. Cantidad y tamanio segun MEDA; posicion SINTETICA.
#   remolinos a la vez por km2 = DD_POR_KM2 (por sol) x fraccion de esa hora x vida de cada uno
# Cada casilla de 400 m tira la probabilidad una vez por "vida" (VIDA_DD_MIN) del tiempo real: los remolinos aparecen,
# crecen, se deshacen y otros aparecen en otro lado. Determinista: la misma casilla, sol, hora y ventana dan lo mismo.
# Devuelve hasta `maximo`: [Vector4(x, z, radio, alto)].
func remolinos(sol: float, cx: float, cz: float, t_seg: float, radio_busqueda: float, maximo: int, hora: float) -> Array:
	var celda := 400.0
	var por_hora := DD_POR_KM2 * actividad_dd(hora) / ACTIVIDAD_DD_SUMA        # remolinos por km2 que nacen en esta hora
	var p_celda := MULT_DD * por_hora * (VIDA_DD_MIN / 60.0) * celda * celda / 1.0e6
	var lista: Array = []
	if p_celda <= 0.0:
		return lista
	var vida_s := VIDA_DD_MIN * 60.0
	var c0 := Vector2i(floori((cx - radio_busqueda) / celda), floori((cz - radio_busqueda) / celda))
	var c1 := Vector2i(floori((cx + radio_busqueda) / celda), floori((cz + radio_busqueda) / celda))
	var dia := int(floor(sol))
	for j in range(c0.y, c1.y + 1):
		for i in range(c0.x, c1.x + 1):
			var desfase := float(hash(Vector2i(i, j)) % 1000) / 1000.0 * vida_s     # cada casilla con su propio reloj
			var ventana := floori((t_seg + desfase) / vida_s)
			var edad := fposmod(t_seg + desfase, vida_s) / vida_s                 # 0..1 dentro de su vida
			var rng := RandomNumberGenerator.new()
			rng.seed = hash([i, j, dia, ventana])
			if rng.randf() >= p_celda:
				continue
			var ax := (i + rng.randf()) * celda
			var az := (j + rng.randf()) * celda
			# diametro 5-135 m con mediana ~26 m (Toledo 2023: mediana 25 m, maximo ~132 m); el radio es la mitad
			var diam := exp(lerpf(log(5.0), log(135.0), rng.randf()))
			var alto := lerpf(120.0, 450.0, rng.randf())               # SUPUESTO (altura de la columna)
			var dir := rng.randf() * TAU
			var vel := lerpf(2.0, 6.0, rng.randf())                    # m/s, se mueven con el viento (supuesto)
			var px := ax + cos(dir) * vel * edad * vida_s
			var pz := az + sin(dir) * vel * edad * vida_s
			var forma := sin(PI * edad)                                # crece y se deshace
			var d := Vector2(px - cx, pz - cz).length()
			if d < radio_busqueda and forma > 0.05:
				lista.append([d, Vector4(px, pz, maxf(diam * 0.5 * (0.4 + 0.6 * forma), 3.0), alto * forma)])
	lista.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for e in lista.slice(0, maximo):
		out.append(e[1])
	return out


func tau_remolinos(x: float, z: float, lista: Array) -> float:
	var t := 0.0
	for v: Vector4 in lista:
		var d := Vector2(x - v.x, z - v.y).length() / v.z
		t += 2.2 * exp(-d * d)
	return t


# ---------------------------------------------------------------- radiacion (dosis equivalente, mSv/dia)

# Base Gale (RAD). Menos atmosfera encima = menos blindaje (anticorrelacion medida por RAD, Guo et al. 2017);
# coeficiente -0.3 ilustrativo. Hondonadas y paredes tapan parte del cielo (blindaje del terreno): SINTETICO.
func radiacion(sol: float, h: float, hondonada: float, x: float, z: float) -> float:
	var p := presion(sol, h)
	var base := RAD_GALE * (1.0 - 0.3 * (p - 820.0) / 820.0)
	var blindaje := 1.0 - 0.10 * clampf(hondonada / 15.0, 0.0, 1.0)
	var variacion := 1.0 + 0.10 * ruido_rad.get_noise_2d(x, z)
	return base * blindaje * variacion


func t_rad(d: float) -> float:
	return clampf((d - RAD_MIN) / (RAD_MAX - RAD_MIN), 0.0, 1.0)


# ---------------------------------------------------------------- oxigeno

# Fraccion O2 0.16 % con subida estacional (SAM midio hasta +30 % en primavera/verano; forma aproximada).
func fraccion_o2(sol: float) -> float:
	return O2_FRAC * (1.0 + 0.20 * _campana(ls_de_sol(sol), 75.0, 45.0))


# Presion parcial de O2 (Pa). La parte de la altura es fisica; la variacion local es SINTETICA.
func po2(sol: float, h: float, x: float, z: float) -> float:
	return fraccion_o2(sol) * presion(sol, h) * (1.0 + 0.12 * ruido_o2.get_noise_2d(x, z))


func t_o2_falta(p: float) -> float:
	return clampf((PO2_BUENO - p) / (PO2_BUENO - PO2_MALO), 0.0, 1.0)


# ---------------------------------------------------------------- temperatura del aire (K)

# Forma del ciclo diario: -1 en el minimo (madrugada), +1 en el maximo (despues del mediodia).
func forma_diaria(hora: float) -> float:
	var h := fposmod(hora, 24.0)
	if h >= HORA_MIN and h <= HORA_MAX:
		return -cos(PI * (h - HORA_MIN) / (HORA_MAX - HORA_MIN))
	var hh := h if h > HORA_MAX else h + 24.0
	return cos(PI * (hh - HORA_MAX) / (24.0 - HORA_MAX + HORA_MIN))


# Temperatura del aire en un punto de referencia (sin efectos del lugar).
# Estacion: mas tibio cerca del perihelio (Ls ~250). Polvo: el dia se enfria y la noche se calienta
# (la diferencia dia-noche se achica, MEDA lo vio en las tormentas). Ambos efectos con forma aproximada.
func temp_base(sol: float, hora: float, tau: float) -> float:
	var ls := deg_to_rad(ls_de_sol(sol))
	var media := T_MEDIA + 6.0 * cos(ls - deg_to_rad(250.0))
	var ampl := T_AMPL / (1.0 + 0.4 * maxf(tau - 0.5, 0.0))
	return media + ampl * forma_diaria(hora)


# Factor de dia (0 de noche, 1 con el sol ya alto) para los efectos del lugar. Sol aprox. de 06:00 a 18:00.
func factor_dia(hora: float) -> float:
	var h := fposmod(hora, 24.0)
	if h <= 6.0 or h >= 18.0:
		return 0.0
	return clampf(2.0 * sin(PI * (h - 6.0) / 12.0), 0.0, 1.0)


# Temperatura en un lugar. SINTETICO (con base fisica): de dia las laderas que miran al sol se calientan mas
# (sol_rel = insolacion de la ladera / insolacion en plano - 1); de noche el aire frio baja a las hondonadas.
func temperatura(sol: float, hora: float, tau: float, sol_rel: float, hondonada: float, x: float, z: float) -> float:
	var dia := factor_dia(hora)
	var t := temp_base(sol, hora, tau)
	t += 4.0 * clampf(sol_rel, -1.0, 1.0) * dia
	t -= 5.0 * clampf(hondonada / 15.0, 0.0, 1.0) * (1.0 - dia)
	t += 1.5 * ruido_temp.get_noise_2d(x, z)
	return t


# Insolacion relativa de una ladera con pendiente (gx = dh/dx, gz = dh/dz) bajo un sol en direccion `sol_vec` (hacia el sol).
func insolacion_rel(gx: float, gz: float, sol_vec: Vector3) -> float:
	var n := Vector3(-gx, 1.0, -gz).normalized()
	return maxf(n.dot(sol_vec), 0.0) / maxf(sol_vec.y, 0.1) - 1.0

# Planificador de rutas a pie en Marte (guía de caminata VR)

Calcula la mejor ruta entre dos puntos de una escena de `mars-route-walker` (Jezero, sol 793) según
**distancia, pendiente, tipo de terreno y condiciones**, y la dibuja en el visor Godot/VR como una guía en el suelo.

## Idea central: "mejor ruta" = menor *tiempo efectivo*

Cada paso entre dos celdas vecinas cuesta **segundos**. Es el tiempo real que tarda un astronauta con traje en caminarlo,
multiplicado por penalizaciones de riesgo. Usar segundos como unidad única da dos ventajas: se puede explicar
("esta ruta tarda 2 min 17 s") y el HUD de VR puede mostrar una hora estimada de llegada (ETA) real.

```
costo(a→b) = distancia_3D / velocidad(a→b)  ×  penalización
velocidad   = Tobler(pendiente) × factor_terreno × factor_traje × factor_condición
penalización = 1 + riesgo·(w_pend·exceso_pendiente² + w_rugosidad·rugosidad + w_terreno·riesgo_terreno[clase]) + w_sombra·sombra   (× bonus si va sobre la huella del rover)
```

| Factor | De dónde sale | Por qué |
|---|---|---|
| Distancia 3D | heightmap (1 m o 6 m) | subir también es distancia |
| Pendiente | gradiente del heightmap; **asimétrica** (Tobler: bajar suave es lo más rápido) | subir ≠ bajar, por eso el grafo es dirigido |
| Pendiente límite | ≥ 25° = intransitable; ≥ 15° penaliza (igual que `HAZARD_DEG` del visor) | seguridad con traje |
| Tipo de terreno | `terrain_classes.py`: mapa externo si lo hay; si no, proxy (rugosidad del DEM + brillo del ortho HiRISE). Velocidad: roca firme 1.0, regolito 0.9, arena/duna 0.6, bloques 0.5; **riesgo extra**: duna 1.5, bloques 0.8, regolito 0.1 | una duna cuesta ~4× el terreno firme (velocidad 0.6 y penalización 2.5) |
| Sombra | sombreado del relieve según azimut y elevación del sol | frío: evitar laderas sin sol |
| Huella del rover | `route_local.json` (celdas a ≤ 2 m) | terreno ya explorado |
| Condiciones | `normal`, `tormenta_polvo` (menos visibilidad, pendiente segura 8°, sigue más la huella), `frio_sombra` | cambian **la ruta**, no solo el ETA |

## Reconocimiento de terreno (duna vs. terreno firme)

`terrain_classes.py` produce una matriz de enteros con la **misma forma y georreferencia que la de pendientes** (cuadrícula n×n centrada
en el origen de la escena, fila 0 = norte). Los códigos están definidos en un solo lugar:

| Código | Clase | Nombre corto (HUD) |
|---|---|---|
| 0 | roca firme | roca firme |
| 1 | regolito | regolito |
| 2 | arena / duna | duna |
| 3 | bloques / rocoso | bloques |

Fuentes intercambiables (misma interfaz `fuente(g) -> (matriz, info)`):

1. **Mapa externo** (`--terrain-map ruta`): `.npy`, `.png` (el valor del píxel es el código), `.f32` o `.u8` (n×n crudo). Debe cubrir el **mismo cuadrado**
   que la capa; si su resolución difiere se remuestrea por vecino más cercano. Si usa otros códigos, un `ruta.json` con `{"codes": {"valor_externo": codigo}}`.
   Para otra fuente (p. ej. un clasificador propio) basta una clase con `name` y `__call__(g)` (ver `make_source`).
2. **Proxy** (por defecto): rugosidad del DEM + brillo del ortho (brillante y liso → roca; oscuro y liso → arena/duna; rugoso → bloques) y un filtro de moda 3×3 que quita celdas sueltas.
   **Es una aproximación, no un mapa de dunas.** Los umbrales de brillo son percentiles de la propia escena, así que casi siempre marca ~20 % como "duna" aunque no haya ninguna.

La fuente usada se registra en el log (con la advertencia del proxy) y en el JSON de salida (`terrain_source`). Cada punto de `guide_path.json` trae su clase en `terrain[]`
y `summary.dune_m` los metros sobre duna. `--png-clases clases.png` guarda la matriz de clases (paleta + leyenda con porcentajes + ruta) para revisar el clasificador a ojo.

### Riesgo (`--riesgo`)

`--riesgo W` (default 1.0) multiplica el peso de pendiente, rugosidad y terreno frente a la distancia: **"ruta más cercana y menos peligrosa" = menor costo efectivo**.
`0` = solo tiempo de marcha (cruza dunas si es más corto); `3` = rodea casi todo. No cambia el algoritmo, solo los costos. El ETA siempre es tiempo real de marcha, sin penalizaciones.

### Supuestos configurables

Todos los pesos viven en **`route_config.py`** y son **supuestos, no mediciones**: factores y riesgo por terreno, traje 0.55, pendientes 15°/25°, condiciones y umbrales del proxy.
Se pueden sobrescribir sin tocar código: `--config mis_supuestos.json` (mismas claves, p. ej. `{"TERRAIN_RISK": {"2": 3.0}}`).

## Algoritmo (paso a paso)

1. **Capas**: del heightmap salen la pendiente, la rugosidad y la sombra; del ortho, el brillo. Con eso (o con un mapa externo) se asigna la clase de terreno.
2. **Costos**: velocidad y penalización por celda según condición y `--riesgo`; se bloquean las celdas con pendiente ≥ 25°.
3. **A\*** en una cuadrícula de 8 vecinos. Heurística = distancia en línea recta / velocidad máxima posible (admisible: da la ruta óptima).
4. **Planificación jerárquica** (solo capas grandes, > 200 000 celdas, p. ej. el anillo de 3 km): A\* grueso en bloques de 4×4 celdas y A\* fino restringido a un corredor de ±3 celdas gruesas alrededor.
5. **Suavizado** con *string pulling* (atajo solo si cuesta ≤ 2 % más; salto máximo de 60 nodos) y Chaikin. Chaikin puede rozar la esquina de una franja de duna (~1 celda).
6. **Exportar** `guide_path.json`: un punto por metro con altura, ETA acumulado, pendiente, **clase de terreno**, advertencias (pendiente, bloques, tramo de duna) y lon/lat de cada punto.

## Uso

```bash
cd route-planner
source ../.venv/bin/activate                         # numpy + Pillow
SCENE=../viewer-godot/patch_793

# Ruta corta en el parche caminable (1 m, ±45 m), las 3 condiciones + vista previa + matriz de clases
python mars_route.py $SCENE --start 0 0 --goal 40 40 --cond all --png preview.png --png-clases clases.png

# Más cuidado con dunas/rocas/pendiente (o menos: --riesgo 0)
python mars_route.py $SCENE --goal 40 40 --riesgo 3

# Destino por lat/lon, o por punto guardado (id o nombre)
python mars_route.py $SCENE --goal-latlon 18.4830 77.3690
python mars_route.py $SCENE --waypoint origen_escena

# Con un mapa de dunas/geológico propio en vez del proxy
python mars_route.py $SCENE --goal 40 40 --terrain-map mi_mapa.npy

# Ruta larga en el anillo de 3 km (6 m/celda; jerárquica automática, ~1.6 s)
python mars_route.py $SCENE --layer ring_3km --goal 1800 -1500 --out ring_path.json --png ring.png
```
Coordenadas en metros: **x = este, z = sur**, con origen en el waypoint del rover (las mismas del HUD del visor). `--start-latlon` y `--goal-latlon` usan grados decimales (lon este positiva).
Si un punto dado en lat/lon cae sobre una celda intransitable se usa la transitable más cercana (≤ 5 m) y se **avisa**; si cae fuera de la capa se da un error claro. Los puntos `--start/--goal X Z` siguen siendo estrictos, como antes.

### lat/lon (`geo.py`) y puntos guardados (`waypoints.py`)

`geo.py` convierte lat/lon ↔ metros locales ↔ celda con la georreferencia de la escena (`scene.json → origin.lon/lat`) y la misma fórmula esférica de `marswalk.geo.Site`
(x = R·cos(lat0)·Δlon, z = R·(lat0 − lat)). Es una aproximación local (sirve en ±3 km). Si la escena no trae `origin` lanza un error y **no inventa valores**.

`viewer-godot/route/waypoints.json` guarda los puntos importantes (`id`, `nombre`, `lat`, `lon`, `descripcion`). Python y Godot leen el mismo archivo:

```bash
python waypoints.py list
python waypoints.py add rescate "Punto de rescate" 18.4830 77.3690 "donde rescatamos al Ingenuity"
python waypoints.py del rescate
```
Las entradas `base` y `rescate_ingenuity` son **placeholders** (`"placeholder": true`, lat/lon `null`): reemplázalas con coordenadas reales. Usarlas como destino da un error claro.
`origen_escena` (de `scene.json`) e `ingenuity` (de `layers/ingenuity/ingenuity.json`) son coordenadas reales del repo. En el **world** Ingenuity cae en (x −7216, z −3120) (tile 11_20) y es alcanzable;
en el parche de 1 m queda fuera de la capa (a ~2.7 km solo cabe en `--layer ring_3km` de `patch_793`). Ojo: `origen_escena` es el origen del parche, no el del world (en el world el origen es el primer vértice de la ruta del rover).

## Integración con el mapa

El mapa (de tu compañera) solo necesita **emitir una señal en Godot**; todo lo demás funciona sin cambios. No se asume cómo está hecho el mapa.

### En Godot (`viewer-godot/route/route_ui.gd`, nodo `RouteUI`)

```gdscript
signal destination_selected(lat: float, lon: float, nombre: String)   # ÚNICA puerta de entrada de destinos
signal player_position_changed(lat: float, lon: float)                # salida: dónde está el jugador (cada ~0.5 s, solo si se movió)
func set_start(lat: float, lon: float)    # entrada: el mapa fija el punto de partida (si no, se usa la posición del jugador)
func clear_start()
```
El ingreso por teclado (`L`), los puntos guardados (`P`) y el mapa pasan por la **misma** señal. Ejemplo mínimo desde el código del mapa, al tocar un punto:

```gdscript
var route_ui := get_tree().root.find_child("RouteUI", true, false)   # lo crea main.gd en modo parche
route_ui.destination_selected.emit(18.4830, 77.3690, "Punto tocado en el mapa")

# para dibujar al jugador en el mapa:
route_ui.player_position_changed.connect(func(lat, lon): mi_marcador.actualizar(lat, lon))
```
Para un punto importante marcado en el mapa, emitir sus `lat`, `lon` y `nombre` (o llamar `route_ui.select_waypoint("id")`).
Otras señales: `route_ready(result_path)` y `route_failed(message)`.

### En Python: `plan_route` y el contrato JSON

```python
import mars_route as m
layers = m.load_layers("viewer-godot/patch_793")          # una sola vez (pendiente, rugosidad, sombra, terreno); se reutiliza
res = m.plan_route(layers, start={"x": 0, "z": 0}, goal={"lat": 18.4830, "lon": 77.3690},
                   condition="normal", risk_weight=1.0)   # sin estado global; llamar cuando se quiera
res.ok, res.error_code, res.route, res.timing             # RouteResult
```
Por proceso (lo que usa Godot): `python mars_route.py ESCENA --request req.json --result res.json` (código de salida 0 = ok, 2 = error con detalle en el JSON).

**Petición** (todos los campos salvo `goal` son opcionales):

| Campo | Tipo / unidad | Significado |
|---|---|---|
| `scene` | texto | carpeta de la escena (con `scene.json`); si falta se usa el argumento posicional |
| `layer` | texto | parche: `terrain` (1 m, ±45 m; default) o `ring_3km` (6 m, ±3 km). Se ignora en world |
| `lod` | 1, 5 ó 20 | solo world: fuerza el paso del terreno en m (default: según el tamaño del recorte) |
| `start`, `goal` | objeto | `{"x","z"}` metros locales (x este, z sur) · `{"lat","lon"}` grados decimales (lon este +) · `{"waypoint": id_o_nombre}`. Default de `start`: `{"x":0,"z":0}` |
| `condition` | texto | `normal` (default), `tormenta_polvo`, `frio_sombra` |
| `risk_weight` | número ≥ 0 | peso de riesgo (default 1.0) |
| `terrain_map` | texto | mapa de clases externo (si no, proxy) |
| `hierarchical` | `auto`/`on`/`off` | planificación jerárquica (default `auto`) |
| `snap_m` | número, m | radio para mover un punto intransitable a la celda transitable más cercana (default 5; 0 = estricto) |
| `waypoints`, `sun` | texto, `[az°, el°]` | archivo de puntos guardados; azimut y elevación del sol |

**Respuesta**: `{"schema": 1, "ok": bool, "error": texto|null, "error_code": texto|null, "route": {...}|null, "warnings": [texto], "timing_ms": {...}}`.
`route` es el `guide_path.json` (campos: `points` [x,y,z] en metros, `eta_s` segundos acumulados, `slope_deg` grados, `terrain` código por punto, `terrain_names`, `terrain_source`
{`source`, `is_proxy`, `warning`}, `warnings` [{i, type, msg}], `lonlat` [lon, lat] por punto, `summary` {`length_m`, `eta_s`, `dune_m`, ...}, `risk_weight`, `conditions`).
`error_code` estable: `peticion_invalida`, `escena_invalida`, `condicion_invalida`, `riesgo_invalido`, `punto_invalido`, `sin_georreferencia`, `fuera_de_capa`, `intransitable`,
`waypoint_invalido`, `sin_ruta`. Un error nunca deja una ruta a medias.

### Cómo Godot pide la ruta

`RouteUI` escribe `user://route/req_N.json`, lanza `mars_route.py --request … --result …` con `OS.create_process` (**no bloquea el frame**), muestra "Calculando ruta a X…" en el HUD, sondea
si terminó y entonces llama `GuidePath.set_route(res_N.json)`. Una petición nueva mata la anterior. Es un proceso por petición (~0.4 s en el parche, ~3 s en el anillo, casi todo carga de capas);
si más adelante hace falta menos latencia, el siguiente paso es un proceso persistente que mantenga las capas cargadas. Python: `../.venv/bin/python` o `python3`.

## Modo world (mundo por tiles)

Una carpeta con `world.json` (release `world-v1`, `kind: tiled_world`) también es una "escena": `python mars_route.py /ruta/world --goal-latlon 18.4972 77.3225` o `--waypoint ingenuity`.
Coordenadas: las del world (**x este, z sur, origen = primer vértice de la ruta del rover**, y = elevación − `datum_m`). Como cada petición cubre una zona distinta, el grid se **ensambla por petición** (`world_grid.py`):

1. Rectángulo inicio–meta + margen (`max(100 m, 10 % del tramo, tope 500 m)`), alineado a 100 m y recortado a los tiles. Cada punto debe caer en un tile existente (`fuera_de_capa`).
2. **LOD** (la regla más simple): `t1` (1 m) si el recorte tiene ≤ 250 000 celdas (~500×500 m); si no `t5` (5 m) si ≤ 1 600 000; si no `t20`; si ni así cabe, error. `--lod 1|5|20` (o `"lod"` en la petición) lo fuerza.
3. Geometría de `world.gd`: el mosaico es una cuadrícula en píxeles con `spacing_x ≈ 0.9485` m/px en x y `spacing_z = 1`; cada tile trae (block/N+1)² muestras con el borde este/sur compartido. El grid del planificador es cuadrado **en metros**, así que se interpola bilinealmente (igual que `WorldStreamer.height_at`); un test comprueba que sobre un plano la altura es exacta cruzando bordes de tiles.
4. Pendiente, rugosidad, sombra, clases, costos, A\* (jerárquico si > 200 000 celdas), suavizado y exportación son los mismos. El contrato JSON no cambia (`points` x/y/z en el frame del world; `lonlat` por punto).
5. **Terreno**: proxy con el ortho del tile (`o100` para ≤ 2 m, `o400` si no), con percentiles calculados **solo sobre las celdas con datos del recorte** (así que la clasificación de un mismo lugar puede cambiar un poco entre recortes). `terrain_map` externo aún no se soporta en world. La huella del rover (`route.json`) se usa como preferencia, como en el parche.
6. **Nodata**: una celda fuera de los tiles, o en un tile con `nodata_frac ≥ 0.5` en `world.json` (sus alturas fueron rellenadas), es intransitable (se mueve a la celda transitable más cercana o da `intransitable`). Con `nodata_frac` parcial (< 0.5) no se sabe qué celdas son: se usa el tile y se avisa en `warnings`. Hay 8 tiles con nodata en el world de Jezero (bx 2-3, by 23-27).

`geo.WorldGeo` es una réplica exacta de `WorldStreamer.lonlat_to_world / world_to_lonlat` (usa `origin.mosaic_x0/y0`, `origin.px`, `spacing_x/z` y el radio; `origin.lat0` = 18.4666 **no interviene**, solo fijó `spacing_x` al construir).
Un test compara contra valores calculados por Godot (diferencia < 2 mm, la de float32).

`--export-terrain PREFIJO --around X Z [--radius 200]` escribe una ventana t1 de clases alrededor de un punto (la usa el HUD del visor).

## Tiempos de planificación (medidos)

| Caso | Capa | Tiempo de `plan_route` (capas ya cargadas) | Proceso completo |
|---|---|---|---|
| (0,0) → (40,40) | parche 1 m, 91×91 | **~85 ms** (A\* 58 ms, 1 590 nodos) | 0.41 s |
| (0,0) → (1800,−1500), jerárquica | anillo 6 m, 1000×1000 | **~1.6 s** (grueso 0.3 s, fino 0.6 s, suavizado 0.6 s) | 3.1 s |
| ídem, sin jerarquía | anillo | 6.0 s (A\* 5.5 s, 121 293 nodos) | – |

| World: (0,0) → (40,40), t1 | recorte 301×301 | **~270 ms** (recorte 180 ms + A\* 86 ms) | – |
| World: (0,0) → (300,−200), t1 + jerárquica | recorte 501×401 | **~850 ms** | – |
| World: (0,0) → **Ingenuity** (8.6 km, t5 + jerárquica) | recorte 1661×841 | **~6.2 s** (recorte 0.9 s, grueso 1.9 s, A\* 2.1 s, suavizado 1.1 s) | ~7 s |

**Elegí la jerarquía automática para capas grandes** porque la ruta larga exacta tarda 6 s (y antes ~30 s, casi todo en el suavizado, que ahora está vectorizado y acotado):
demasiado para uso interactivo. La jerárquica explora 8× menos nodos y da una ruta ~0.6 % más lenta en ETA (3 592 s vs 3 574 s) en la prueba. El parche de 1 m no la necesita.
La cuadrícula gruesa promedia pendientes, así que puede pasar por alto un paso estrecho entre zonas bloqueadas; en ese caso, si no encuentra ruta, vuelve a la búsqueda completa. `--hier off` fuerza la exacta.

## En el visor (Godot / VR)

Todo está en `viewer-godot/route/`: `guide_path.gd` (la línea guía) y `route_ui.gd` (destino, HUD, proceso externo). `main.gd` los crea con `_route_setup()` (modo parche) o `_route_setup_world()` (modo `--world=`, que usa
`RouteUI.setup_world`) y agrega la salida al HUD; `--noroute` los desactiva. En world la guía se re-pega al terreno del visor (`WorldStreamer.height_at`) y flota 0.3 m, porque los LOD de la malla difieren del que usó el planificador;
el HUD muestra "Terreno: …" con una ventana t1 de ~400 m alrededor del jugador que el planificador regenera en segundo plano al acercarte al borde.

Teclas: **L** escribir lat/lon (valida formato y rango y muestra el error en pantalla) · **P** lista de puntos guardados, número 1-9 · **R** recalcular desde donde estás hasta el último destino · **C** borrar ruta · **Esc** cierra el diálogo.
El HUD muestra "Terreno: duna" (clase bajo el jugador, de la matriz del planificador), lat/lon, "(estimado: proxy)" si aplica, ETA, advertencias y "Calculando…".

`GuidePath`: chevrones en el suelo coloreados por riesgo (verde = ok, **morado = duna / arena suelta**, ámbar = pendiente ≥ 15°, rojo = bloques o ≥ 20°), baliza con nombre y ETA en la meta, flecha flotante 4 m adelante
(o de vuelta a la ruta si te sales a más de 3 m). `set_route(ruta_json)` recarga una ruta en ejecución (acepta el `guide_path.json` o el sobre de `plan_route`); `clear_route()` la borra.

Prueba headless (Godot 4.7.2): `godot --headless --path viewer-godot --script res://route/selftest.gd -- --patch=patch_793` o `-- --world=/ruta/al/world` (en world incluye Ingenuity como destino).
Para probarlo a mano: `godot --path viewer-godot --xr-mode off -- --world=/ruta/al/world --sol=1114`, pulsa **G** para bajar del rover (a pie), **P** y **2** (Ingenuity) o **L** y escribe `18.4972, 77.3225`; espera el "Calculando…" (~7 s) y sigue la línea.
Si el caché de clases del proyecto está desactualizado (error `FarRings not declared`), corre antes `godot --headless --editor --quit --path viewer-godot`.
**No probado en el headset VR** (la entrada de texto de `L` es por teclado; en VR hace falta un teclado virtual o usar `P`).

## Tests

```bash
.venv/bin/python -m pytest tests            # clasificador, rutas que evitan/cruzan dunas, lat/lon, puntos guardados, contrato JSON, replanificación
```

## Límites honestos

- **El reconocimiento de dunas con el proxy es poco confiable.** Usa solo brillo del ortho + rugosidad de un DEM de 1 m: no distingue arena de roca oscura, sombra o polvo, ni ve óndulas menores a ~2 m. Marca "duna" ~20 % de la escena por construcción (percentil), con o sin dunas reales. Sirve para probar el flujo; para decidir rutas reales hace falta un mapa de dunas/geológico (`--terrain-map`; p. ej. Stack et al. 2020 para Jezero).
- Las rocas menores a 1 m no aparecen en el DEM. Las rocas del visor son sintéticas, así que la ruta no las esquiva.
- Los parámetros (traje 0.55, 15°/25°, factores y riesgo por terreno) son supuestos razonables; no salen de mediciones.
- lat/lon usa una proyección esférica local; el origen debe estar en `scene.json`.
- El parche caminable mide solo 90 m; para destinos más lejos usa el modo world.
- **World**: la ruta larga (8.6 km, t5) tarda ~6 s: no es instantánea (hay "Calculando…" y no se bloquea el frame). A 5 m las pendientes se suavizan, así que la ruta larga puede cruzar pendientes locales más duras de lo que dice `max_slope_deg`; los últimos metros no se refinan a 1 m.
- **World**: los percentiles del proxy dependen del recorte; el terreno bajo el jugador (ventana t1) y el de una ruta larga (t5) pueden no coincidir. 8 tiles tienen nodata (se bloquean); la ruta no los cruza. `terrain_map` externo no está soportado en world.
- **World**: el ortho de world se usa con el mismo proxy de brillo; no se probó contra una verdad de terreno.
- Un punto intransitable se mueve a la celda transitable más cercana, que podría ser una zona aislada (entonces el error es `sin_ruta`).

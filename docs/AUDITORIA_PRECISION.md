# Auditoría de precisión: planificador Python ↔ Godot ↔ Steam Frame

Rama `capa/ingenuity` (sin commitear los cambios de esta auditoría). El "Síntoma" del encargo venía sin llenar, así que se midió todo contra la geometría del propio proyecto.
Todas las cifras salen de scripts ejecutados en esta sesión (scripts de medición en el scratchpad; las comprobaciones que quedaron como tests están en `tests/` y `viewer-godot/route/`).

## 1. Línea base (antes de tocar)
- `pytest`: 23 passed. `selftest.gd` en `--patch=patch_793` y en `--world=…`: TODO OK. Ruta (0,0)→(40,40), 3 condiciones: 59.9/60.1/59.9 m, ETA 87/138/102 s.
- **El Frame NO corre el mismo código.** `frame-bundle/` se construyó el 13-nov 10:41 (antes de toda la ruta):

| Archivo | `frame-bundle/…/viewer-godot` | PC (`viewer-godot`) |
|---|---|---|
| `route/guide_path.gd`, `route_ui.gd`, `selftest.gd`, `waypoints.json` | **no existen** | existen |
| `world.gd`, `terrain.gdshader` | **no existen** | existen |
| `main.gd` | versión vieja (350 líneas distintas) | actual |
| `route-planner/` (Python) | **no está en el bundle** | existe |
| `project.godot` | con `openxr/default_action_map` | el del working tree **lo perdió** (lo reescribió el editor) |

  El `.tgz` es idéntico al directorio. Además `tools/frame/make_bundle.sh` solo empaquetaba `viewer-godot`, así que aunque se regenerara el bundle **no llevaría el planificador**, y `install.sh` no preparaba Python (el visor busca `<repo>/.venv/bin/python`). Es la causa principal de "en el Frame no hay ruta / no coincide con la PC".
  `mars-route-walker-main/` tiene `world.gd` y shader idénticos a la PC, `main.gd` y `project.godot` distintos (no tiene `route/`).

## 2. Tabla de hipótesis

| | Hipótesis | Estado | Evidencia |
|---|---|---|---|
| A1 | Ejes x este / z sur invertidos al pasar a Godot | **Descartada** | Godot `height_at(x,z)` sobre los puntos del JSON: error máx 0.0013 m (redondeo del JSON). `latlon_to_local` de Godot = Python a 1e-6 m (3 puntos). `main.gd:297-310` (`_hraw`/`height_at`) usa fila = z, columna = x igual que `mars_route.py` (`to_rc`) |
| A2 | Unidades (rad/°, tan vs ángulo, km/h vs m/s) | **Descartada** | Tobler recibe `dh/dxy` adimensional y vale 6 km/h = 1.667 m/s en −0.05 (`mars_route.py` `tobler_ms`); 1 m/celda en parche, 6 m anillo, 5 m world, usados en `step` de cada capa |
| B1 | Pendiente mal dividida por el espaciado | **Descartada** | `np.gradient(h, step)` = diferencia central de la bilineal de Godot (`slope_deg`) en nodos: 0.0000° de diferencia. Fuera de nodos la pendiente del JSON es la de la celda más cercana: mediana 0.15°, máx 1.55° |
| B2 | Interpolación/malla distinta | **Descartada (parche)** | Bilineal idéntica (clamp `n−1.001`, origen `−half`). Malla de Godot (triángulos cada 0.5 m) vs bilineal: máx 2.8 mm |
| B3 | Altura del JSON ≠ superficie visible (world) | **CONFIRMADA** | JSON a 5 m vs superficie t5 de `WorldStreamer.height_at`: error máx **0.439 m** (doble interpolación: tile→grid de metros→punto). Además la guía se fijaba con t5 y la malla/jugador pasan a t1 al cargar `h1` (`world.gd:112, 287`): t1−t5 en la ruta a Ingenuity máx 0.56 m, p95 0.11 m |
| B4 | Pendiente a 5 m oculta pendientes reales (world) | **CONFIRMADA** | Ruta a Ingenuity (9 060 pts): pendiente de celda 5 m máx 19.9° vs local 1 m máx **31.2°**; puntos ≥15°: 41 vs 131; puntos ≥25° (intransitable): 0 vs 4 |
| C1 | Heurística no admisible | **Descartada** | A\* vs Dijkstra (H≈0), 36 pares × 3 condiciones: diferencia de costo máx 0.000000 s |
| C2 | Costo A\* ≠ ETA | **Descartada (por diseño)** | El ETA no lleva penalizaciones (documentado). El ETA exportado difiere del tiempo del camino bruto en −2.5 s (−2.8 %) solo porque el suavizado acorta 61.6→59.9 m; sin redondear coordenadas la diferencia es 0.025 s |
| C3 | Asimetría subir/bajar, diagonales | **Descartada** | Tobler(−0.2)=0.99 m/s vs Tobler(+0.2)=0.70 m/s; `hypot` para diagonal y altura (`edge_cost`) |
| C4 | **ETA ≠ lo que camina el visor** | **CONFIRMADA (modelo, no bug)** | Planificador: 0.69 m/s en regolito plano, 0.92 m/s máx (traje 0.55). El visor camina a **2.2 m/s** (`main.gd:213, 227, 718, 732`; 6 con Shift en parche, 20 en world). Caminar los 60 m del ejemplo toma ~27 s a pie del visor vs ETA 87 s (3.2×) |
| D1 | El atajo cruza celdas intransitables | **Descartada** | 13 964 puntos exportados (24 rutas aleatorias, world t1, 0 bloqueadas en la muestra de celdas con pendiente ≥25° = 7–20 mil por recorte) → 0 en celda bloqueada; parche sin celdas bloqueadas |
| D2 | Chaikin / remuestreo | **Parcial** | ETA/altura/pendiente SÍ se recalculan sobre los puntos suavizados. El espaciado no es "1 punto/m": 0.06–1.0 m (media 0.50). No afecta cálculos (Godot usa la distancia real acumulada) pero duplica el JSON |
| E | Geodesia | **Descartada** | Esfera R=3 396 190 m (la misma del mosaico). Error del plano local vs haversine: 0.00 m a 3 km (E o S), 0.16 m en diagonal a 3 km, 0.21 m a 80 km E, 109 m (0.14 %) en diagonal a 80 km. `WorldGeo` = `WorldStreamer` a 2 mm (test) |
| F1 | Distancia restante / ETA saltan | **CONFIRMADA** | `guide_path.gd` usaba el vértice más cercano: error de distancia restante máx **0.48 m** (rms 0.23), salto de hasta **0.90 m** por avance real de 0.1 m, ETA hasta 0.67 s |
| F2 | Umbral fuera de ruta (3 m) | Menor | Medía hasta el vértice (+0.03 m con 1 m de espaciado); ahora distancia al segmento |
| F3 | float32 lejos del origen | **Descartada** | 12 km en float32: 0.0003 m de error de representación; `cum` y `eta` como `PackedFloat32Array`: ulp 1 mm / 1 ms a 8.5 km / 13 000 s |
| F4 | `_process` vs `_physics_process` / `delta` | **Descartada** | Todo el movimiento y la guía en `_process` con `delta`; no hay física |
| F5 | VR: referencia de la posición del jugador | **CONFIRMADA (diseño)** | `route_ui.tick` recibía `origin.position`, no la cámara: con room-scale (el jugador camina dentro del cuarto) la distancia, la flecha (1.6 m fijos sobre el origen) y el punto de partida del replan quedaban desplazados lo que se haya movido físicamente (1–2 m) |
| F6 | VR: altura del suelo | **No corregido (núcleo)** | `main.gd` fija `origin.y = height_at(origin)`; con room-scale el suelo bajo los pies es el de la posición real: error = pendiente × desplazamiento (p. ej. 15° y 1.5 m → 0.40 m). `xr/openxr/reference_space = 1` (local_floor), `world_scale = 1.0`, `cam.y = 1.6` solo en pantalla plana (en VR lo pisa el tracker) |
| G1 | Bundle del Frame desactualizado | **CONFIRMADA** | ver §1 |
| G2 | Endianness / arm64 / renderer | **Descartada** | `.f32` little-endian en ambos (arm64 LE); `renderer/rendering_method="mobile"` igual; rutas `res://` |
| G3 | `guide_path.json` / `waypoints.json` instalados iguales | **Incumple** | `waypoints.json` y `route/` no están en el bundle |

## 3. Bugs confirmados por impacto
1. **G1 Frame sin código de ruta ni planificador** (impacto total en el Frame).
2. **C4 ETA 3.2× el tiempo que tarda el visor en recorrer la ruta** (modelo: traje EVA vs caminar libre del visor).
3. **F5 VR: guía referida al XROrigin3D y no a la cámara** (1–2 m en room-scale).
4. **B4 pendientes ocultas en rutas largas de world**: 4 puntos reales ≥25° y 90 puntos más ≥15° sin aviso.
5. **F1 distancia/ETA restante cuantizados**: hasta 0.48 m / 0.67 s y saltos de 0.9 m.
6. **B3 altura del JSON y de la guía en world**: hasta 0.44 m (doble interpolación) y 0.56 m (t5 vs t1).

## 4. Cambios aplicados y tests (todo sin commitear)
| Archivo | Cambio | Test |
|---|---|---|
| `route-planner/world_grid.py`, `mars_route.py` (`export`) | En world la `y` sale de los tiles (`World.heights_at`, mismo LOD que la malla) y la pendiente local de 1 m (`slopes_at`, igual que `WorldStreamer.slope_deg`) en vez del grid remuestreado. La planificación no cambia | `tests/test_route_world.py::test_world_altura_y_pendiente_salen_de_los_tiles`: y exacta (2 mm) vs 0.05–0.4 m con el método viejo; pendiente de 1 m vs celda de 5 m (>3° de diferencia en el relieve de prueba). Real (Ingenuity): y−t5 **0.439 → 0.002 m**; pendiente máx exportada 19.9° → 31.2°; puntos ≥15°: 41 → 136 (35 avisos de pendiente) |
| `viewer-godot/route/guide_path.gd` | Proyección sobre el segmento (`_project`): distancia restante, ETA y fuera-de-ruta exactos; `update_player(…, head_pos)`; `refresh_heights()` re-pega chevrons cercanos a `height_fn` cada 0.5 s | `viewer-godot/route/test_guide.gd` (+ `tests/test_godot.py`): con el script anterior: error 0.478 m, ETA 0.668 s, salto 0.901 m (FALLA); con el nuevo: 0.000 m, 0.000 s, 0.000 m |
| `viewer-godot/route/route_ui.gd` | `feet()` = cámara proyectada al suelo; la usan `tick`, `hud_lines`, el punto de partida del replan y `player_latlon`; la flecha usa la cámara real | `selftest.gd` (pasos 9–11): `feet()` con la cámara a (2, −1) m del origen |
| `tools/frame/make_bundle.sh`, `install.sh` | El bundle incluye `route-planner/`; `install.sh` crea `~/mars/mars-route-walker/.venv` con numpy+Pillow (con aviso si falla) | `tests/test_frame_bundle.py` (con los scripts anteriores FALLA: falta `route-planner/mars_route.py`) |

Estado final: `pytest tests` → **28 passed** (incluye los de Godot headless parche); `selftest.gd --world` → TODO OK; `test_guide.gd` → TODO OK.
**No se tocó:** `main.gd` (núcleo), `project.godot`, datos, `frame-bundle/` (hay que regenerarlo: `bash tools/frame/make_bundle.sh` desde la raíz), el modelo de velocidad (C4) ni el seguimiento de altura del suelo en VR (F6).

## 5. Lo que no se pudo verificar sin el Steam Frame y qué probar
Hay que **regenerar e instalar el bundle** (`bash tools/frame/make_bundle.sh`, copiarlo, `install.sh`; revisar que diga "Planificador de rutas: OK"). `project.godot` a empaquetar debe ser el de HEAD (con `default_action_map`), no el del working tree.

1. **Ruta presente y mismos números:** en el Frame, `mars-flat.sh`, tecla **L** → `18.4830, 77.3690`. Debe decir ~60 m, ETA ~87 s (normal), la misma línea que en la PC. Si dice "No se pudo ejecutar el planificador", el venv no se creó.
2. **Distancia recorrida:** a pie por la línea con un tramo medido (cinta en el cuarto no sirve: usar el stick). 60 m a 2.2 m/s = 27 s; el HUD marcará ETA 87 s → ver C4. "Faltan N m" debe bajar de forma continua (sin saltos de ~1 m).
3. **Room-scale (F5/F6):** con `mars-xr.sh`, ruta activa; caminar físicamente 1.5 m hacia la línea sin mover el stick: "faltan" debe bajar ~1.5 m y la flecha estar 1 m delante de los ojos. Medir el desnivel del suelo bajo los pies en una pendiente (F6 sin corregir).
4. **Altura de la guía (parche):** debe estar a ~5 cm sobre el suelo (en world, 30 cm). Si flota/se hunde >0.1 m, anotar posición.
5. **Referencia de lat/lon:** el HUD en el origen del parche debe mostrar `lat 18.48256 lon 77.36868`.
6. **Refresco / rendimiento:** FPS al cargar una ruta larga; el planificador corre en un proceso aparte (en el Frame arm64 puede tardar más que en la PC: medir "calculada en N ms" en el HUD).

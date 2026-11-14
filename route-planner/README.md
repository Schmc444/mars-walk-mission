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
penalización = 1 + w_pend·exceso_pendiente² + w_rugosidad·rugosidad + w_sombra·sombra   (× bonus si va sobre la huella del rover)
```

| Factor | De dónde sale | Por qué |
|---|---|---|
| Distancia 3D | heightmap (1 m o 6 m) | subir también es distancia |
| Pendiente | gradiente del heightmap; **asimétrica** (Tobler: bajar suave es lo más rápido) | subir ≠ bajar, por eso el grafo es dirigido |
| Pendiente límite | ≥ 25° = intransitable; ≥ 15° penaliza (igual que `HAZARD_DEG` del visor) | seguridad con traje |
| Tipo de terreno (proxy) | rugosidad del DEM + brillo del ortho HiRISE: roca firme 1.0, regolito 0.9, arena/óndulas 0.6, bloques 0.5 | aún no hay mapa geológico en la escena |
| Sombra | sombreado del relieve según azimut y elevación del sol | frío: evitar laderas sin sol |
| Huella del rover | `route_local.json` (celdas a ≤ 2 m) | terreno ya explorado |
| Condiciones | `normal`, `tormenta_polvo` (menos visibilidad, pendiente segura 8°, sigue más la huella), `frio_sombra` | cambian **la ruta**, no solo el ETA |

## Algoritmo (paso a paso)

1. **Capas**: del heightmap salen la pendiente, la rugosidad y la sombra; del ortho, el brillo. Con eso se asigna una clase de terreno.
2. **Costos**: se calcula la velocidad y la penalización por celda; se bloquean las celdas con pendiente ≥ 25°.
3. **A\*** en una cuadrícula de 8 vecinos. Heurística = distancia en línea recta / velocidad máxima posible.
   Nunca sobreestima el costo real, así que A\* da la ruta óptima, pero expande muchos menos nodos que Dijkstra.
4. **Suavizado** con *string pulling*: un atajo en línea recta solo se acepta si su costo es como máximo un 2% mayor
   que el del camino original. Después se aplica Chaikin para que la línea se vea natural en VR.
5. **Exportar** `guide_path.json`: un punto por metro con altura, ETA acumulado, pendiente, clase de terreno y advertencias.

## Uso

```bash
cd route-planner
source ../mars-route-walker/.venv/bin/activate      # numpy + Pillow
SCENE=../mars-route-walker/viewer-godot/patch_793

# Ruta corta en el parche caminable (1 m, ±45 m), las 3 condiciones + imagen de vista previa
python mars_route.py $SCENE --start 0 0 --goal 40 40 --cond all --png preview.png

# Solo una condición (esto es lo que lee el visor)
python mars_route.py $SCENE --start 0 0 --goal 40 40 --cond normal

# Ruta larga en el anillo de 3 km (6 m/celda, ~15 s por condición)
python mars_route.py $SCENE --layer ring_3km --goal 1800 -1500 --out ring_path.json --png ring.png
```
Coordenadas en metros: **x = este, z = sur**, con origen en el waypoint del rover (las mismas del HUD del visor).

## En el visor (Godot / VR)

`guide_path.gd` es un nodo independiente. Dibuja chevrones en el suelo coloreados por riesgo
(verde = ok, ámbar = pendiente, rojo = rocoso o muy empinado), una baliza con ETA en la meta y una flecha flotante
frente a la vista que apunta 4 m adelante sobre la ruta (o de vuelta a la ruta si te sales a más de 3 m).

1. Copiá `guide_path.gd` a `viewer-godot/` y el `guide_path.json` generado a la carpeta del parche.
2. En `main.gd` (en tu rama, p. ej. `wally/aprendiendo`):
```gdscript
var guide: GuidePath                                   # arriba, con las otras variables

# en _ready(), después de _route():
if FileAccess.file_exists(PATCH + "guide_path.json"):
	guide = GuidePath.new()
	guide.json_path = PATCH + "guide_path.json"
	add_child(guide)

# al final de _process(), después de armar hud.text:
if guide:
	guide.update_player(origin.position, cam.global_basis)
	hud.text += guide.hud_line()
```
Probado en modo headless en Godot 4.7.2: el script carga, calcula la distancia restante y el ETA, y detecta cuando
te salís de la ruta. **Todavía no se probó en el headset.**

## Límites honestos

- El tipo de terreno es una aproximación (rugosidad + brillo), no un mapa geológico. Mejora siguiente: usar el mapa geológico de Jezero (Stack et al. 2020) o la clasificación de terreno de las rutas del rover.
- Las rocas menores a 1 m no aparecen en el DEM. Las rocas del visor son sintéticas, así que la ruta no las esquiva.
- Los parámetros (traje 0.55, 15°/25°, factores de terreno) son supuestos razonables para ajustar; no salen de mediciones.
- El parche caminable mide solo 90 m. Para rutas largas, el anillo de 3 km planifica la ruta general y el parche de 1 m afina el tramo local (planificación jerárquica).

# Capa puntos_interes (Paula) - guia para tu agente

## Que hace
Lee `puntos.json` y pone un **pin** (poste amarillo de 30 m + esfera + nombre) en cada punto, pegado al suelo de Marte.
Para agregar un punto **solo se edita `puntos.json`**; no hay que tocar `layer.gd` ni el nucleo.

## Como agregar un punto
Agrega una linea con las coordenadas reales (lon este positiva, lat norte positiva):

```json
{"nombre": "Muestra Cheyava Falls", "lon": 77.4501, "lat": 18.4440, "texto": "Descripcion que quieras mostrar"}
```

Si en vez de lon/lat tienes metros del mundo (x este, z sur, origen = primer punto de la ruta), usa `"x": -7216.9, "z": -3120.0`.

El sistema convierte solo: `world.lonlat_to_world(lon, lat)` da (x, z) y `world.height_at(x, z)` da la altura del suelo.
El pin se vuelve a pegar al suelo cada 0.5 s porque el terreno carga por distancia.

## Probar
```bash
cd viewer-godot
godot --path . --xr-mode off -- --world=/ruta/al/mundo --layers=puntos_interes --at=X,Z
```
`--at=X,Z` empieza a pie en ese punto del mundo (ponlo unos 100 m antes del pin). En consola sale
`puntos_interes: <nombre> -> x=... z=...` para cada punto: si `x`,`z` caen lejos de la ruta o fuera del mundo, revisa que lon/lat no esten invertidos.

## Siguiente (lo tuyo)
El texto (`"texto"`) ya se carga en el JSON pero aun no se muestra: falta el panel de informacion al acercarse (distancia a `core.origin.global_position` o `core.cam`).
Para cambiar el pin por un modelo 3D: en `layer.gd`, dentro de `_make_pin`, agrega `n.add_child(load("res://layers/puntos_interes/modelo.glb").instantiate())`.

## Reglas
Solo edita esta carpeta. Archivos < 10 MB. Cita la fuente de los datos en este archivo.

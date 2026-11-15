# Capa ingenuity (Paquito) - guia para tu agente

## Que hace
Lee `ingenuity.json` y pone en esas coordenadas: el helicoptero (provisional, caja + palas) y un **pin** cian de 30 m con el nombre, pegados al suelo.
Para mover a Ingenuity **solo se edita `ingenuity.json`**.

## Coordenadas
```json
{"nombre": "Ingenuity", "lon": 77.322539, "lat": 18.497263}
```
lon este positiva, lat norte positiva. Alternativa en metros del mundo (x este, z sur, origen = primer punto de la ruta): `"x": -7216.9, "z": -3120.0`.
Conversion interna: `world.lonlat_to_world(lon, lat)` -> (x, z); `world.height_at(x, z)` -> altura del suelo. Se re-pega al suelo cada 0.5 s porque el terreno carga por distancia.
Ingenuity queda a ~364 m de la ruta (mas cerca: sol 1114), por eso el pin alto: se ve desde el rover.

## Probar
```bash
cd viewer-godot
godot --path . --xr-mode off -- --world=/ruta/al/mundo --layers=ingenuity --at=-7150,-3100
```
`--at=X,Z` empieza a pie en ese punto del mundo. En consola sale `ingenuity: x=... z=...`.

## Siguiente (lo tuyo)
- Mision de rescate: ruta segura a pie desde el rover hasta Ingenuity. Utiles: `world.slope_deg(x, z)` (pendiente), `core.hazard_on`, `world.route_nearest_s(Vector2(px, pz))` (punto de la ruta mas cercano).
- Para varios waypoints, usa la misma idea de `_make_pin` en una lista.

## Reglas
Solo edita esta carpeta. Archivos < 10 MB. Cita la fuente de los datos en este archivo.

## Modelo
`ingenuity.glb`: Ingenuity Mars Helicopter, NASA/JPL (repo nasa/NASA-3D-Resources), copia del cache de Luna Visor. Se escala para que el rotor mida 1.21 m (real) y se apoya en el suelo. Si no carga, usa el helicoptero provisional.

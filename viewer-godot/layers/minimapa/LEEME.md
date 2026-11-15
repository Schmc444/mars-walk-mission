# Capa minimapa

Muestra un tramo (1200 m) de la ruta de Perseverance en gris claro y el rover como un punto naranja que avanza sobre ella.
Lo ya recorrido se ve en gris más oscuro. Norte arriba. Cuando el rover pasa al siguiente tramo, el dibujo se reajusta.

- Pantalla: esquina inferior derecha. VR: panel en la mano izquierda.
- Datos: solo la ruta que ya carga el mundo (`world.route_pos`, `route_length`, `core.ride_s`); no agrega fuentes externas.

Probar: `godot --path viewer-godot --xr-mode off -- --world=<mundo> --sol=1114 --layers=minimapa`

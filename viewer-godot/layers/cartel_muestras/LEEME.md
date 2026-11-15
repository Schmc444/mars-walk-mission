# Capa cartel_muestras

Cartel de información estilo museo, flotando junto a cada muestra. Es independiente de `puntos_interes`: solo lee `puntos.json` (para la posición) y no toca el hueco.

Cargar: `--layers=puntos_interes,cartel_muestras` (sin `--layers` se cargan todas).

## Añadir una muestra (sin tocar código)
Añade una entrada a `muestras.json` con `punto` (el `nombre` exacto de `puntos.json`) o `lon`/`lat`, un bloque `cartel` con los ajustes, `titulo`, `compacto`, `ampliado`, `creditos` y los pies.

## Ajustes (bloque `cartel`)
Tamano: `ancho_compacto_m`, `alto_compacto_m` (tope duro; la letra se reduce hasta caber), `ancho_ampliado_m`, `alto_ampliado_m`, `textura_px_por_m`, tamanos de fuente.
Colocacion: `distancia_hueco_m`, `distancia_min_cabeza_m`, `altura_factor_ojos`, `altura_min_m`, `altura_max_m`, `inclinar`, `inclinacion_max_deg`.
Suavizado y visibilidad: `suavizado_giro_s`, `suavizado_orbita_s`, `suavizado_altura_s`, `dist_min_direccion_m`, `radio_visible_m`, `fundido_m`, `opacidad`.
Modo: `modo_inicial`, `ampliado_activo`, `tecla_modo`, `boton_vr_modo`. Colores: `color_*`.

## Controles
Escritorio: tecla `I` recorre compacto y paginas del modo ampliado (solo si `ampliado_activo` es true). VR: botón de agarre (`grip_click`) de cualquier mano. Solo cambia el cartel que está visible.

Prueba: `--cartel-modo=ampliado` arranca en modo ampliado.

Depuracion: `--cartel-debug-orbita=radio,vel` simula caminar en circulo e imprime el error de orientacion.

# Capa Atmósfera (Kevin, rama `capa/atmosfera`)

Panel lateral con cinco valores de la atmósfera donde está el jugador, cada uno con su color, más una **neblina de colores por zonas**
que se ve de lejos y te rodea cuando entras en la zona. En VR el panel flota pegado a la vista.

## Panel

| Color | Parámetro | Valor que muestra |
|---|---|---|
| Azul | Oxígeno | % del aire (ej. 0.16 %) |
| Verde | Radiación | mSv/día (ej. 0.66 mSv/día) |
| Turquesa | Temperatura | °C del aire a 1.5 m (ej. −58 °C) |
| Amarillo | Presión | Pa (ej. 779 Pa) |
| Rosado | Polvo | opacidad τ (ej. τ 1.54) |

Nada más: sin encabezado, leyenda ni textos extra (pedido de Kevin; se agregan solo si él lo indica).

## Teclas

| Tecla | Qué hace |
|---|---|
| **F1** | Neblina de **polvo** (rosado claro = poco, morado oscuro = mucho) |
| **F2** | Neblina de **radiación** (verde claro = menos, verde oscuro = más) |
| **F3** | Neblina de **oxígeno** (azul claro = más O2, azul oscuro = menos) |
| **F6** | Mostrar u ocultar el panel |
| **F7** | Neblina de **presión** (amarillo claro = más, café oscuro = menos). Las lomas tienen menos presión que las hondonadas |
| **F8** | Neblina de **temperatura** del aire a 1.5 m (turquesa claro = menos frío, turquesa oscuro = más frío) |

Solo hay **una neblina activa a la vez**: F2 con el polvo encendido cambia directo a radiación; repetir la misma tecla la apaga.
El panel muestra siempre los cinco valores al mismo tiempo.

Presión y temperatura cambian muy poco en 3 km (unos 10 Pa y 1-3 °C), así que su escala de color va del 5 % al 95 % de los valores
alrededor del jugador y su neblina de volumen es más tenue: el contraste se ve en el suelo.

**VR:** todavía no hay botones del control asignados. Para asignarlos, llama a `activar(POLVO | RAD | O2 | PRES | TEMP)`
o `alternar_panel()`. Ojo: el núcleo ya usa los botones A/B/X/Y para la capa de peligro de pendiente (H).

## Opciones para probar (después de `--`)

`--atm=polvo|radiacion|oxigeno|presion|temperatura` (empezar con esa neblina) ·
`--atm-sol=316` (forzar un sol, por ejemplo la tormenta DS-1) · `--atm-hora=4` (forzar la hora local, 0-24; si no, sale del sol de la escena) ·
`--atm-panel-3d` (ver el panel flotante como en VR, sin visor).

La escena tiene un sol fijo (del núcleo). La capa lo lee para sacar la hora local aproximada (~08:30) y qué laderas reciben más sol.
Con `--atm-hora` cambian los números y la neblina, pero la luz de la escena sigue igual.

```bash
godot --path viewer-godot --xr-mode off -- --world=/ruta/al/mundo --sol=448 --layers=atmosfera --atm=polvo
```

## Archivos

| Archivo | Qué es |
|---|---|
| `layer.gd` | La capa: teclas, panel (pantalla y VR), mapa de valores alrededor del jugador |
| `modelo.gd` | Las fórmulas y los valores base (con la fuente al lado de cada número) |
| `neblina.gdshader` | La neblina: recorre el rayo de cada píxel por un mapa de 3.2 km × 3.2 km alrededor del jugador, y pinta una capa baja pegada al suelo donde el valor está sobre la mediana del mapa (p50 → p95), para que las zonas se lean sobre el terreno. El color siempre es el valor absoluto de la leyenda |
| `textos.gd` | Textos de justificación de cada número (eran la tecla F5). **No se usa por ahora**; queda por si se vuelven a mostrar |

El mapa de valores son dos texturas: `campo` (R polvo, G radiación, B falta de O2 en 0..1, A altura del suelo) y `campo2` (R presión en Pa,
G temperatura en K, valores reales; el shader los pasa a 0..1 con `rango_local`).

## Qué es real y qué es sintético

| Parámetro | Valor base (real) | Cambio con el sol | Cambio de un lugar a otro |
|---|---|---|---|
| Polvo (τ) | Temporada clara ~0.3-0.4; tormentas DS-1 (sols 312-318, τ ≈ 1.4), DS-A (sols ~417-472, τ ≥ 1), DS-C (sol ~574) | Aproximación a las curvas de MEDA | **SINTÉTICO**: zonas de ráfagas y posición de los remolinos. La cantidad (~2.5 por km² por sol) y el tamaño (5-135 m) sí son de MEDA |
| Radiación | 0.67 mSv/día (RAD, Gale), corregida por presión | Por presión (coeficiente ilustrativo) | **SINTÉTICO**: ±10 % y blindaje de hondonadas |
| Oxígeno | 0.16 % del aire (SAM) | Subida estacional aproximada (SAM midió hasta +30 %) | Por altura (física) + **SINTÉTICO** ±12 % |
| Presión | Ciclo estacional de MEDA (forma aproximada, ~650-780 Pa) | Sí | Por altura (**física**, altura de escala 11.1 km): ~7 Pa menos por cada 100 m |
| Temperatura (aire a 1.5 m) | Ciclo diario de MEDA (forma aproximada): ~ −85 °C de madrugada, ~ −20 °C a las 13:30 en buen tiempo | Estación (±6 K) y polvo (achica la diferencia día-noche), ambos aproximados | **SINTÉTICO con base física**: de día +4 °C en laderas al sol; de noche −5 °C en hondonadas (aire frío); ±1.5 °C de ruido |
| Aire | 95 % CO2, 2.6 % N2, 1.9 % Ar (SAM) | No | No |

En la realidad, el polvo de fondo, la radiación y el oxígeno casi no cambian en pocos kilómetros. Las zonas de colores se ponen
para **ilustrar** cómo se vería un mapa así. Los remolinos de polvo sí son locales de verdad.

## Fuentes

- Hassler et al. 2013, *Science*. RAD/Curiosity: 0.67 mSv/día en la superficie. https://www.swri.org/press-release/swri-scientists-publish-first-radiation-measurements-surface-mars
- NASA OCHMO, NASA-STD-3001: límite de carrera de 600 mSv y tope de 0.8 mSv/día en superficie. https://www.nasa.gov/sites/default/files/atoms/files/ochmo_standards_overview_sept_15_2021_francisco.pdf
- Guo et al. 2017, *JGR Planets*: la dosis baja cuando hay más atmósfera encima. https://arxiv.org/abs/1712.06987
- Trainer et al. 2019, *JGR Planets* (NASA Goddard). SAM: composición del aire y O2 hasta +30 % en primavera/verano. https://www.nasa.gov/missions/with-mars-methane-mystery-unsolved-curiosity-serves-scientists-a-new-one-oxygen/
- Smith et al. 2023, *JGR Planets*, doi:10.1029/2022JE007560. MEDA/TIRS: opacidad del polvo en Jezero.
- Sánchez-Lavega et al. 2025: tormentas DS-1, DS-A y DS-C, y la relación sol ↔ Ls. https://arxiv.org/abs/2501.05337
- Hueso et al. 2023, *JGR Planets*, doi:10.1029/2022JE007516, y Toledo et al. 2023, doi:10.1029/2022JE007494: remolinos en Jezero (1.3-3.4 por km² por sol, 5-135 m).
- Newman et al. 2022, *Science Advances*, doi:10.1126/sciadv.abn3783: vientos y remolinos en Jezero. https://www.nasa.gov/missions/mars-2020-perseverance/perseverance-rover/nasas-perseverance-studies-the-wild-winds-of-jezero-crater/
- Harri et al. 2024, *JGR Planets*, doi:10.1029/2023JE007880. MEDA: presión en Jezero; aterrizaje en Ls ~5°.
- MOXIE (MIT/NASA): O2 producido en Jezero. https://news.mit.edu/2021/aboard-nasa-perseverance-mars-rover-moxie-creates-oxygen-0421 · https://science.nasa.gov/?p=354880
- Munguira et al. 2023, *JGR Planets*, doi:10.1029/2022JE007559. MEDA: temperaturas del aire cerca del suelo en Jezero (ciclo diario, efecto del polvo).
  Los números de `modelo.gd` (`T_MEDIA`, `T_AMPL`, horas del mínimo y del máximo) son una aproximación: conviene compararlos con las figuras del artículo.
- Límite de Armstrong (6.3 kPa): https://en.wikipedia.org/wiki/Armstrong_limit

## Pendiente / no probado

- **No probado en el visor VR.** Se probó en Godot 4.7.2 (renderer Mobile, sin visor) con el mundo real `world-v1` (sol 448) y con
  `--atm-panel-3d`. En VR el shader usa la rama `USE_MULTIVIEW` (profundidad por ojo); si da error en el visor, revisar esa parte de `neblina.gdshader`.
- **Rendimiento** (Intel Iris Xe, 1600×900, con la capa piedras): con cualquier neblina +7-9 ms por frame (~3 ms fijos por leer la profundidad, ~0.25 ms por paso).
  La neblina hace 24 pasos por píxel y solo evalúa los remolinos que cruza el rayo (máx. 4). Si va lento en la Steam Frame, bajar `PASOS` en el shader.
- Si consiguen datos reales (por ejemplo, la tabla de τ de MEDA por sol), se reemplazan las funciones de `modelo.gd`.

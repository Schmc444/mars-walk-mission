# Informe técnico de la capa Atmósfera (inglés, formato IEEE)

**PDF:** [`informe_atmosfera.pdf`](informe_atmosfera.pdf) (7 páginas, en inglés). Fuente LaTeX: [`informe_atmosfera.tex`](informe_atmosfera.tex)
(las referencias van dentro del .tex; [`referencias.bib`](referencias.bib) tiene las mismas entradas).

**Datos: solo de la NASA.** Terreno HiRISE/CTX (Mars 2020 TRN, NASA JPL/USGS), ruta de Perseverance (NASA JPL MMGIS),
**mediciones de MEDA de los sols 1063–1116 bajadas del NASA PDS** (presión, temperatura del aire, infrarrojo del suelo, Sol y posición
del rover), calendario Mars24 (NASA GISS), Mars Fact Sheet (NSSDCA), modelo de NASA Glenn, SAM y RAD (Curiosity), NASA-STD-3001.

**Overleaf:** `informe_overleaf.zip` se genera localmente (no se sube); en Overleaf: *New Project → Upload Project*, compilador pdfLaTeX.

## Contenido

| Sección | Qué calcula / demuestra |
|---|---|
| II. Time | Sol → fecha y Ls con el algoritmo Mars24 de la NASA; hora real del sol de la escena con el ángulo cenital medido por MEDA |
| III. Atmosphere measured by MEDA | Regresión armónica (mínimos cuadrados) de la presión: tendencia estacional + mareas térmicas de 24 h y 12 h. Fórmula barométrica y altura de escala con la temperatura medida. Ciclo diario del aire (ATS) y reajuste del modelo. Temperatura del suelo con Stefan–Boltzmann (TIRS) |
| IV. Point A | Panel de la capa vs. datos de la NASA; Dalton (O₂), blindaje (radiación), Beer–Lambert (polvo), remolinos |
| V. Uncertainty | Propagación de primer orden + Monte Carlo, ahora con la dispersión diaria real de MEDA |
| VI. Terrain | Posición del rover MEDA vs. ruta JPL; diferencias centrales O(Δ²), Richardson, dependencia de la escala; ley del coseno de Lambert |
| VII. Routes | Costo J = ∫c ds, A*, dosis, sensibilidad al peso de la exposición y al límite de pendiente |

## Resultados principales (validación con MEDA, sols 1063–1116, 51 sols con datos)

| Magnitud | Capa | NASA |
|---|---|---|
| Ls en el sol 1063 | 203.07° | 200.06° (Mars24) |
| Presión en A (08–09 h) | 744.67 Pa | 691.63 Pa |
| Subida estacional de la presión | 0.45 Pa/sol | 1.61 Pa/sol (680.5 → 765.1 Pa) |
| Temperatura del aire en A | 212.0 K | 221.9 K |
| Ciclo diario del aire | 33 K de amplitud | 198.9–253.5 K (amplitud reajustada 25.5 K) |
| Altura de escala | 11.10 km | 11.34 km (con T de MEDA) |

- Tendencia + 2 armónicos explican el **93.5 %** de la variación de la presión; la dispersión de un día a otro es **3.98 Pa**
  (antes se suponían 15 Pa).
- El terreno sube 13.5 m de A a B: solo **0.81 Pa** por la fórmula barométrica, frente a 84.6 Pa de cambio estacional.
- El suelo a mediodía está **11.4 K más caliente que el aire** y de madrugada 2.8 K más frío (TIRS): respalda la vista térmica.
- Rutas (terreno HiRISE): la recta es inviable (18°), la óptima mide 335 m, no hay camino con pendientes ≤ 9°.

## Cómo regenerar los datos y el PDF

```bash
# 1) datos de la capa (CSV en informe/datos/): mismas funciones que el panel
cd viewer-godot
godot --path . --xr-mode off -- --world=../world --sol=1063 --layers=atmosfera --atm-analisis

# 2) datos de MEDA desde el NASA PDS (unos 800 MB en streaming; guarda solo promedios por hora) y comparación
cd layers/atmosfera/informe/meda
python meda_bajar.py ../datos/meda_horario.csv 1063 1116
python analisis_meda.py            # escribe datos/meda_por_sol.csv, meda_ciclo.csv, meda_resumen.txt

# 3) PDF (MiKTeX o TeX Live: IEEEtran, pgfplots)
cd ..
latexmk -pdf informe_atmosfera.tex
```

Las gráficas las dibuja `pgfplots` directamente desde los CSV, así que el PDF se actualiza al recompilar.

## Pendiente

- Completar el nombre del autor y la institución en `informe_atmosfera.tex` (texto de ejemplo en cursiva).
- Recalibrar la capa con MEDA (tendencia y mareas de presión, temperatura reajustada, Ls con Mars24).

# Informe técnico de la capa Atmósfera

**PDF:** [`informe_atmosfera.pdf`](informe_atmosfera.pdf) (formato IEEE, 5 páginas). Fuente LaTeX: [`informe_atmosfera.tex`](informe_atmosfera.tex),
referencias en [`referencias.bib`](referencias.bib) (títulos, autores y DOI verificados en Crossref y arXiv).

## Contenido

| Sección | Qué calcula |
|---|---|
| II. Tiempo | Sol → longitud solar Ls (interpolación entre anclas publicadas); hora local a partir de la elevación del sol de la escena |
| III. Modelo físico (punto A, sol 1063) | Presión: serie de Fourier de 2 armónicos + fórmula barométrica (deducción de H = RT/Mg). Oxígeno: fracción de SAM y presión parcial (Dalton). Radiación: dosis de RAD con blindaje por presión. Temperatura: ciclo diario de MEDA. Polvo: Beer–Lambert y densidad de remolinos según la hora |
| IV. Derivadas | Diferencias centrales (error O(Δ²)), pendiente = arctan‖∇h‖ (tecla H del núcleo), respuesta en frecuencia del derivador (jω·sinc), ley del coseno de Lambert |
| V. Visualización | Neblina como suma de Riemann de la integral de extinción; inversa del tonemapping ACES |
| VI. Rutas | Polilínea (rectas tangentes/secantes), función de costo J = ∫c ds, búsqueda A* con restricción de pendiente ≤ 15°, comparación ruta real / recta / óptima |
| VII. Variables de estado | Filtro de un polo del panel VR y del sonido (polos en z), lazo PI propuesto para el traje |

## Resultado principal (tramo sol 1063 → 1116)

| Camino | Largo | Costo J | Pendiente máx. |
|---|---|---|---|
| Ruta real de Perseverance | 477 m | 1091 | 11.0° |
| Recta A → B | 320 m | 767 | **18.0°** (no factible) |
| Óptima (A*) | 335 m | **752** | 11.3° |

La radiación, el oxígeno y el polvo varían de forma sintética de un lugar a otro, así que la comparación ilustra el método; la ruta
real responde además a objetivos científicos que el costo no incluye.

## Cómo regenerar los datos y el PDF

```bash
# 1) datos (CSV en informe/datos/): mismas funciones que el panel de la capa
cd viewer-godot
godot --path . --xr-mode off -- --world=../world --sol=1063 --layers=atmosfera --atm-analisis

# 2) PDF (MiKTeX o TeX Live: IEEEtran, babel-spanish, pgfplots)
cd layers/atmosfera/informe
latexmk -pdf informe_atmosfera.tex
```

Los gráficos de rutas y pendientes los dibuja `pgfplots` directamente desde los CSV, así que si cambian los datos, el PDF se actualiza al recompilar.

## Pendiente

- Completar el nombre del autor y la institución en `informe_atmosfera.tex` (están como texto de ejemplo en cursiva).
- Reemplazar las aproximaciones por los datos de MEDA de los sols 1063–1116 cuando se descarguen del PDS.

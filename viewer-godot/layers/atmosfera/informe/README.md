# Informe técnico de la capa Atmósfera

**PDF:** [`informe_atmosfera.pdf`](informe_atmosfera.pdf) (formato IEEE, 6 páginas). Fuente LaTeX: [`informe_atmosfera.tex`](informe_atmosfera.tex),
referencias en [`referencias.bib`](referencias.bib): 21 fuentes, 12 de ellas de la NASA o de sus instrumentos (MEDA, RAD, SAM, MOXIE, NASA-STD-3001, NSSDCA, NASA Glenn, PDS), verificadas en Crossref, arXiv y nasa.gov.

**Overleaf:** `informe_overleaf.zip` se genera localmente (no se sube); en Overleaf: *New Project → Upload Project*, compilador pdfLaTeX.

## Contenido

| Sección | Qué calcula / demuestra |
|---|---|
| II. Tiempo | Sol → longitud solar Ls (interpolación); hora local con trigonometría esférica a partir de la elevación del sol |
| III. Modelo físico (punto A, sol 1063) | Presión: serie de Fourier (armónico anual y semestral) + fórmula barométrica deducida del equilibrio hidrostático y el gas ideal (H = RT/Mg). Oxígeno: ley de Dalton. Radiación: blindaje por la masa de la columna de aire. Temperatura: ciclo diario de MEDA. Polvo: Beer–Lambert deducida de dI = −κI ds; densidad de remolinos según la hora |
| IV. Incertidumbre | Propagación de primer orden (derivadas parciales) verificada con Monte Carlo (20 000 muestras) |
| V. Terreno | Diferencias centrales con error O(Δ²) por Taylor, extrapolación de Richardson, la diferencia central como pendiente media (teorema fundamental del cálculo) y su dependencia de la escala; ley del coseno de Lambert |
| VI. Rutas | Polilínea, costo J = ∫c ds, A* (admisibilidad), dosis como integral en el tiempo, sensibilidad al peso de la exposición y al límite de pendiente |

## Resultados principales

- **Incertidumbre:** presión en A = 744.7 ± 14.8 Pa (Monte Carlo: ± 14.8). La altura de escala aporta solo 0.6 Pa; el error lo domina la
  presión de la estación, así que lo que más mejoraría el modelo son los datos diarios de MEDA. Dosis 0.69 ± 0.13 mSv/día (domina RAD).
- **Pendiente:** en terreno suave converge como O(Δ²) (Richardson: 9.14° en A). Junto a un escarpe vale 33.5° con Δ = 0.5 m y 1.6° con
  Δ = 16 m: la pendiente depende de la escala.
- **Rutas (sol 1063 → 1116):**

| Camino | Largo | Costo J | Pendiente máx. |
|---|---|---|---|
| Ruta real de Perseverance | 477 m | 1091 | 11.0° |
| Recta A → B | 320 m | 767 | **18.0°** (no factible) |
| Óptima (A*) | 335 m | **752** | 11.3° |

  No existe camino con pendientes ≤ 9°; con 10° mide 369 m. Cambiar el peso de la exposición casi no cambia la ruta: en 300 m la
  atmósfera es casi uniforme, así que la ruta la deciden el terreno y la distancia. La dosis de la caminata (0.0025 mSv) depende del
  tiempo, no del camino.

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

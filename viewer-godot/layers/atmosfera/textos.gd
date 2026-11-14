extends RefCounted
# Textos de justificacion (tecla F5). Resumen propio de las fuentes; referencias completas en LEEME.md.

const GENERAL := """[b]Cómo leer estos números[/b]
Los valores base salen de instrumentos de la NASA en Marte (MEDA y MOXIE en Perseverance; RAD y SAM en Curiosity).
La variación con el sol (estación) es una aproximación a las curvas publicadas.
La variación de un lugar a otro es [color=#ffb347]SINTÉTICA[/color] (ilustrativa): en la realidad casi no cambia en pocos km, salvo los remolinos de polvo y la presión por la altura."""

const POLVO := """[b]Polvo: por qué estos números[/b]
• τ (opacidad óptica): MEDA/TIRS, Mastcam-Z y SkyCam la miden a diario en Jezero (Smith et al. 2023, JGR Planets).
• Tormentas del año marciano 36: DS-1 en sols 312-318 llegó a τ ≈ 1.4; DS-A con τ ≥ 1 en sols ~417-472 (Sánchez-Lavega et al. 2025).
• Remolinos: en Jezero se forman ~1.3-3.4 por km² cada sol, con diámetros de 5 a 135 m (Toledo et al. 2023; Hueso et al. 2023). Son los más frecuentes vistos por una misión.
• "% de luz bloqueada" = 1 − e^(−τ): la luz directa del Sol que no llega (con el Sol en lo alto).
[color=#ffb347]SINTÉTICO:[/color] dónde están los remolinos y las zonas de ráfagas."""

const RADIACION := """[b]Radiación: por qué estos números[/b]
• RAD (Curiosity) midió en promedio 0.67 mSv/día de rayos cósmicos en la superficie (Hassler et al. 2013, Science).
• Menos aire encima = menos blindaje: la dosis sube cuando baja la presión (Guo et al. 2017). Jezero está más alto que Gale.
• Riesgo: NASA-STD-3001 pide mantener los rayos cósmicos bajo 0.8 mSv/día en sistemas de superficie, y fija 600 mSv como límite de carrera de un astronauta.
• Paredes y hondonadas tapan parte del cielo y bajan la dosis (RAD lo estudia en Gale).
[color=#ffb347]SINTÉTICO:[/color] el mapa local (±10 %) y el efecto de las hondonadas."""

const OXIGENO := """[b]Oxígeno: por qué estos números[/b]
• SAM (Curiosity): el aire de Marte es 95 % CO2, 2.6 % N2, 1.9 % Ar y solo 0.16 % O2 (Trainer et al. 2019, NASA Goddard).
• El O2 subió hasta un 30 % en primavera y verano, sin explicación aún.
• Presión parcial de O2 en Marte ≈ 1 Pa; en la Tierra, a nivel del mar, ≈ 21 200 Pa. Sin traje es letal.
• MOXIE (Perseverance) sacó O2 del CO2 en Jezero: hasta ~12 g/h, 122 g en total (NASA/MIT).
[color=#ffb347]SINTÉTICO:[/color] las zonas con más o menos O2 (±12 %). La parte por altura sí es física."""

const PRESION := """[b]Presión[/b]
• MEDA mide la presión en Jezero: cambia con la estación (dos mínimos al año) porque el CO2 se congela en los polos (Harri et al. 2024).
• Baja con la altura: la atmósfera de Marte pierde la mitad de la presión cada ~7.7 km (altura de escala ~11.1 km). Esta parte del mapa es [b]física[/b], no sintética: las lomas tienen menos presión que las hondonadas.
• En pocos km la diferencia es de decenas de Pa, por eso la escala de color (F7) se centra en el lugar donde estás.
• Límite de Armstrong: 6.3 kPa. Por debajo, los líquidos del cuerpo hierven a 37 °C. En Marte hay ~0.7 kPa: hace falta traje presurizado."""

const TEMPERATURA := """[b]Temperatura: por qué estos números[/b]
• MEDA (sensores ATS) mide el aire a ~1.5 m en Jezero: de madrugada baja a cerca de −85 °C y después del mediodía sube a cerca de −20 °C (Munguira et al. 2023, JGR Planets). Aquí se usa una forma aproximada de esa curva.
• El aire es tan delgado que guarda muy poco calor: por eso la diferencia entre el día y la noche es de ~60 °C.
• Con polvo en el aire el día se enfría y la noche se calienta (la diferencia se achica); MEDA lo vio en las tormentas.
• La hora sale del sol de la escena (o de --atm-hora).
[color=#ffb347]SINTÉTICO (con base física):[/color] de día, las laderas que miran al sol se calientan más; de noche, el aire frío baja a las hondonadas; más ±1.5 °C de ruido."""

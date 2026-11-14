# Guía para el equipo: cómo agregar tu capa sin pisar a los demás

El **núcleo** (mapa, carga del mundo, movimiento del rover, video) lo hacen Santiago y Claude. Cada compañero construye **una capa** encima. Si todos respetan las reglas de abajo, los cinco trabajos se juntan al final sin conflictos.

| Capa | Carpeta | Qué hace |
|---|---|---|
| Puntos de interés | `viewer-godot/layers/puntos_interes/` | Paneles de información donde Perseverance tomó muestras |
| Ingenuity | `viewer-godot/layers/ingenuity/` | Misión de rescate: ruta segura a pie considerando peligros |
| Minimapa y brújula | `viewer-godot/layers/minimapa/` | Minimapa en la mano y brújula basada en el sol |
| Atmósfera | `viewer-godot/layers/atmosfera/` | Superposición de CO2, radiación y oxígeno |

(Si tu capa tiene otro nombre, usa otra carpeta; el nombre de la carpeta es el nombre de la capa.)

## Las 5 reglas

1. **Una rama por capa.** Nunca trabajes en `main` ni en `foundation`. Tu rama se llama `capa/<nombre>` (ejemplo: `capa/minimapa`) y sale de `foundation`.
2. **Solo edita tu carpeta** `viewer-godot/layers/<tu_capa>/`. No cambies `main.gd`, `world.gd`, `terrain.gdshader` ni `marswalk/`. Si necesitas algo del núcleo, pídelo (ver "Pedir algo al núcleo").
3. **Commits pequeños y seguidos**, con mensaje en español que diga qué hiciste.
4. **Antes de abrir el Pull Request**, trae lo nuevo de `foundation` a tu rama y prueba que todo sigue abriendo.
5. **El merge lo hace Santiago** (o quien él indique) desde un Pull Request en GitHub. Nadie hace merge directo a `foundation` o `main`.

## Paso a paso con Git (terminal)

```bash
git clone https://github.com/Schmc444/mars-route-walker.git
cd mars-route-walker
git checkout foundation
git checkout -b capa/minimapa            # tu rama (cambia el nombre)

mkdir -p viewer-godot/layers/minimapa
cp viewer-godot/layers/_plantilla/layer.gd viewer-godot/layers/minimapa/layer.gd
# ... edita layer.gd y agrega tus archivos en esa carpeta ...

git add viewer-godot/layers/minimapa
git commit -m "Minimapa: dibuja la ruta en la mano"
git push -u origin capa/minimapa
```

Para traer lo nuevo del núcleo mientras trabajas:

```bash
git fetch origin
git merge origin/foundation              # si pregunta por un mensaje, guarda y cierra
```

Luego en GitHub: **Pull requests → New pull request**, base `foundation`, compare `capa/minimapa`. Describe qué hace tu capa y cómo probarla.

### Sin terminal (GitHub Desktop, la web o Gemini)

- **GitHub Desktop:** *Current Branch → New Branch*, nombre `capa/<nombre>`, "based on" `foundation`. Agrega tus archivos a `viewer-godot/layers/<tu_capa>/`, escribe el resumen del commit, **Commit** y luego **Push origin**. El botón **Create Pull Request** abre la página de GitHub.
- **Web de GitHub:** botón de ramas → escribe `capa/<nombre>` → *Create branch*. Luego *Add file → Upload files* en tu carpeta y *Commit changes* a **tu rama** (no a `foundation`).
- **Con Gemini u otra IA:** pásale esta página y `viewer-godot/layers/_plantilla/layer.gd`, y dile que el resultado debe ser un solo `layer.gd` (y archivos extra) dentro de tu carpeta. Los nombres de las funciones de la lista de abajo son exactos.
- Si no tienes permiso para crear ramas en el repo, haz un **Fork** y manda el Pull Request desde tu fork hacia `foundation`.

## Cómo es una capa

Una capa es un script de Godot (GDScript) en `viewer-godot/layers/<nombre>/layer.gd`. El visor lo encuentra solo: no hay que registrarlo en ningún lado. Empieza copiando `layers/_plantilla/layer.gd` (las carpetas que empiezan con `_` se ignoran).

El visor llama a `setup(world, core)` una vez al cargar. Después tu script funciona como cualquier nodo de Godot (`_process`, `add_child`, etc.).

**`world`** (el mundo):

| Función | Devuelve |
|---|---|
| `world.height_at(x, z)` | altura del suelo en metros |
| `world.slope_deg(x, z)` | pendiente en grados |
| `world.lonlat_to_world(lon, lat)` | `Vector2(x, z)` en metros |
| `world.world_to_lonlat(x, z)` | `Vector2(lon, lat)` |
| `world.route_length()` | largo de la ruta en metros |
| `world.route_pos(s)` | `Vector2(x, z)` a `s` metros por la ruta |
| `world.route_sol_at(s)` | sol (día marciano) en esa posición |
| `world.route_s_of_sol(sol)` | metros de ruta donde empieza ese sol |
| `world.route_nearest_s(Vector2(x, z))` | punto de la ruta más cercano a un lugar |

**`core`** (el visor): `core.origin` (el jugador, usa `core.origin.global_position`), `core.cam` (cámara), `core.left` y `core.right` (controles de las manos, para pegar cosas en la mano), `core.ride_s` (metros recorridos), `core.riding` (¿va en el rover?), `core.sun_dir_xz` (hacia dónde viaja la luz del sol), `core.hazard_on` (capa de peligro).

**Convenciones:** todo en metros. `x` = este, `z` = sur, `y` = arriba. El origen (0, 0) es el primer punto de la ruta. Las coordenadas reales son lon/lat de Marte (este positivo); conviértelas con `world.lonlat_to_world`.

Ejemplo, un marcador en las coordenadas de Ingenuity (18.497263 N, 77.322539 E):

```gdscript
var p := world.lonlat_to_world(77.322539, 18.497263)
marcador.position = Vector3(p.x, world.height_at(p.x, p.y), p.y)
```

## Probar tu capa

Necesitas el **mundo** (tiles del terreno, ~626 MB; no está en git). Pídeselo a Santiago, o genéralo:

```bash
pip install -e .
python tools/fetch_band.py --out band          # descarga ~720 MB de datos HiRISE (tarda)
python tools/build_world.py --band band --out world
```

Y abre el visor (Godot 4.7.2, sin visor VR agrega `--xr-mode off`):

```bash
cd viewer-godot
godot --path . --xr-mode off -- --world=/ruta/al/mundo --sol=1114
```

Opciones útiles después de `--`: `--sol=N` (empezar en ese sol), `--at=x,z` (empezar a pie en un punto), `--layers=minimapa` (cargar solo tu capa), `--shot=foto.png` (una captura y salir).
Controles: **W/S** avanza o retrocede en el rover, **G** bajar/subir del rover, **Shift** correr a pie, **H** capa de peligro, **clic derecho + ratón** mirar, **Esc** salir. En VR: stick izquierdo = velocidad, stick derecho = giro.

## Pedir algo al núcleo

Si tu capa necesita una función que no está en la lista (por ejemplo, saber si el jugador va en el rover, o dibujar texto en el HUD), **no edites el núcleo**: abre un *Issue* en GitHub o escríbele a Santiago con lo que necesitas. Se agrega a `foundation` y tú traes los cambios con `git merge origin/foundation`.

## Reglas de convivencia

- No subas archivos grandes (>10 MB), mundos ni datos descargados. El `.gitignore` ya excluye `world/` y `band/`.
- No subas claves, tokens ni contraseñas.
- Si usas datos o imágenes de fuera, anota la fuente en un `LEEME.md` dentro de tu carpeta (los datos de la competencia deben poder rastrearse).
- Si algo se rompe, avisa antes de "arreglar" archivos que no son tuyos.

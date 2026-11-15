# Empezar a probar (Linux / macOS / Windows)

Necesitas: **Git**, **Python 3.10+** y **Godot 4.7.2** (versión estándar, no .NET). Internet para generar escenas (los datos de HiRISE se leen por HTTP, no hay que descargar nada a mano).

## 1. Instalar

```bash
git clone https://github.com/Schmc444/mars-walk-mission.git
cd mars-walk-mission
git checkout foundation        # rama con el generador `marswalk`

python3 -m venv .venv
source .venv/bin/activate      # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .               # instala numpy, pillow y el comando `marswalk`
python -m pytest tests -q      # opcional: pip install pytest antes
```

Godot: descarga 4.7.2 de https://godotengine.org/download/archive/4.7.2-stable/ . No requiere instalación; en los comandos de abajo `godot` es el ejecutable que descargaste (ruta completa si no está en el PATH).

## 2. Ver una escena que ya viene hecha

```bash
cd viewer-godot
godot --path . -- --patch=patch_793        # Jezero, sol 793
godot --path . -- --patch=scene_olympus    # faldas de Olympus Mons
```

Controles: WASD para caminar, ratón para mirar, H alterna la capa de peligro por pendiente.

## 3. Escoger un sitio y generar tu propia escena

1. Abre `docs/sites.html` en el navegador: mapa y tabla de los 1,104 sitios HiRISE (filtros, orden por área/resolución). Copia el **ID** del sitio.
2. Genera la escena:

```bash
marswalk build --site <ID> --out viewer-godot/mi_escena
```

El origen se elige solo, pero en sitios con huecos de datos puede fallar con `no valid DTM patch found`. En ese caso da tú la coordenada (lon/lat, grados este, de la tabla o de `marswalk find`):

```bash
marswalk find -- -133.32 17.28             # qué DTM cubren un punto
marswalk build --site <ID> --lon -133.3246 --lat 17.2845 --out viewer-godot/mi_escena
```

Tarda de 2 a 5 minutos (lee la ortofoto de ~1.3 GB por rangos HTTP). Termina con `... OK` si la validación pasó.

3. Míralo:

```bash
cd viewer-godot
godot --path . -- --patch=mi_escena
```

Para escenas de rover (Perseverance) en vez de HiRISE arbitrario: `marswalk build <sol> <site> <drive> --out viewer-godot/mi_escena`.

## 4. Otros comandos

| Comando | Qué hace |
|---|---|
| `marswalk layers` | lista las capas disponibles |
| `marswalk build ... --layers terrain,ortho` | genera solo esas capas |
| `marswalk validate <carpeta>` | comprueba una escena contra su `scene.json` |
| `marswalk index` | reconstruye `data/hirise_dtm_index.json` (lento) |

Formato de escena: `docs/SCENE_FORMAT.md`. Cada capa es un plugin `@layer(...)` en `marswalk/layers.py`.

## 5. Problemas conocidos

- Algunos sitios tienen mucho nodata: el parche válido puede estar lejos del centro; usa `--lon/--lat`.
- La mayoría del horizonte en sitios HiRISE viene del mapa global de 200 m, se ve borroso a lo lejos. Las texturas de los anillos (foto en gris sobre el relieve lejano) vienen de los mosaicos CTX de Robbins y solo existen entre 30°S y 30°N; fuera de eso el anillo queda de un solo color.
- Las ortofotos de varios sitios son de un solo canal (gris).
- Sitios polares (156) no están soportados.
- Parches viejos (`patch`, `patch_793`) tienen ~5% de estiramiento este-oeste; las escenas nuevas generadas con `marswalk` no.
- Si `git push` o el ruteo te pide credenciales, el repo es privado: hay que ser colaborador.

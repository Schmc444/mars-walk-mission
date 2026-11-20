# Mars Walk Mission

**NASA Space Apps Challenge 2026 · *Interplanetary Survival Guide: Martian Map***

Plan a route on Mars, then walk it. Mars Walk Mission turns real orbital data around the Perseverance rover's
traverse (Jezero Crater) into a first-person scene you can explore on a desktop or in VR (OpenXR, tested on
Steam Frame). You pick a destination, the planner finds the safest path over the terrain, and you follow it on foot.

![status](https://img.shields.io/badge/status-hackathon_prototype-orange)

**Demo video:** https://youtu.be/2VvJ5GXO3KE

## What it does

- **Walkable Mars.** 1 m terrain and the distant crater rim and mountains come from real elevation data; the ground
  is textured with real orbital imagery.
- **Safe route planning** (`route-planner/`). Terrain classes (slope, dunes, hazards) are weighed to find the safest
  walkable path to a destination such as Ingenuity's crash site; the route is drawn on the ground as chevrons.
- **Layers** (`viewer-godot/layers/`), each one a self-contained module:
  - `ruta`: route following, rover on rails, recording and replay of a session
  - `minimapa`: live minimap of the traverse with the player's position
  - `atmosfera`: oxygen, radiation, temperature, pressure and dust panel plus false-colour views of each variable,
    shaded with the terrain relief so mountains stay recognisable
  - `puntos_interes`: sample sites (e.g. Comet Geyser) with information panels
  - `ingenuity`: Ingenuity helicopter and its location
  - `ruta_punteada`, `piedras`, `cartel_muestras`, `camara`: dotted traverse line, rocks, sample signs, camera helpers
- **VR menu**: pick saved destinations, recalculate or clear the route, toggle the minimap.

## Quick start

1. Install **Godot 4.7.2** (standard build): https://godotengine.org
2. Clone this repo. The showcase patch `viewer-godot/patch_793` (sol 793, Jezero) is included, so this works with no download:
   ```bash
   cd viewer-godot
   godot --path . -- --patch=patch_793
   ```
3. For the full world (Perseverance traverse, sols 0-1599, 610 MB):
   ```bash
   python tools/get_world.py          # downloads release world-v1 into ./world (needs zstd or Python >= 3.14)
   godot --path viewer-godot --xr-mode off -- --world=../world --sol=1114
   ```

**Controls (desktop):** W/A/S/D move, Shift run, right mouse look, H cycle slope and atmosphere overlays, Esc quit.
**VR:** left stick moves, right stick turns, left grip or stick click opens the menu, right trigger selects.

Useful flags (after `--`): `--patch=<folder>`, `--world=<folder>`, `--sol=<n>`, `--norover`, `--shot=out.png`
(render one frame and exit), `--sin-pines` (hide the tall location pins, handy for renders).
`--espejo` serves the headset view as MJPEG at `http://<device-ip>:8090/` so it can be projected from a browser (`--espejo-fps=N`, `--espejo-ancho=N`, `--espejo-puerto=N`).

## Repository map

| Folder | Contents |
|---|---|
| `viewer-godot/` | Godot 4.7 viewer, shaders, layers, patches (`patch_793` is the showcase) |
| `route-planner/` | Python route planner over terrain-class grids |
| `pipeline/`, `tools/`, `marswalk/` | Scripts that cut terrain patches and build the world from NASA/USGS data (HTTP range reads, no GDAL) |
| `data/`, `reference/` | A first test patch (sol 448) and a real Mastcam-Z photo used to compare the render |
| `docs/` | `PIPELINE.md` (how it all works), `SCENE_FORMAT.md`, `EQUIPO.md` and `WORKFLOW.md` (team notes, in Spanish) |

`tools/frame/make_bundle.sh` builds a bundle for running the viewer natively on a Steam Frame.

## A note on language

The README and the user-facing docs are in English so the project can be read by the wider Space Apps community.
The code was written by a Spanish-speaking team, so folder, layer and file names (`atmosfera`, `puntos_interes`,
`ruta`, `EQUIPO.md`), code comments and commit messages are in Spanish. Each layer folder name is the layer name, and
the team notes in `docs/` are in Spanish on purpose. If you contribute, either language is fine for issues and PRs.

## Honest status

- Terrain shape and the distant crater and mountains are **real data**. Ground texture is real 25 cm orbital imagery
  near the rover and grayscale orbital imagery farther out.
- **Colour is a hand-tuned tint**, not measured. **Rocks and pebbles are procedural.**
- Atmosphere values (oxygen, radiation, temperature, pressure, dust) are a **model for illustration**, not measurements.
- Only Perseverance/Jezero waypoints are supported. VR frame rate has not been formally benchmarked.
- The Ingenuity and Perseverance 3D models are simplified rover/helicopter models; check their provenance before reusing them.

## Credits

**Team (NASA Space Apps 2026, TEC Cartago):** Paula Ramírez Vilchez, Daniela Pacheco Naranjo, Sebastián Meneses Castillo,
Kevin Bogantes Durán, Santiago Chacón Castillo.

**Data:** USGS/JPL Mars 2020 TRN HiRISE and CTX mosaics; NASA/JPL MMGIS (waypoints, traverse); ESA HRSC + NASA MOLA blended
DEM; Robbins CTX quad mosaics. **Audio:** NASA/JPL-Caltech SuperCam microphone recordings (details in
`viewer-godot/audio/CREDITOS.md`). **Engine:** Godot (MIT).

Each team member owns one layer under `viewer-godot/layers/` (see `docs/EQUIPO.md`); the git history shows who
contributed what. Third-party assets keep their own credits (for example `viewer-godot/audio/CREDITOS.md`).

## License

Code is released under the MIT License (see [LICENSE](LICENSE)). NASA, USGS and ESA data and recordings keep their
own terms; NASA imagery and audio are generally public domain, with credit.

# Mars Route Walker

NASA Space Apps 2026, *Interplanetary Survival Guide: Martian Map*. Turns a Perseverance rover waypoint into a
walkable first-person Mars scene (desktop and OpenXR/VR), built from real orbital elevation and imagery.

![status](https://img.shields.io/badge/status-hackathon_prototype-orange)

## Quick start (viewer only)

1. Install **Godot 4.7.2** (standard build): https://godotengine.org
2. Clone this repo; the showcase scene `viewer-godot/patch_793` (sol 793, Jezero) is included.
3. Run:
   ```bash
   cd viewer-godot
   godot --path . -- --patch=patch_793
   ```

Controls: **W/A/S/D** move, **Shift** run, **right mouse** look, **H** slope hazard layer, **Esc** quit. In VR: left stick moves, right stick snap-turns.

Useful flags (after `--`): `--patch=<folder>`, `--cam=az,el,vfov`, `--norover`, `--shot=out.png` (render one frame and exit).

## What is in here

| Folder | Contents |
|---|---|
| `pipeline/` | Python scripts that cut a patch and far-field rings from NASA/USGS data (HTTP range reads, no GDAL) |
| `viewer-godot/` | Godot 4.7 viewer, terrain/rock/pebble shaders, patches (`patch_793` = showcase, `patch` = sol 448 default) |
| `data/` | First test patch (sol 448) |
| `reference/` | Real Mastcam-Z photo used to compare the render |
| `docs/PIPELINE.md` | **How it all works**, coordinates, every stage, how to build a new scene, known limits |

Start with [`docs/PIPELINE.md`](docs/PIPELINE.md).

## Honest status

- Terrain shape (1 m) and the distant crater and mountains are **real data**. Ground texture is real 25 cm orbital imagery near the rover and grayscale orbital imagery farther out.
- **Colour is a hand-tuned tint**, not measured. **Rocks and pebbles are procedural** and labelled synthetic in the HUD.
- Only Perseverance/Jezero waypoints are supported. VR frame rate and the hazard layer are not validated.

## Credits

USGS/JPL Mars 2020 TRN HiRISE and CTX mosaics, NASA/JPL MMGIS (waypoints, traverse), ESA HRSC + NASA MOLA blended DEM, Robbins CTX quad mosaics. Godot Engine (MIT).

## Steam Frame (native, untested)

`tools/frame/make_bundle.sh` builds a tarball with Godot 4.7.2 arm64 and the viewer. Copy it to the Frame, unpack, run
`./install.sh`, then `~/mars/mars-flat.sh` (window) or `~/mars/mars-xr.sh` (VR). Not yet verified on the headset.

# How the pipeline works

Goal: take one rover waypoint (a sol/site/drive from the Perseverance route) and turn it into a first-person Mars
scene you can walk around in, on desktop or in VR. Everything is built from real orbital data except the
small-scale clutter (rocks, pebbles, dust), which is procedural.

```
 source adapter      normalize          derive        enrich            synthetic detail      viewer
 (NASA/USGS data) -> (cut to a patch) -> (slope)  ->  (orbital albedo) -> (rocks, pebbles)  -> Godot
```

## 0. Coordinates and conventions (read this first)

- The scene origin is the rover waypoint. **x = east, z = south, y = up**, all in metres.
- A heightmap's row 0 is the northern edge. Heights are stored **relative to the waypoint's own elevation**
  (`center_elevation_m` in `meta.json` holds the absolute value), so the rover stands at y = 0.
- The source maps use an equirectangular projection on a Mars sphere of radius `R = 3396190 m`:
  `x = R * lon_rad`, `y = R * lat_rad`. That is why every script has `R = 3396190.0`.
- Mars curvature matters: the horizon at 1.7 m eye height is only about 3.4 km away (`d = sqrt(2*R*h)`).
  Mountains are still visible beyond that if they are tall enough, which is why the far rings exist.

## 1. Source adapter: where the data comes from

| Data | What it is | How it is read |
|---|---|---|
| HiRISE DTM, 1 m | Elevation, USGS/JPL Mars 2020 TRN mosaic (~1.8 GB) | Local file in `MARS_DATA` |
| HiRISE ortho, 25 cm | Grayscale orbital photo, same mosaic family | HTTP range requests |
| CTX ortho, 6 m | Wider-area grayscale photo | HTTP range requests |
| HRSC+MOLA blend DEM, 200 m | Global elevation (for the 80 km ring) | HTTP range requests |
| Robbins CTX quad MC13, 100 m | Global grayscale mosaic (for the 80 km ring texture) | Downloaded once (667 MB, compressed TIFF, read with Pillow) |
| `M20_waypoints.json`, `M20_traverse.json` | NASA/JPL MMGIS rover waypoints and driven route | Local files in `MARS_DATA` |

`pipeline/bigtiff_range.py` (`RemoteBigTiff`) is the trick that makes this practical: it reads a small window out of a
huge **uncompressed** TIFF or BigTIFF by asking the server only for the bytes it needs (HTTP `Range` requests),
so no multi-GB download is needed. It supports 8/16-bit and int16/float32, stripped or tiled files.
It does **not** support compressed TIFFs; that is why the MC13 mosaic is downloaded and opened with Pillow instead.

`MARS_DATA` (env var, default `../mars_data/`) must contain the DTM `.tif`, `M20_waypoints.json` and `M20_traverse.json`.

## 2. Normalize: cut the scene

Run from `pipeline/`. `<sol> <site> <drive>` identify the waypoint (shown in the Mars Trek popup, or in `M20_waypoints.json`).

| Script | Output (in the patch folder) | What it does |
|---|---|---|
| `patch.py <sol> <site> <drive> [size_m=100] [out]` | `heightmap.f32`, `ortho.png`, `route_local.json`, `meta.json` | Walkable patch. 1 m DTM (size+1 samples square), 25 cm ortho at 4x per metre, the driven route converted to local metres, plus metadata |
| `farfield.py <sol> <site> <drive> [half_km=3] [factor=6]` | `farfield.f32/.json` | 3 km half-width ring from the 1 m DTM averaged down by `factor` (6 m/sample) |
| `farfield.py ... 6 12` | `farfield6.f32/.json` | 6 km ring at 12 m/sample (viewer skips its inner 3 km) |
| `farfield_global.py <sol> <site> <drive> [half_km=80] [step_m=160]` | `farfield80.f32/.json` | 80 km ring from the global 200 m DEM, resampled onto a metric grid. This is what gives the distant crater rim and mountains |

All heights are relative to the waypoint, so the rings line up with the patch. Run `patch.py` first: `farfield_global.py` reads
`center_elevation_m` from the patch's `meta.json`.

`pick.py` is a helper to find interesting waypoints (sols 300-1500) by relief and slope.

## 3. Derive

Slope is computed inside the viewer from the heightmap (`slope_deg`), not stored. The H key colours the terrain
by slope against `HAZARD_DEG = 15` (a simple hazard layer, not a real traversability model).

## 4. Enrich: orbital albedo on the far rings

The patch itself uses the 25 cm ortho directly. The rings get grayscale textures so dunes and crater structure show:

| Script | Output | Source / resolution |
|---|---|---|
| `farfield_tex_hirise.py <sol> <site> <drive> [half_km=3]` | `farfield_tex.png` (4000 px) | HiRISE 25 cm ortho block-averaged 6x to 1.5 m/px. Threaded range reads (about 24,000 row requests, ~10 min) |
| `farfield_tex.py <sol> <site> <drive> [half_km=6]` | `farfield6_tex.png` (1000 px) | CTX 6 m ortho, resized to 12 m/px |
| `farfield80_tex.py <sol> <site> <drive> <MC13.tif> <out_dir>` | `farfield80_tex.png` (1001 px) | Robbins MC13 100 m mosaic resampled onto the 80 km ring grid |

Textures are normalised to 8 bit (percentile stretch) and the viewer multiplies them into the ring colour.
This is **brightness only, not true colour**. We tried the HiRISE COLOR product (false-colour IRB strip) but could not
register it to the ortho, so the red tint is a fixed hand-tuned colour matched to a real photo.

## 5. Synthetic detail (all in `viewer-godot/main.gd`)

Orbital data stops at ~25 cm per pixel, so ground-level clutter is generated, seeded, and labelled synthetic on screen:

- **Rocks** (`_rocks`, `_rock_mesh`, `_add_rock`): clusters (a boulder with debris around it) plus scattered rocks, power-law
  sizes up to ~0.7 m, tilted to the slope, partly buried, dust on top. Instanced meshes, ~323k triangles total.
- **Pebbles and ground colour** (terrain shader): three overlapping procedural layers (granules, pebbles, small cobbles)
  that cluster into gravelly and bare patches, with short sun shadows and distance fade to avoid shimmer in VR.
- **Perseverance model** (`_rover`) placed at the waypoint (`--norover` hides it).

## 6. Viewer (`viewer-godot/`)

Godot 4.7, GDScript. `_ready` loads `meta.json` and `heightmap.f32`, then builds: environment (sky, fog, sun), terrain mesh
with the ortho shader, the far rings (`_farfield`, `_farring`), rocks, route markers, player and XR setup.

- Far rings are meshes with a vertex shader that applies **Mars curvature** (`VERTEX.y -= d^2 / (2R)`), exponential fog
  and aerial perspective for haze.
- Patch folder is chosen with `--patch=<folder>`; the default is `res://patch/`.
- Test/debug flags: `--cam=az,el,vfov`, `--norover`, `--shot=out.png` (renders 40 frames, saves, quits), `--test`.
- The player is confined to the 90 m patch (`LIMIT = 45`).

## Making a new scene, end to end

```bash
cd pipeline
export MARS_DATA=/path/to/mars_data/          # DTM .tif + M20_waypoints.json + M20_traverse.json
OUT=../viewer-godot/patch_<sol>
python patch.py          <sol> <site> <drive> 90 $OUT
python farfield.py       <sol> <site> <drive> 3 6  $OUT
python farfield.py       <sol> <site> <drive> 6 12 /tmp/ring6   # separate folder, see note below
cp /tmp/ring6/farfield.f32 $OUT/farfield6.f32; cp /tmp/ring6/farfield.json $OUT/farfield6.json
python farfield_global.py <sol> <site> <drive> 80 160 $OUT
python farfield_tex_hirise.py <sol> <site> <drive> 3 $OUT
python farfield_tex.py   <sol> <site> <drive> 6 $OUT
python farfield80_tex.py <sol> <site> <drive> /path/MC13_100mpp.tif $OUT
cd ../viewer-godot && godot --path . -- --patch=patch_<sol>
```

Known wrinkle: `farfield.py` always writes `farfield.f32`, so the 6 km ring goes to a separate folder and is renamed
to `farfield6.*` (that is how `patch_793` was made). Fixing this with an output-name argument is a good first cleanup. This command sequence has not been re-run end to end from scratch.

## Known limits and open items

- Rock and pebble placement is random, not derived from real rock maps; do not use it for science.
- Colour is a tint, not measured. Real colour needs HiRISE COLOR registered to the ortho (failed on sol 793: weak correlation).
- Patch is 90 m; the player cannot walk further. Rover heading, VR frame rate, and hazard-layer visuals are unverified.
- `data/patch_sol448_*` is the first test patch; `viewer-godot/patch/` is the viewer default (sol 448); `patch_793` is the current showcase.
- Credits: USGS/JPL Mars 2020 TRN mosaics, NASA/JPL MMGIS, ESA HRSC / NASA MOLA, Robbins CTX mosaics.

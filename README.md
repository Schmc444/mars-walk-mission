# Mars Route Walker

NASA Space Apps 2026 (Interplanetary Survival Guide: Martian Map). Turns a rover route into a walkable Mars scene.

- `pipeline/` — source adapter + patch extraction (USGS/JPL HiRISE 1 m DTM + 25 cm ortho via HTTP range requests, NASA MMGIS route/waypoints). Usage: `patch.py <sol> <site> <drive> [size_m] [out_dir]` (env `MARS_DATA` = folder with M20_waypoints.json and the DTM .tif).
- `data/` — small extracted patches (heightmap.f32, ortho.png, route_local.json, meta.json).
- `viewer-godot/` — Godot 4.7 viewer (desktop + OpenXR). Controls: WASD, RMB look, H = slope hazard layer.

Data: USGS/JPL Mars 2020 TRN HiRISE mosaics, NASA/JPL MMGIS. Rocks are synthetic (illustrative).

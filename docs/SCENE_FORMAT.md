# scene.json (schema 1)

Every scene folder has a `scene.json` written by `marswalk build` (or `marswalk adopt` for legacy folders).
The viewer only reads this manifest; it never hard-codes file names.

- `origin`: sol, site, drive, lon, lat, roll/pitch/yaw, elevation_m. Axes: x east, z south, y up, metres, origin = waypoint.
- `layers[]`: `id`, `title`, `kind` (`elevation` | `image` | `scalar` | `polylines`), `file`, `dtype`, `samples`, `step_m`,
  `half_m`, `unit`, `min`, `max`, `source`. Rasters have row 0 = north. Heights are relative to the waypoint.
- Rings add `role: "ring"`, `inner_skip_m`, `view {subsample, lower_m}` and an optional `texture` (grayscale PNG over the ring extent, row 0 = north) with
  `texture_sources[]` crediting what it was made from. `marswalk` makes them from the Robbins CTX quad mosaics (6 m for the
  3 and 6 km rings, 100 m for the 80 km ring; only for |lat| < 30) and, on the 3 km ring, the HiRISE 25 cm ortho where the
  site has it. Outside CTX coverage the ring is left untextured.

Add a layer: write a function in `marswalk/layers.py` decorated with `@layer("id", requires=(...))` that writes its files
into `ctx.out` and returns manifest entries. Check with `marswalk validate <folder>`.
Commands: `marswalk build SOL SITE DRIVE` / `marswalk build --site ID [--lon X --lat Y]`, `marswalk adopt FOLDER`, `marswalk validate FOLDER`, `marswalk layers`.

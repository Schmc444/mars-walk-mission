# scene.json (schema 1)

Every scene folder has a `scene.json` written by `marswalk build` (or `marswalk adopt` for legacy folders).
The viewer only reads this manifest; it never hard-codes file names.

- `origin`: sol, site, drive, lon, lat, roll/pitch/yaw, elevation_m. Axes: x east, z south, y up, metres, origin = waypoint.
- `layers[]`: `id`, `title`, `kind` (`elevation` | `image` | `scalar` | `polylines`), `file`, `dtype`, `samples`, `step_m`,
  `half_m`, `unit`, `min`, `max`, `source`. Rasters have row 0 = north. Heights are relative to the waypoint.
- Rings add `role: "ring"`, `inner_skip_m`, `view {subsample, lower_m}` and an optional `texture`.

Add a layer: write a function in `marswalk/layers.py` decorated with `@layer("id", requires=(...))` that writes its files
into `ctx.out` and returns manifest entries. Check with `marswalk validate <folder>`.
Commands: `marswalk build SOL SITE DRIVE`, `marswalk adopt FOLDER`, `marswalk validate FOLDER`, `marswalk layers`.

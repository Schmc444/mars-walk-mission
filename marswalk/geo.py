"""Coordinates. Scene frame: origin = waypoint, x east, z south, y up, all in GROUND metres. Raster row 0 = north.

The NASA/USGS mosaics are equirectangular with standard parallel 0 (X = R*lon, Y = R*lat in 'metres'), so one pixel is
`px` metres N-S but only `px*cos(lat)` metres E-W on the ground. Everything here converts through lon/lat so the scene
uses true ground metres on both axes.
"""
import math, warnings
import numpy as np

R = 3396190.0


class Site:
    def __init__(self, lon, lat):
        self.lon, self.lat = lon, lat
        self.cos = math.cos(math.radians(lat))

    def axis_lonlat(self, half_m, step_m):
        """1-D ground axes (east, south) of an n x n grid centred on the site -> (E, S, lon[n], lat[n])."""
        n = int(round(2 * half_m / step_m)) + 1
        g = -half_m + np.arange(n) * step_m
        return g, g, self.lon + np.degrees(g / (R * self.cos)), self.lat - np.degrees(g / R)

    def to_ground(self, lon, lat):
        """lon/lat (deg) -> (east_m, south_m) from the site."""
        return R * self.cos * math.radians(lon - self.lon), R * math.radians(self.lat - lat)


class Raster:
    """A georeferenced source mosaic. unit 'm' = projected equirectangular metres, 'deg' = degrees."""

    def __init__(self, tif, unit="m"):
        self.tif, self.unit = tif, unit

    def lonlat_to_px(self, lon, lat):
        """Continuous pixel coordinates (pixel k covers [k, k+1))."""
        t = self.tif
        if self.unit == "deg":
            return (np.asarray(lon) - t.x0) / t.px, (t.y0 - np.asarray(lat)) / t.px
        return (R * np.radians(lon) - t.x0) / t.px, (t.y0 - R * np.radians(lat)) / t.px


class ClonRaster(Raster):
    """Equirectangular mosaic centred on longitude 180 (Robbins CTX quads): x = R*radians(lon - 180), lon wrapped."""

    def lonlat_to_px(self, lon, lat):
        t = self.tif
        lc = (np.asarray(lon) % 360.0) - 180.0
        return (R * np.radians(lc) - t.x0) / t.px, (t.y0 - R * np.radians(lat)) / t.px


def block_mean(a, b):
    if b == 1:
        return a
    m, n = a.shape[0] // b, a.shape[1] // b
    with np.errstate(all="ignore"), warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return np.nanmean(a[:m * b, :n * b].reshape(m, b, n, b), axis=(1, 3))


def bilinear(img, ix, iy):
    """Sample img (H, W) at float index coordinates ix (n_x,), iy (n_y,) -> (n_y, n_x). Index k = centre of pixel k."""
    H, W = img.shape
    x0 = np.clip(np.floor(ix).astype(int), 0, W - 2)
    y0 = np.clip(np.floor(iy).astype(int), 0, H - 2)
    tx = np.clip(ix - x0, 0, 1)[None, :]
    ty = np.clip(iy - y0, 0, 1)[:, None]
    a, b = img[y0][:, x0], img[y0][:, x0 + 1]
    c, d = img[y0 + 1][:, x0], img[y0 + 1][:, x0 + 1]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def sample_ground_grid(raster, site, half_m, step_m, block=1, nodata_below=-1e30, keep_nan=False):
    """Resample a mosaic onto the scene's ground grid (n x n, row 0 = north). `block` pre-averages source pixels
    (use for coarse rings so fine detail is averaged, not aliased). Returns float32 (n, n)."""
    E, S, _, _ = site.axis_lonlat(half_m, step_m)
    return sample_axes(raster, site, E, S, block, nodata_below, keep_nan)


def sample_axes(raster, site, E, S, block=1, nodata_below=-1e30, keep_nan=False):
    """Like sample_ground_grid for arbitrary ground axes: E east metres (columns), S south metres (rows)."""
    lon = site.lon + np.degrees(np.asarray(E) / (R * site.cos))
    lat = site.lat - np.degrees(np.asarray(S) / R)
    fx, fy = raster.lonlat_to_px(lon, lat)
    pad = block + 2
    c0, r0 = int(math.floor(fx.min())) - pad, int(math.floor(fy.min())) - pad
    c1, r1 = int(math.ceil(fx.max())) + pad, int(math.ceil(fy.max())) + pad
    t = raster.tif
    inside = (fx >= 0)[None, :] & (fx <= t.width)[None, :] & (fy >= 0)[:, None] & (fy <= t.height)[:, None]
    if (c0 < 0 or r0 < 0 or c1 > t.width or r1 > t.height) and not keep_nan:
        raise ValueError("requested area leaves the source mosaic")
    c0, r0, c1, r1 = max(c0, 0), max(r0, 0), min(c1, t.width), min(r1, t.height)
    if c1 - c0 < 2 or r1 - r0 < 2:
        return np.full((len(lat), len(lon)), np.nan, "f4"), 1.0
    win = t.window(c0, r0, c1 - c0, r1 - r0).astype("f4")
    win[win < nodata_below] = np.nan
    win = block_mean(win, block)
    ix, iy = (fx - c0) / block - 0.5, (fy - r0) / block - 0.5
    out = bilinear(win, ix, iy)
    out[~inside] = np.nan
    bad = np.isnan(out)
    if keep_nan:
        return out.astype("f4"), float(bad.mean())
    if bad.any():
        out[bad] = np.nanmin(out) if not bad.all() else 0
    return out.astype("f4"), float(bad.mean())

"""Conversión mínima lat/lon <-> metros locales <-> celda, solo para escribir destinos con el teclado.

Usa la georreferencia de la escena: `scene.json -> origin {lon, lat}` (el waypoint del rover, origen de la escena) y la
misma fórmula esférica que `marswalk.geo.Site.to_ground` (x = este, z = sur, metros sobre el suelo):
    x = R·cos(lat0)·Δlon      z = R·(lat0 - lat)
Es una aproximación equirectangular local: sirve en el parche (±45 m) y el anillo (±3 km); no para distancias de cientos de km.
Longitud este positiva (Marte, 0-360 E). Si la escena no trae `origin`, se lanza GeoError: NO se inventan valores.
Punto de extensión: pasar otro `GeoRef` (con los mismos métodos) a `validate_point` si algún día hay otra proyección.
"""
import json, math, os

R = 3396190.0  # radio de Marte (m), igual que marswalk.geo.R


class GeoError(ValueError):
    """Error claro para mostrar al usuario (sin georreferencia, fuera de la capa, intransitable...). `code` es estable."""
    def __init__(self, msg, code="punto_invalido"):
        super().__init__(msg)
        self.code = code


class GeoRef:
    def __init__(self, lon0, lat0):
        self.lon0, self.lat0 = float(lon0), float(lat0)
        self.cos = math.cos(math.radians(self.lat0))

    @classmethod
    def from_scene(cls, scene):
        """`scene`: dict de scene.json o carpeta de la escena."""
        if isinstance(scene, (str, os.PathLike)):
            scene = json.load(open(os.path.join(scene, "scene.json")))
        o = scene.get("origin") or {}
        if o.get("lon") is None or o.get("lat") is None:
            raise GeoError("la escena no tiene georreferencia (scene.json -> origin.lon/lat): no se puede convertir lat/lon", "sin_georreferencia")
        return cls(o["lon"], o["lat"])

    def lonlat_to_local(self, lon, lat):
        dlon = (float(lon) - self.lon0 + 180.0) % 360.0 - 180.0   # por el camino corto (sin salto 0/360)
        return R * self.cos * math.radians(dlon), R * math.radians(self.lat0 - float(lat))

    def local_to_lonlat(self, x, z):
        return (self.lon0 + math.degrees(x / (R * self.cos))) % 360.0, self.lat0 - math.degrees(z / R)


def parse_latlon(text):
    """'18.4826, 77.3687' (o con ';' / espacios) -> (lat, lon). Lanza GeoError con un mensaje claro."""
    parts = [p for p in text.replace(";", " ").replace(",", " ").split() if p]
    if len(parts) != 2:
        raise GeoError("formato: 'lat, lon' en grados decimales (ej. 18.4826, 77.3687)")
    try:
        lat, lon = float(parts[0]), float(parts[1])
    except ValueError:
        raise GeoError("lat/lon deben ser numeros decimales (ej. 18.4826, 77.3687)")
    if not (-90 <= lat <= 90):
        raise GeoError("latitud fuera de rango (-90 a 90): %s" % lat)
    if not (-360 <= lon <= 360):
        raise GeoError("longitud fuera de rango (-360 a 360): %s" % lon)
    return lat, lon


def local_to_cell(g, x, z):
    """Metros locales -> (fila, columna) de la capa `g` (puede quedar fuera: se valida aparte)."""
    s = g["step"]
    return int(round((z - g["z0"]) / s)), int(round((x - g["x0"]) / s))


def inside(g, x, z):
    r, c = local_to_cell(g, x, z)
    return 0 <= r < g["h"].shape[0] and 0 <= c < g["h"].shape[1]


def validate_point(g, x, z, snap_m=5.0, what="punto"):
    """Comprueba que (x, z) cae dentro de la capa y sobre una celda transitable (`g['blocked']`, ya calculado).

    Devuelve (x, z, aviso). Si la celda es intransitable usa la transitable más cercana dentro de `snap_m` metros y lo dice en `aviso`
    (None si no hubo cambio). Si cae fuera de la capa o no hay celda transitable cerca lanza GeoError.
    """
    if not inside(g, x, z):
        raise GeoError("%s fuera de la capa (x %.0f..%.0f m, z %.0f..%.0f): x=%.0f, z=%.0f" % (
            what, g["x0"], g["x0"] + (g["h"].shape[1] - 1) * g["step"], g["z0"], g["z0"] + (g["h"].shape[0] - 1) * g["step"], x, z), "fuera_de_capa")
    r, c = local_to_cell(g, x, z)
    blocked = g["blocked"]
    if not blocked[r, c]:
        return x, z, None
    k = int(math.ceil(snap_m / g["step"]))
    best = None
    for rr in range(max(0, r - k), min(g["h"].shape[0], r + k + 1)):
        for cc in range(max(0, c - k), min(g["h"].shape[1], c + k + 1)):
            d = math.hypot(rr - r, cc - c) * g["step"]
            if not blocked[rr, cc] and d <= snap_m and (best is None or d < best[0]):
                best = (d, rr, cc)
    if best is None:
        raise GeoError("%s intransitable (pendiente >= limite o sin datos) y sin celda transitable a menos de %.0f m" % (what, snap_m), "intransitable")
    nx, nz = g["step"] * best[2] + g["x0"], g["step"] * best[1] + g["z0"]
    return nx, nz, "%s sobre celda intransitable; se uso la transitable mas cercana (%.1f m): x=%.1f, z=%.1f" % (what, best[0], nx, nz)

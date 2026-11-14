"""Clasificación de terreno: duna/arena vs. terreno firme, celda por celda.

Produce una matriz de enteros con la MISMA forma y georreferencia que la matriz de pendientes del planificador
(cuadrícula n x n centrada en el origen de la escena, fila 0 = norte). Los códigos se definen aquí y solo aquí.

Fuentes intercambiables (misma interfaz: `fuente(g) -> (matriz_clases, info)`):
  - ProxySource  : aproximación con rugosidad del DEM + brillo del ortho HiRISE (fallback, SIN mapa geológico real).
  - FileSource   : mapa de clases externo (.npy, .png o .f32) que cubre el mismo cuadrado que la capa.
Se elige con `make_source(ruta_o_None)`. Para agregar otra fuente basta una clase con `name` y `__call__(g)`.
"""
import json, os
import numpy as np
from PIL import Image

# --- códigos (únicos; no cambiar los números: están en guide_path.json y en el visor) ---
ROCA_FIRME = 0
REGOLITO = 1
ARENA_DUNA = 2
BLOQUES = 3

NAMES = {ROCA_FIRME: "roca firme", REGOLITO: "regolito", ARENA_DUNA: "arena / duna", BLOQUES: "bloques / rocoso"}
# nombres cortos para el HUD ("Terreno: duna")
SHORT = {ROCA_FIRME: "roca firme", REGOLITO: "regolito", ARENA_DUNA: "duna", BLOQUES: "bloques"}
COLORS = {ROCA_FIRME: (150, 150, 160), REGOLITO: (120, 85, 60), ARENA_DUNA: (240, 200, 70), BLOQUES: (170, 60, 190)}

PROXY_WARNING = ("Clase de terreno estimada con un PROXY (rugosidad del DEM + brillo del ortho), no con un mapa geologico "
                 "ni de dunas: es una aproximacion. Los percentiles de brillo hacen que casi siempre salga algo de 'duna'.")


def box3(a):
    p = np.pad(a, 1, mode="edge")
    return sum(p[1 + di:1 + di + a.shape[0], 1 + dj:1 + dj + a.shape[1]] for di in (-1, 0, 1) for dj in (-1, 0, 1)) / 9.0


def mode_filter(cls, n_classes=4):
    """Filtro de moda 3x3 (quita celdas sueltas). En empate se conserva la clase de la celda."""
    p = np.pad(cls, 1, mode="edge")
    counts = np.zeros((n_classes,) + cls.shape, "i4")
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            win = p[1 + di:1 + di + cls.shape[0], 1 + dj:1 + dj + cls.shape[1]]
            for k in range(n_classes):
                counts[k] += (win == k)
    best = counts.argmax(0)
    keep = counts.max(0) == np.take_along_axis(counts, cls[None].astype(int), 0)[0]
    return np.where(keep, cls, best).astype("i4")


class ProxySource:
    """Fallback: clase de terreno estimada a partir de `g['rough']` e `g['img']` (brillo 0-1, o None)."""
    name = "proxy"

    def __init__(self, params=None):
        from route_config import PROXY
        self.p = dict(PROXY, **(params or {}))

    def __call__(self, g):
        p, rough = self.p, g["rough"]
        cls = np.full(rough.shape, REGOLITO, "i4")
        if g["img"] is not None:
            b = g["img"]
            nd = g.get("nodata")
            lo, hi = np.percentile(b if nd is None else b[~nd], [p["dark_pct"], p["bright_pct"]])   # solo celdas con datos
            cls[(b > hi) & (rough < p["rough_bright"])] = ROCA_FIRME   # brillante y liso -> roca expuesta
            cls[(b < lo) & (rough < p["rough_dark"])] = ARENA_DUNA     # oscuro y liso -> arena / duna
        cls[rough > p["rough_blocks"]] = BLOQUES                       # rugoso -> bloques
        if p["mode_filter"]:
            cls = mode_filter(cls)
        return cls, dict(source=self.name, is_proxy=True, warning=PROXY_WARNING, params=p)


class FileSource:
    """Mapa de clases externo. Debe cubrir el MISMO cuadrado que la capa (centrado en el origen, ±half_m).

    Formatos: .npy (2-D), .png (gris: el valor del píxel es el código), .f32/.u8 (n x n crudo, n = lado de la capa).
    Si el mapa externo usa otros códigos, un JSON junto al archivo (`<archivo>.json`) con {"codes": {"valor_externo": codigo_interno}}.
    Si su resolución difiere de la capa se remuestrea por vecino más cercano (no se mezclan clases).
    """
    def __init__(self, path):
        self.path = path
        self.name = "archivo:" + os.path.basename(path)

    def _read(self, n):
        ext = os.path.splitext(self.path)[1].lower()
        if ext == ".npy":
            return np.load(self.path)
        if ext == ".png":
            return np.asarray(Image.open(self.path).convert("L"))
        if ext in (".f32", ".u8"):
            a = np.fromfile(self.path, "<f4" if ext == ".f32" else "u1")
            if a.size != n * n:
                raise ValueError("%s: %d valores, se esperaban %dx%d" % (self.path, a.size, n, n))
            return a.reshape(n, n)
        raise ValueError("formato de mapa de clases no soportado: %s (usa .npy, .png, .f32 o .u8)" % ext)

    def __call__(self, g):
        n = g["n"]
        a = self._read(n)
        if a.ndim != 2 or a.shape[0] != a.shape[1]:
            raise ValueError("el mapa de clases debe ser cuadrado y 2-D, llegó %s" % (a.shape,))
        a = np.rint(a).astype("i4")
        sidecar = self.path + ".json"
        if os.path.exists(sidecar):
            codes = {int(k): int(v) for k, v in json.load(open(sidecar))["codes"].items()}
            out = np.full(a.shape, -1, "i4")
            for k, v in codes.items():
                out[a == k] = v
            a = out
        if a.shape[0] != n:   # remuestreo por vecino más cercano sobre el mismo cuadrado
            idx = np.minimum((np.arange(n) * a.shape[0] / n).astype(int), a.shape[0] - 1)
            a = a[np.ix_(idx, idx)]
        bad = ~np.isin(a, list(NAMES))
        if bad.any():
            raise ValueError("%s: %d celdas con códigos fuera de %s (usa un JSON 'codes' para mapearlos)" % (self.path, bad.sum(), sorted(NAMES)))
        return a, dict(source=self.name, is_proxy=False, warning=None, params={"file": self.path})


def make_source(spec=None):
    """None / 'proxy' -> ProxySource; ruta a archivo -> FileSource; objeto con __call__ y name -> tal cual."""
    if spec is None or spec == "proxy":
        return ProxySource()
    if callable(spec):
        return spec
    return FileSource(str(spec))


def classify(g, source=None):
    """Clasifica la capa `g` (con 'rough' e 'img') con la fuente dada. Devuelve (matriz, info)."""
    cls, info = make_source(source)(g)
    assert cls.shape == g["h"].shape, "la matriz de clases debe tener la forma de la capa"
    return cls, info


def class_image(cls, scale=1):
    """RGB (uint8) de la matriz de clases con la paleta COLORS, para revisar el clasificador a ojo."""
    rgb = np.zeros(cls.shape + (3,), "u1")
    for k, col in COLORS.items():
        rgb[cls == k] = col
    im = Image.fromarray(rgb)
    return im.resize((cls.shape[1] * scale, cls.shape[0] * scale), Image.NEAREST) if scale != 1 else im

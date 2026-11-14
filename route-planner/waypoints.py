"""Puntos importantes guardados (base, rescate del Ingenuity, ...) en un JSON compartido con el visor Godot.

Archivo por defecto: viewer-godot/route/waypoints.json  (Godot lo lee como res://route/waypoints.json).
Formato: {"schema": 1, "waypoints": [{"id", "nombre", "lat", "lon", "descripcion"?, "placeholder"?, "fuente"?}]}
Las entradas con "placeholder": true NO tienen coordenadas reales (lat/lon = null): reemplazalas a mano o con `add`.
Uso rapido:  python waypoints.py list | add ID NOMBRE LAT LON [DESC] | del ID_O_NOMBRE
"""
import json, os, sys, unicodedata

DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "viewer-godot", "route", "waypoints.json")


class WaypointError(ValueError):
    pass


def _norm(s):
    return "".join(c for c in unicodedata.normalize("NFD", str(s).strip().lower()) if unicodedata.category(c) != "Mn")


def load(path=None):
    path = path or DEFAULT_PATH
    if not os.path.exists(path):
        return []
    return json.load(open(path, encoding="utf-8")).get("waypoints", [])


def save(wps, path=None):
    path = path or DEFAULT_PATH
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    json.dump({"schema": 1, "waypoints": wps}, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def find(key, path=None):
    """Busca por id o por nombre (sin distinguir mayusculas ni acentos). Lanza WaypointError si no existe."""
    k = _norm(key)
    for w in load(path):
        if _norm(w["id"]) == k or _norm(w["nombre"]) == k:
            return w
    raise WaypointError("no hay un punto guardado con id/nombre '%s'" % key)


def usable(w):
    """Un punto sirve de destino solo si tiene coordenadas (los placeholders no)."""
    return w.get("lat") is not None and w.get("lon") is not None


def resolve(key, path=None):
    """id/nombre -> (lat, lon, nombre). Error claro si es un placeholder sin coordenadas."""
    w = find(key, path)
    if not usable(w):
        raise WaypointError("'%s' es un placeholder sin coordenadas: edita waypoints.json con lat/lon reales" % w["nombre"])
    return float(w["lat"]), float(w["lon"]), w["nombre"]


def add(id_, nombre, lat, lon, descripcion="", path=None):
    """Agrega un punto (o reemplaza el de mismo id). lat/lon en grados decimales."""
    if not (-90 <= float(lat) <= 90) or not (-360 <= float(lon) <= 360):
        raise WaypointError("lat/lon fuera de rango")
    wps = [w for w in load(path) if _norm(w["id"]) != _norm(id_)]
    w = {"id": id_, "nombre": nombre, "lat": float(lat), "lon": float(lon)}
    if descripcion:
        w["descripcion"] = descripcion
    wps.append(w)
    save(wps, path)
    return w


def remove(key, path=None):
    """Borra por id o nombre. Devuelve el punto borrado."""
    w = find(key, path)
    save([x for x in load(path) if x is not w and x["id"] != w["id"]], path)
    return w


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "list"
    if cmd == "list":
        for w in load():
            pos = "(placeholder, sin coordenadas)" if not usable(w) else "%.6f, %.6f" % (w["lat"], w["lon"])
            print("%-18s %-28s %s  %s" % (w["id"], w["nombre"], pos, w.get("descripcion", "")))
    elif cmd == "add" and len(argv) >= 6:
        print("guardado:", add(argv[2], argv[3], float(argv[4]), float(argv[5]), " ".join(argv[6:])))
    elif cmd in ("del", "rm") and len(argv) == 3:
        print("borrado:", remove(argv[2]))
    else:
        print(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except WaypointError as e:
        sys.exit("error: %s" % e)

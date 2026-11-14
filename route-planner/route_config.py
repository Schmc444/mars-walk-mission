"""Parámetros SUPUESTOS del planificador de rutas (un solo lugar).

Nada de esto sale de mediciones: son valores razonables para ajustar. Se pueden sobrescribir sin tocar el código
con un JSON (`--config archivo.json`, ver `apply_overrides`) con las mismas claves.
"""
from terrain_classes import ROCA_FIRME, REGOLITO, ARENA_DUNA, BLOQUES

# Por clase de terreno: (factor de velocidad, riesgo de terreno).
#  - factor de velocidad: multiplica la velocidad de marcha (arena suelta: se hunde el pie).
#  - riesgo: penalización ADICIONAL de costo (se multiplica por --riesgo): hundirse/resbalar en duna, tropezar en bloques.
TERRAIN_SPEED = {ROCA_FIRME: 1.00, REGOLITO: 0.90, ARENA_DUNA: 0.60, BLOQUES: 0.50}
TERRAIN_RISK = {ROCA_FIRME: 0.0, REGOLITO: 0.1, ARENA_DUNA: 1.5, BLOQUES: 0.8}

SUIT_FACTOR = 0.55      # traje EVA vs. caminante en la Tierra (en Apolo se caminaba a ~0.5-1 m/s)
SOFT_SLOPE = 15.0       # grados: empieza la penalización (igual que HAZARD_DEG del visor)
HARD_SLOPE = 25.0       # grados: intransitable a pie

DEFAULT_RISK = 1.0      # peso de riesgo por defecto. 0 = solo tiempo de marcha; >1 = evita más dunas/rocas/pendiente

CONDITIONS = {
    # vis: visibilidad (0-1)   spd: factor de velocidad   soft: pendiente (°) donde empiezan las penalizaciones
    # shadow/rough/slope/terrain: pesos de penalización   track: bono por ir sobre la huella del rover
    "normal":         dict(vis=1.00, spd=1.00, soft=15.0, shadow=0.0, rough=0.5, slope=2.0, terrain=1.0, track=0.85),
    "tormenta_polvo": dict(vis=0.55, spd=0.85, soft=8.0,  shadow=0.0, rough=2.5, slope=4.0, terrain=1.5, track=0.55),
    "frio_sombra":    dict(vis=0.90, spd=0.90, soft=15.0, shadow=1.5, rough=0.5, slope=2.0, terrain=1.0, track=0.85),
}

# Clasificador proxy (rugosidad del DEM + brillo del ortho). Umbrales supuestos.
PROXY = dict(
    bright_pct=75.0,    # percentil de brillo por encima del cual (y liso) se supone roca expuesta
    dark_pct=20.0,      # percentil por debajo del cual (y liso) se supone arena/duna
    rough_bright=0.6,   # rugosidad máxima para llamar "roca firme" a lo brillante
    rough_dark=0.8,     # rugosidad máxima para llamar "arena" a lo oscuro
    rough_blocks=0.35,  # rugosidad (≈3.5 cm RMS por m) a partir de la cual se llama "bloques"
    mode_filter=True,   # filtro de moda 3x3: quita celdas sueltas (ruido)
)


def apply_overrides(path):
    """Sobrescribe constantes de este módulo con las claves de un JSON (mismos nombres, p. ej. {"TERRAIN_RISK": {"2": 3.0}})."""
    import json
    g = globals()
    for k, v in json.load(open(path)).items():
        if k not in g or k.startswith("_") or not k.isupper():
            raise ValueError("clave de configuración desconocida: %s" % k)
        if isinstance(g[k], dict):
            for kk, vv in v.items():
                key = int(kk) if k.startswith("TERRAIN_") else kk
                if isinstance(g[k].get(key), dict):
                    g[k][key].update(vv)
                else:
                    g[k][key] = vv
        else:
            g[k] = v

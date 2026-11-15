"""Download MEDA (NASA PDS) files for sols A..B and reduce them to hourly LMST means per sol.
Output: meda_horario.csv (sol, hour, p, T_air, T_air_min/max, LW_up, LW_down, zenith, x, y, z, n).
Raw files are streamed, not saved."""
import csv, io, math, sys, urllib.request, os, concurrent.futures as cf

B = "https://pds-atmospheres.nmsu.edu/PDS/data/PDS4/Mars2020/mars2020_meda"
OUT = sys.argv[1]
SOLS = range(int(sys.argv[2]), int(sys.argv[3]) + 1)
FILES = {
    "ps":  ("data_derived_env", "DER_PS__________________P01"),
    "ats": ("data_calibrated_env", "CAL_ATS_________________P01"),
    "tirs": ("data_derived_env", "DER_TIRS________________P02"),
    "anc": ("data_derived_env", "DER_ANCILLARY___________P02"),
}


def url(kind, sol):
    d, name = FILES[kind]
    lo = 900 + ((sol - 900) // 120) * 120
    return "%s/%s/sol_%04d_%04d/sol_%04d/WE__%04d___________%s.CSV" % (B, d, lo, lo + 119, sol, sol, name)


def rows(kind, sol):
    try:
        with urllib.request.urlopen(url(kind, sol), timeout=300) as r:
            txt = r.read().decode("ascii", "replace")
    except Exception as e:
        if kind == "anc" and "P02" in FILES["anc"][1]:
            try:
                with urllib.request.urlopen(url(kind, sol).replace("P02.CSV", "P01.CSV"), timeout=300) as r:
                    txt = r.read().decode("ascii", "replace")
                return list(csv.DictReader(io.StringIO(txt)))
            except Exception:
                pass
        print("missing", kind, sol, e, flush=True)
        return []
    return list(csv.DictReader(io.StringIO(txt)))


def hora(lmst):  # '01063M08:19:10.123' -> 8.319...
    t = lmst.split("M")[1]
    h, m, s = t.split(":")
    return int(h) + int(m) / 60 + float(s) / 3600


def f(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def sol_data(sol):
    acc = {}  # (hour) -> dict of lists

    def add(lmst, key, val):
        if val is None or not lmst.startswith("%05d" % sol):
            return
        h = int(hora(lmst))
        acc.setdefault(h, {}).setdefault(key, []).append(val)

    for r in rows("ps", sol):
        v = f(r["PRESSURE"])
        add(r["LMST"], "p", v if v is not None and 400.0 < v < 1200.0 else None)   # drop PDS fill values
    for r in rows("ats", sol):
        vals = [f(r["ATS_LOCAL_TEMP%d" % i]) for i in (1, 2, 3)]
        vals = [v for v in vals if v is not None and 120 < v < 320]
        if vals:
            add(r["LMST"], "t", sum(vals) / len(vals))
    for r in rows("tirs", sol):
        u, d = f(r["UPWARD_LW_IRRADIANCE"]), f(r["DOWNWARD_LW_IRRADIANCE"])
        add(r["LMST"], "lwu", u if u is not None and 0.0 < u < 1000.0 else None)
        add(r["LMST"], "lwd", d if d is not None and 0.0 < d < 1000.0 else None)
    for i, r in enumerate(rows("anc", sol)):
        if i % 10:
            continue
        z = f(r["SOLAR_ZENITHAL_ANGLE"])
        add(r["LMST"], "zen", z if z is not None and 0.0 <= z <= 180.0 else None)
        add(r["LMST"], "x", f(r["ROVER_POSITION_X"]))
        add(r["LMST"], "y", f(r["ROVER_POSITION_Y"]))
        add(r["LMST"], "z", f(r["ROVER_POSITION_Z"]))
    out = []
    for h in sorted(acc):
        a = acc[h]
        m = lambda k: (sum(a[k]) / len(a[k])) if a.get(k) else None
        out.append(dict(sol=sol, hora=h, p=m("p"), n_p=len(a.get("p", [])), t=m("t"),
                        t_min=min(a["t"]) if a.get("t") else None, t_max=max(a["t"]) if a.get("t") else None,
                        lwu=m("lwu"), lwd=m("lwd"), zen=m("zen"), x=m("x"), y=m("y"), z=m("z")))
    print("sol", sol, "horas", len(out), flush=True)
    return out


with cf.ThreadPoolExecutor(6) as ex:
    todo = [r for res in ex.map(sol_data, SOLS) for r in res]
keys = ["sol", "hora", "p", "n_p", "t", "t_min", "t_max", "lwu", "lwd", "zen", "x", "y", "z"]
with open(OUT, "w", newline="") as fh:
    w = csv.DictWriter(fh, keys)
    w.writeheader()
    for r in todo:
        w.writerow({k: ("" if r[k] is None else (round(r[k], 4) if isinstance(r[k], float) else r[k])) for k in keys})
print("ok", len(todo))

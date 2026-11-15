"""Compare the Atmosphere layer model with NASA MEDA measurements (sols 1063-1116).
Input : ../datos/meda_horario.csv (from meda_bajar.py: hourly LMST means per sol, NASA PDS Atmospheres Node).
Output: ../datos/meda_por_sol.csv, ../datos/meda_ciclo.csv, ../datos/meda_resumen.txt
Pure Python (no numpy). Run: python -I analisis_meda.py"""
import csv, math, os, random

AQUI = os.path.dirname(os.path.abspath(__file__))
DATOS = os.path.join(AQUI, "..", "datos")
SIGMA_SB = 5.670374419e-8
R_GAS, M_CO2MIX, G_MARS = 8.314, 0.04349, 3.73       # NASA Mars Fact Sheet: M = 43.49 g/mol, g = 3.73 m/s2
H_A, H_LAYER = 189.5157, 11100.0                     # point A height in the simulator; layer scale height
SOL_REF = 1089.5

exec(open(os.path.join(AQUI, "mars24.py")).read().split("M2020_SOL0_MSD = ")[0])   # ls_of_msd()
def ls_mars24(sol):
    return ls_of_msd(52304 + sol + 0.5)[0]

# ----- layer model (copied from modelo.gd so both can be compared) -----
LS_ANCLAS = [[0.0, 5.0], [16.0, 13.3], [308.0, 150.7], [313.0, 153.0], [565.0, 308.0], [668.6, 365.0]]
def ls_modelo(sol):
    s = sol - math.floor(sol / 668.6) * 668.6
    for a, b in zip(LS_ANCLAS, LS_ANCLAS[1:]):
        if s <= b[0]:
            return (a[1] + (b[1] - a[1]) * (s - a[0]) / (b[0] - a[0])) % 360
def p0_modelo(ls):
    l = math.radians(ls)
    return 715 + 45 * math.cos(l - math.radians(255)) + 25 * math.cos(2 * (l - math.radians(50)))
def forma_diaria(h, hmin=5.5, hmax=13.5):
    h %= 24
    if hmin <= h <= hmax:
        return -math.cos(math.pi * (h - hmin) / (hmax - hmin))
    hh = h if h > hmax else h + 24
    return math.cos(math.pi * (hh - hmax) / (24 - hmax + hmin))
def temp_modelo(ls, h, tau=0.65):
    media = 220 + 6 * math.cos(math.radians(ls - 250))
    return media + 33 / (1 + 0.4 * max(tau - 0.5, 0)) * forma_diaria(h)

# ----- small linear algebra -----
def lstsq(X, y):
    n = len(X[0])
    A = [[sum(r[i] * r[j] for r in X) for j in range(n)] + [sum(r[i] * v for r, v in zip(X, y))] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(A[r][c])); A[c], A[p] = A[p], A[c]
        for r in range(n):
            if r != c:
                f = A[r][c] / A[c][c]
                A[r] = [a - f * b for a, b in zip(A[r], A[c])]
    return [A[i][n] / A[i][i] for i in range(n)]
def mean(v): return sum(v) / len(v)
def std(v):
    m = mean(v); return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1))
def rms(v): return math.sqrt(mean([x * x for x in v]))

filas = list(csv.DictReader(open(os.path.join(DATOS, "meda_horario.csv"))))
F = lambda r, k: float(r[k]) if r[k] != "" else None
sols = sorted({int(r["sol"]) for r in filas})
out = []
def say(s=""):
    print(s); out.append(s)

say("MEDA (NASA PDS) sols %d-%d: %d sols with data, %d hourly means" % (sols[0], sols[-1], len(sols), len(filas)))
say("Missing sols: %s" % [s for s in range(1063, 1117) if s not in sols])
for s in (1063, 1089.5, 1116):
    say("Ls sol %s: Mars24 %.2f deg, layer model %.2f deg" % (s, ls_mars24(s), ls_modelo(s)))

# ----- 1. pressure: trend + diurnal Fourier, joint least squares -----
P = [(int(r["sol"]), int(r["hora"]) + 0.5, F(r, "p")) for r in filas if F(r, "p") is not None]
def fila_x(sol, h, K):
    x = [1.0, sol - SOL_REF]
    for k in range(1, K + 1):
        w = 2 * math.pi * k * h / 24
        x += [math.cos(w), math.sin(w)]
    return x
y = [p for _, _, p in P]
var_y = sum((v - mean(y)) ** 2 for v in y)
say("\n[Pressure] joint fit p = c0 + c1 (sol-%.1f) + sum_k a_k cos(2 pi k t/24) + b_k sin(...)" % SOL_REF)
for K in range(0, 5):
    c = lstsq([fila_x(s, h, K) for s, h, _ in P], y)
    res = [v - sum(a * b for a, b in zip(c, fila_x(s, h, K))) for (s, h, v) in P]
    say("  K=%d harmonics: rms residual %.2f Pa, R2 %.4f" % (K, rms(res), 1 - sum(r * r for r in res) / var_y))
K = 3
c = lstsq([fila_x(s, h, K) for s, h, _ in P], y)
say("  c0 = %.2f Pa (mean at sol %.1f), trend c1 = %.3f Pa/sol" % (c[0], SOL_REF, c[1]))
armonicos = []
for k in range(1, K + 1):
    a, b = c[2 * k], c[2 * k + 1]
    A = math.hypot(a, b); tmax = (math.atan2(b, a) * 24 / (2 * math.pi * k)) % (24 / k)
    armonicos.append((k, A, tmax))
    say("  harmonic %d (period %.0f h): amplitude %.2f Pa, first maximum at %.2f h LMST" % (k, 24 / k, A, tmax))
def diurno(h):
    return sum(c[2 * k] * math.cos(2 * math.pi * k * h / 24) + c[2 * k + 1] * math.sin(2 * math.pi * k * h / 24) for k in range(1, K + 1))

# daily means (diurnal cycle removed, so gaps do not bias them)
por_sol = {}
for s, h, v in P:
    por_sol.setdefault(s, []).append(v - diurno(h))
diario = {s: mean(v) for s, v in por_sol.items() if len(v) >= 6}
res_tr = [diario[s] - (c[0] + c[1] * (s - SOL_REF)) for s in diario]
sig_dia = std(res_tr)
say("  daily means: %d sols, day-to-day scatter about the trend sigma = %.2f Pa" % (len(diario), sig_dia))
sA = 1063
pA_dia = diario[sA]
say("  sol 1063 daily mean %.2f Pa; sol 1116 daily mean %.2f Pa; change %.1f Pa (%.1f %%)" %
    (pA_dia, diario[1116], diario[1116] - pA_dia, 100 * (diario[1116] - pA_dia) / pA_dia))
mod_ls = [p0_modelo(ls_modelo(s)) * math.exp(-H_A / H_LAYER) for s in diario]
mod_24 = [p0_modelo(ls_mars24(s)) * math.exp(-H_A / H_LAYER) for s in diario]
med = [diario[s] for s in diario]
sesgo = mean([m - d for m, d in zip(mod_ls, med)])
say("  layer model at point A height: bias %+.1f Pa (%.1f %%), rms %.1f Pa; with Mars24 Ls bias %+.1f Pa" %
    (sesgo, 100 * sesgo / mean(med), rms([m - d for m, d in zip(mod_ls, med)]), mean([m - d for m, d in zip(mod_24, med)])))
tend_mod = (p0_modelo(ls_modelo(1116)) - p0_modelo(ls_modelo(1063))) * math.exp(-H_A / H_LAYER) / 53
say("  model trend %.3f Pa/sol vs measured %.3f Pa/sol" % (tend_mod, c[1]))

# ----- 2. air temperature (ATS) and ground brightness temperature (TIRS) -----
horas = range(24)
def comp(key, f=lambda v: v):
    d = {}
    for r in filas:
        v = F(r, key)
        if v is not None:
            d.setdefault(int(r["hora"]), []).append(f(v))
    return {h: mean(v) for h, v in d.items()}
Tair = comp("t"); Tmin_h = comp("t_min"); Tmax_h = comp("t_max")
Tg = comp("lwu", lambda L: (L / SIGMA_SB) ** 0.25)
Lwd = comp("lwd")
pc = comp("p")
zen = comp("zen")
hmin = min(Tair, key=Tair.get); hmax = max(Tair, key=Tair.get)
say("\n[Air temperature, ATS 1-3 mean, composite of all sols]")
say("  min %.1f K (%.1f C) at %02d-%02d h LMST; max %.1f K (%.1f C) at %02d-%02d h; diurnal mean %.1f K; range %.1f K" %
    (Tair[hmin], Tair[hmin] - 273.15, hmin, hmin + 1, Tair[hmax], Tair[hmax] - 273.15, hmax, hmax + 1, mean(list(Tair.values())),
     Tair[hmax] - Tair[hmin]))
say("  coldest single hourly sample %.1f K, warmest %.1f K" % (min(F(r, "t_min") for r in filas if F(r, "t_min")),
                                                               max(F(r, "t_max") for r in filas if F(r, "t_max"))))
ls_c = ls_mars24(SOL_REF)
modT = {h: mean([temp_modelo(ls_modelo(s), h + 0.5) for s in sols]) for h in horas}
dif = [modT[h] - Tair[h] for h in horas]
say("  layer model vs MEDA: bias %+.1f K, rms %.1f K, worst %+.1f K at %02d h" %
    (mean(dif), rms(dif), max(dif, key=abs), max(horas, key=lambda h: abs(dif[h]))))
# refit the model's own shape: grid on (hmin, hmax), linear LS on (mean, amplitude)
best = None
for a in [x / 4 for x in range(12, 33)]:
    for b in [x / 4 for x in range(44, 68)]:
        X = [[1.0, forma_diaria(h + 0.5, a, b)] for h in horas]
        m, A = lstsq(X, [Tair[h] for h in horas])
        e = rms([m + A * forma_diaria(h + 0.5, a, b) - Tair[h] for h in horas])
        if best is None or e < best[0]:
            best = (e, a, b, m, A)
say("  refit of the same shape to MEDA: mean %.1f K, amplitude %.1f K, min %.2f h, max %.2f h, rms %.2f K" %
    (best[3], best[4], best[1], best[2], best[0]))
refT = {h: best[3] + best[4] * forma_diaria(h + 0.5, best[1], best[2]) for h in horas}
say("\n[Ground brightness temperature from TIRS upward LW, T = (L/sigma)^(1/4)]")
hg = max(Tg, key=Tg.get); hg0 = min(Tg, key=Tg.get)
say("  max %.1f K at %02d h (air %.1f K, ground-air %+.1f K); min %.1f K at %02d h (air %.1f K, ground-air %+.1f K)" %
    (Tg[hg], hg, Tair[hg], Tg[hg] - Tair[hg], Tg[hg0], hg0, Tair[hg0], Tg[hg0] - Tair[hg0]))
say("  downward LW (sky + dust): %.1f W/m2 at %02d h, %.1f W/m2 at %02d h" % (Lwd[hg], hg, Lwd[hg0], hg0))

# ----- 3. scale height from measured temperature -----
Tbar = mean(list(Tair.values())); sTbar = std([mean([F(r, "t") for r in filas if r["sol"] == str(s) and F(r, "t")]) for s in sols
                                              if len([1 for r in filas if r["sol"] == str(s) and F(r, "t")]) >= 20])
H = R_GAS * Tbar / (M_CO2MIX * G_MARS)
say("\n[Scale height] H = R T/(M g) with MEDA diurnal-mean T = %.1f K: H = %.0f m (layer uses %.0f m, diff %.1f %%)" %
    (Tbar, H, H_LAYER, 100 * (H_LAYER - H) / H))
say("  day-to-day sigma of daily-mean T = %.2f K -> sigma_H = %.0f m" % (sTbar, H * sTbar / Tbar))
dz = 203.0 - 189.5
say("  barometric change over the segment (dh = %.1f m): %.2f Pa, vs seasonal change %.1f Pa" %
    (dz, -pA_dia * (1 - math.exp(-dz / H)), diario[1116] - pA_dia))

# ----- 4. sun elevation and local time of the scene sun (35 deg) -----
elev = {h: 90 - zen[h] for h in zen}
hh = sorted(elev)
t35 = None
for a, b in zip(hh, hh[1:]):
    if a < 12 and elev[a] < 35 <= elev[b]:
        t35 = a + 0.5 + (35 - elev[a]) / (elev[b] - elev[a])
noon = max(elev, key=elev.get)
say("\n[Sun] MEDA solar zenith: elevation 35 deg reached at %.2f h LMST (%02d:%02d); max hourly-mean elevation %.1f deg at %02d h" %
    (t35, int(t35), round(60 * (t35 % 1)), elev[noon], noon))

# ----- 5. point A (sol 1063) with measured values -----
r8 = [r for r in filas if r["sol"] == "1063" and r["hora"] == "8"][0]
p8, T8 = F(r8, "p"), F(r8, "t")
say("\n[Point A, sol 1063] measured 08-09 h LMST: p = %.2f Pa, T = %.1f K (%.1f C); daily mean p = %.2f Pa" %
    (p8, T8, T8 - 273.15, pA_dia))
say("  layer panel (model): p = 744.67 Pa, T = 211.97 K -> differences %+.1f Pa, %+.1f K" % (744.665 - p8, 211.973 - T8))
po2 = 0.0016 * p8
D = 0.67 * (1 - 0.3 * (p8 - 820) / 820)
say("  with measured p: pO2 = %.3f Pa, dose (layer law) = %.4f mSv/day, dp/dh = -p/H = %.4f Pa/m" % (po2, D, -p8 / H))

# ----- 6. uncertainty with measured inputs (first order + Monte Carlo) -----
sp = sig_dia
spo2 = po2 * math.sqrt(0.10 ** 2 + (sp / p8) ** 2)
dD_dk = -0.67 * (p8 - 820) / 820; dD_dp = -0.67 * 0.3 / 820
sD = math.sqrt((D * 0.19) ** 2 + (dD_dk * 0.1) ** 2 + (dD_dp * sp) ** 2)
random.seed(1)
mc_p, mc_o, mc_d = [], [], []
for _ in range(20000):
    p = random.gauss(p8, sp); f = random.gauss(0.0016, 0.00016); k = random.gauss(0.3, 0.1); d0 = random.gauss(0.67, 0.67 * 0.19)
    mc_p.append(p); mc_o.append(f * p); mc_d.append(d0 * (1 - k * (p - 820) / 820))
say("\n[Uncertainty at A, sigma_p = day-to-day MEDA scatter %.2f Pa]" % sp)
say("  p    = %.2f +- %.2f Pa (MC %.2f +- %.2f)" % (p8, sp, mean(mc_p), std(mc_p)))
say("  pO2  = %.3f +- %.3f Pa (MC %.3f +- %.3f)" % (po2, spo2, mean(mc_o), std(mc_o)))
say("  dose = %.3f +- %.3f mSv/day (MC %.3f +- %.3f)" % (D, sD, mean(mc_d), std(mc_d)))

# ----- CSV for the report figures -----
with open(os.path.join(DATOS, "meda_por_sol.csv"), "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(["sol", "ls_mars24", "p_medida", "p_tendencia", "p_modelo"])
    for s in sorted(diario):
        w.writerow([s, round(ls_mars24(s), 2), round(diario[s], 2), round(c[0] + c[1] * (s - SOL_REF), 2),
                    round(p0_modelo(ls_modelo(s)) * math.exp(-H_A / H_LAYER), 2)])
pm = mean(list(pc.values()))
with open(os.path.join(DATOS, "meda_ciclo.csv"), "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(["hora", "p_anom", "p_fourier", "t_aire", "t_aire_min", "t_aire_max", "t_modelo", "t_reajuste", "t_suelo", "elev_sol"])
    for h in horas:
        w.writerow([h + 0.5, round(pc[h] - pm, 2), round(diurno(h + 0.5), 2), round(Tair[h], 2), round(Tmin_h[h], 2), round(Tmax_h[h], 2),
                    round(modT[h], 2), round(refT[h], 2), round(Tg[h], 2), round(elev[h], 2)])
open(os.path.join(DATOS, "meda_resumen.txt"), "w").write("\n".join(out) + "\n")

"""Ls of a Perseverance sol with the NASA GISS Mars24 algorithm (Allison & McEwen 2000)."""
import math, sys

def ls_of_msd(msd):
    jd_tt = msd * 1.0274912517 + 2405522.0028779
    dt = jd_tt - 2451545.0
    M = math.radians(19.3871 + 0.52402073 * dt)
    a_fms = 270.3871 + 0.524038496 * dt
    pbs = 0.0
    for A, tau, phi in [(0.0071, 2.2353, 49.409), (0.0057, 2.7543, 168.173), (0.0039, 1.1177, 191.837),
                        (0.0037, 15.7866, 21.736), (0.0021, 2.1354, 15.704), (0.0020, 2.4694, 95.528),
                        (0.0018, 32.8493, 49.095)]:
        pbs += A * math.cos(math.radians(0.985626 * dt / tau + phi))
    v_m = (10.691 + 3.0e-7 * dt) * math.sin(M) + 0.623 * math.sin(2 * M) + 0.050 * math.sin(3 * M) \
        + 0.005 * math.sin(4 * M) + 0.0005 * math.sin(5 * M) + pbs
    return (a_fms + v_m) % 360, jd_tt

M2020_SOL0_MSD = 52304  # Perseverance landing sol 0 (Mars24 / NASA GISS)
for s in [int(x) for x in sys.argv[1:]]:
    ls, jd = ls_of_msd(M2020_SOL0_MSD + s + 0.5)
    # JD(TT) -> calendar (approx UTC)
    import datetime
    d = datetime.datetime(2000, 1, 1, 12) + datetime.timedelta(days=jd - 2451545.0 - 69.184 / 86400)
    print(s, round(ls, 2), d.date())

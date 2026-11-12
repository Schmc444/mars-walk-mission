import math
from marswalk.geo import Site, R


def test_ground_roundtrip():
    s = Site(77.4, 18.48)
    e, so = s.to_ground(77.4 + 0.001, 18.48 - 0.001)
    assert abs(e - R * math.cos(math.radians(18.48)) * math.radians(0.001)) < 1e-6
    assert abs(so - R * math.radians(0.001)) < 1e-6


def test_axis_size_and_centre():
    s = Site(77.4, 18.48)
    E, S, lon, lat = s.axis_lonlat(45, 1)
    assert len(E) == len(lon) == 91
    assert abs(lon[45] - 77.4) < 1e-12 and abs(lat[45] - 18.48) < 1e-12

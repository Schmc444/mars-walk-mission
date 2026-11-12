"""Read a window of an uncompressed, stripped/tiled (Big)TIFF over HTTP range requests or from a local file (no GDAL)."""
import struct, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
import numpy as np

TYPES = {1: ("B", 1), 3: ("H", 2), 4: ("I", 4), 5: ("II", 8), 11: ("f", 4), 12: ("d", 8), 16: ("Q", 8), 2: ("c", 1)}


class RemoteBigTiff:
    def __init__(self, url, workers=10):
        self.url, self.workers = url, workers
        head = self._rng(0, 15)
        big = head[:4] == b"II+\x00"
        assert big or head[:4] == b"II*\x00", "only little-endian TIFF/BigTIFF supported"
        cw, ew, vw = (8, 20, 8) if big else (2, 12, 4)
        ifd = struct.unpack("<Q", head[8:16])[0] if big else struct.unpack("<I", head[4:8])[0]
        n = struct.unpack("<Q" if big else "<H", self._rng(ifd, ifd + cw - 1))[0]
        raw = self._rng(ifd + cw, ifd + cw + n * ew - 1)
        self.tags = {}
        for i in range(n):
            e = raw[i * ew:(i + 1) * ew]
            tag, typ = struct.unpack("<HH", e[:4])
            cnt = struct.unpack("<Q" if big else "<I", e[4:4 + vw])[0]
            val = e[4 + vw:]
            fmt, size = TYPES.get(typ, ("B", 1))
            if cnt * size <= vw:
                data = val[:cnt * size]
            else:
                off = struct.unpack("<Q" if big else "<I", val)[0]
                data = self._rng(off, off + cnt * size - 1)
            if typ == 2:
                self.tags[tag] = data.decode("latin1").rstrip("\0")
            elif typ == 5:
                self.tags[tag] = struct.unpack("<%dI" % (cnt * 2), data)
            else:
                self.tags[tag] = struct.unpack("<%d%s" % (cnt, fmt), data)
        t = self.tags
        self.width, self.height = t[256][0], t[257][0]
        self.bits = t[258][0]
        self.dtype = {(8, 1): "u1", (16, 1): "u2", (16, 2): "i2", (32, 3): "f4"}[(self.bits, t.get(339, (1,))[0])]
        assert t.get(259, (1,))[0] == 1, "compressed TIFF not supported"
        self.tiled = 322 in t
        self.px = t[33550][0]
        self.x0, self.y0 = t[33922][3], t[33922][4]

    def _rng(self, a, b):
        if not self.url.startswith("http"):
            with open(self.url, "rb") as f:
                f.seek(a)
                return f.read(b - a + 1)
        for attempt in range(8):
            try:
                r = urllib.request.Request(self.url, headers={"Range": "bytes=%d-%d" % (a, b)})
                return urllib.request.urlopen(r, timeout=120).read()
            except Exception:
                if attempt == 7:
                    raise
                time.sleep(0.5 * 2 ** attempt)

    def window(self, x, y, w, h):
        """Pixel window (x, y, w, h) -> array (h, w). Reads in parallel."""
        bps = self.bits // 8
        out = np.zeros((h, w), dtype=self.dtype)
        if self.tiled:
            tw, th = self.tags[322][0], self.tags[323][0]
            offs, cnts = self.tags[324], self.tags[325]
            tpr = (self.width + tw - 1) // tw
            jobs = [(tx, ty) for ty in range(y // th, (y + h - 1) // th + 1) for tx in range(x // tw, (x + w - 1) // tw + 1)]

            def get_tile(j):
                tx, ty = j
                k = ty * tpr + tx
                tile = np.frombuffer(self._rng(offs[k], offs[k] + cnts[k] - 1), dtype=self.dtype).reshape(th, tw)
                sx0, sy0 = max(x, tx * tw), max(y, ty * th)
                sx1, sy1 = min(x + w, (tx + 1) * tw), min(y + h, (ty + 1) * th)
                out[sy0 - y:sy1 - y, sx0 - x:sx1 - x] = tile[sy0 - ty * th:sy1 - ty * th, sx0 - tx * tw:sx1 - tx * tw]
            with ThreadPoolExecutor(self.workers) as ex:
                list(ex.map(get_tile, jobs))
        else:
            rps = self.tags[278][0]
            offs = self.tags[273]

            def get_row(r):
                s, rr = divmod(r, rps)
                a = offs[s] + (rr * self.width + x) * bps
                out[r - y] = np.frombuffer(self._rng(a, a + w * bps - 1), dtype=self.dtype)
            with ThreadPoolExecutor(self.workers) as ex:
                list(ex.map(get_row, range(y, y + h)))
        return out

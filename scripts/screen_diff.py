#!/usr/bin/env python3
"""Fraction of pixels that differ between two screenshots (reduced to 320x200 with sips; top strip ignored).

  screen_diff.py a.png b.png  → prints the fraction (0..1)
"""
import os, struct, subprocess, sys, tempfile


def pixels(path):
    out = os.path.join(tempfile.mkdtemp(), "x.bmp")
    subprocess.run(["sips", "-s", "format", "bmp", "-z", "200", "320", path, "--out", out], check=True, capture_output=True)
    data = open(out, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (w * bpp + 3) & ~3
    rows = []
    for y in range(abs(h)):
        r = data[offset + y * row: offset + y * row + w * bpp]
        rows.append([r[x * bpp: x * bpp + 3] for x in range(w)])
    if h > 0:
        rows.reverse()  # bottom-up BMP → top row first
    return rows


a, b = pixels(sys.argv[1]), pixels(sys.argv[2])
diff = total = 0
for y in range(8, min(len(a), len(b))):
    for pa, pb in zip(a[y], b[y]):
        total += 1
        if any(abs(pa[i] - pb[i]) > 24 for i in range(3)):
            diff += 1
print(f"{diff / max(total, 1):.4f}")

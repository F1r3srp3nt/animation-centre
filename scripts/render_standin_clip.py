#!/usr/bin/env python3
"""Render the HCG Orbital Command STAND-IN clip (original artwork, generated).

The real 4K "HCG Orbital Command" clip was not available when the first milestone was built, so the sample pack uses
this generated clip with the same delivery spec: 3840x2160, H.264 (avc1) MP4, 30 fps, no audio, a seamless 12-second
loop (every motion has a period that divides 12 s). Replace it with the real clip with scripts/make-sample-pack.sh
--clip <file>.

Usage: render_standin_clip.py <output.mp4> [--width 3840 --height 2160 --seconds 12 --fps 30]
"""
import argparse
import math
import random
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

BG = (8, 12, 18)
CYAN = (0, 217, 255)
BLUE = (23, 139, 255)
SILVER = (217, 226, 235)
MUTED = (100, 119, 139)


def font(size, bold=False):
    for path in (
        "/usr/share/fonts/opentype/inter/Inter-SemiBold.otf" if bold else "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def static_layer(w, h):
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    rnd = random.Random(7)
    for _ in range(int(w * h / 9000)):
        x, y = rnd.randrange(w), rnd.randrange(h)
        b = rnd.randrange(60, 200)
        r = rnd.choice((1, 1, 1, 2))
        d.ellipse((x - r, y - r, x + r, y + r), fill=(b, b, min(255, b + 20)))
    s = w / 3840
    grid = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(grid)
    step = int(160 * s)
    for x in range(0, w, step):
        g.line((x, 0, x, h), fill=(*BLUE, 16), width=max(1, int(s)))
    for y in range(0, h, step):
        g.line((0, y, w, y), fill=(*BLUE, 16), width=max(1, int(s)))
    img.paste(grid, (0, 0), grid)
    return img


def orbits(w, h):
    s = w / 3840
    cx, cy = w * 0.5, h * 0.52
    return cx, cy, s, [
        # (rx, ry, tilt_deg, revolutions per loop, phase, colour, size)
        (620 * s, 230 * s, -12, 2, 0.0, CYAN, 22 * s),
        (980 * s, 360 * s, 8, 1, 0.35, SILVER, 28 * s),
        (1380 * s, 520 * s, -4, -1, 0.7, BLUE, 34 * s),
        (1760 * s, 660 * s, 14, 3, 0.15, CYAN, 18 * s),
    ]


def point_on(cx, cy, rx, ry, tilt, a):
    x, y = rx * math.cos(a), ry * math.sin(a)
    t = math.radians(tilt)
    return cx + x * math.cos(t) - y * math.sin(t), cy + x * math.sin(t) + y * math.cos(t)


def draw_ring(d, cx, cy, rx, ry, tilt, colour, alpha, width):
    pts = [point_on(cx, cy, rx, ry, tilt, 2 * math.pi * i / 360) for i in range(361)]
    d.line(pts, fill=(*colour, alpha), width=width)


def frame(base, w, h, t, period):
    cx, cy, s, rings = orbits(w, h)
    img = base.copy()
    over = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    phase = t / period
    # radar sweep: one turn every period/2
    sweep = 360 * (2 * phase % 1)
    R = 1900 * s
    for k in range(24):
        d.pieslice((cx - R, cy - R, cx + R, cy + R), sweep - k * 1.5 - 1.5, sweep - k * 1.5, fill=(*CYAN, max(0, 34 - k)))
    for rx, ry, tilt, rev, ph, col, size in rings:
        draw_ring(d, cx, cy, rx, ry, tilt, col, 70, max(2, int(3 * s)))
    # core: pulses four times per loop
    pulse = 0.5 + 0.5 * math.sin(2 * math.pi * 4 * phase)
    for k, a in ((260, 40), (200, 70), (150, 120)):
        r = (k + 30 * pulse) * s
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(*CYAN, a), width=max(2, int(4 * s)))
    r = 110 * s
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(*BLUE, 150))
    r = 70 * s
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(*CYAN, 210))
    # satellites with short trails
    for rx, ry, tilt, rev, ph, col, size in rings:
        for k in range(14, -1, -1):
            a = 2 * math.pi * (rev * phase + ph) - k * 0.035 * (1 if rev > 0 else -1)
            x, y = point_on(cx, cy, rx, ry, tilt, a)
            rr = size * (1 - k / 18)
            alpha = 255 if k == 0 else int(120 * (1 - k / 15))
            d.ellipse((x - rr, y - rr, x + rr, y + rr), fill=(*col, alpha))
    glow = over.filter(ImageFilter.GaussianBlur(radius=max(2, int(10 * s))))
    img.paste(glow, (0, 0), glow)
    img.paste(over, (0, 0), over)
    # typography
    t2 = ImageDraw.Draw(img)
    t2.text((160 * s, 140 * s), "HCG ORBITAL COMMAND", font=font(int(120 * s), True), fill=SILVER)
    t2.text((164 * s, 290 * s), "HAKMI CAPITAL GROUP  ·  ANIMATION CENTER", font=font(int(46 * s)), fill=CYAN)
    t2.text((164 * s, h - 200 * s), "STAND-IN CLIP · replace with the 4K HCG Orbital Command master",
            font=font(int(40 * s)), fill=MUTED)
    t2.text((w - 760 * s, h - 200 * s), f"T+{t:05.2f}s  LOOP {period:.0f}s", font=font(int(40 * s)), fill=MUTED)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=2160)
    ap.add_argument("--seconds", type=float, default=12.0)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--crf", type=int, default=26)
    a = ap.parse_args()
    w, h, n = a.width, a.height, int(round(a.seconds * a.fps))
    base = static_layer(w, h)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
           "-r", str(a.fps), "-i", "-", "-an", "-c:v", "libx264", "-preset", "slow", "-crf", str(a.crf),
           "-pix_fmt", "yuv420p", "-profile:v", "high", "-level", "5.1", "-tag:v", "avc1", "-g", str(a.fps * 2),
           "-movflags", "+faststart", "-metadata", "title=HCG Orbital Command (stand-in)", a.output]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for i in range(n):
        p.stdin.write(frame(base, w, h, i / a.fps, a.seconds).tobytes())
        if i % 60 == 0:
            print(f"frame {i}/{n}", file=sys.stderr, flush=True)
    p.stdin.close()
    sys.exit(p.wait())


if __name__ == "__main__":
    main()

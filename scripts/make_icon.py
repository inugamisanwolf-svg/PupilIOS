#!/usr/bin/env python3
"""Generate the PupilIOS AppIcon (1024x1024 PNG) with Pillow.

Pure geometry (no font dependency) so the result is identical on any machine.
Motif: a "P" whose bowl doubles as a camera/lens pupil, on a dark indigo field.

    python scripts/make_icon.py
"""
from __future__ import annotations

import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling factor
W = SIZE * SS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")
OUT_PNG = os.path.join(OUT_DIR, "AppIcon-1024.png")

BG_INNER = (28, 22, 58)      # #1C163A indigo
BG_OUTER = (7, 7, 16)        # #070710 near black
ACCENT_A = (139, 92, 246)    # #8B5CF6 violet
ACCENT_B = (240, 54, 156)    # #F0369C magenta
PUPIL = (245, 243, 255)      # #F5F3FF


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def mix(c1, c2, t: float):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def radial_background() -> Image.Image:
    """Vertical + radial falloff blend (computed low-res, upscaled — it is smooth)."""
    g = 192
    img = Image.new("RGB", (g, g), BG_OUTER)
    px = img.load()
    cx, cy = g * 0.42, g * 0.34
    max_r = math.hypot(g, g) * 0.62
    for y in range(g):
        dy2 = (y - cy) ** 2
        ty = y / (g - 1)
        row_base = mix(BG_INNER, BG_OUTER, min(1.0, ty * 0.85 + 0.10))
        for x in range(g):
            r = min(1.0, math.sqrt((x - cx) ** 2 + dy2) / max_r)
            k = r ** 1.6
            px[x, y] = (
                int(lerp(row_base[0], BG_OUTER[0], k)),
                int(lerp(row_base[1], BG_OUTER[1], k)),
                int(lerp(row_base[2], BG_OUTER[2], k)),
            )
    return img.resize((W, W), Image.BICUBIC)


def accent_layer() -> Image.Image:
    g = 192
    img = Image.new("RGB", (g, g), ACCENT_A)
    px = img.load()
    for y in range(g):
        ty = y / (g - 1)
        for x in range(g):
            t = min(1.0, max(0.0, ty * 0.72 + (x / (g - 1)) * 0.28))
            px[x, y] = mix(ACCENT_A, ACCENT_B, t)
    return img.resize((W, W), Image.BICUBIC)


def _blob_box(cx: int, cy: int, r: int):
    return [cx - r, cy - r, cx + r, cy + r]


def p_mask() -> Image.Image:
    """Mask for the 'P': rounded stem + bowl ring (counter tangent to the stem)
    with a pupil dot sitting in the counter."""
    zero = Image.new("L", (W, W), 0)

    stem_x0 = int(W * 0.255)
    stem_w = int(W * 0.140)
    stem_x1 = stem_x0 + stem_w
    stem_y0 = int(W * 0.215)
    stem_y1 = int(W * 0.800)

    stem = zero.copy()
    ImageDraw.Draw(stem).rounded_rectangle(
        [stem_x0, stem_y0, stem_x1, stem_y1], radius=stem_w // 2, fill=255
    )

    # bowl: outer disc and counter share one centre, so the ring width is even and
    # the counter's left edge lands exactly on the stem's right edge (real 'P' shape)
    inner_r = int(W * 0.096)
    ring_w = int(W * 0.076)
    outer_r = inner_r + ring_w
    cx = stem_x1 + inner_r
    cy = stem_y0 + outer_r

    outer = zero.copy()
    ImageDraw.Draw(outer).ellipse(_blob_box(cx, cy, outer_r), fill=255)
    inner = zero.copy()
    ImageDraw.Draw(inner).ellipse(_blob_box(cx, cy, inner_r), fill=255)
    bowl_ring = ImageChops.subtract(outer, inner)

    m = ImageChops.lighter(stem, bowl_ring)

    # lens ring outline for depth
    halo = zero.copy()
    ImageDraw.Draw(halo).ellipse(
        _blob_box(cx, cy, int(W * 0.310)), outline=80, width=int(W * 0.010)
    )
    m = ImageChops.lighter(m, halo)

    # pupil dot centred in the counter
    dot = zero.copy()
    ImageDraw.Draw(dot).ellipse(_blob_box(cx, cy, int(W * 0.050)), fill=235)
    m = ImageChops.lighter(m, dot)
    return m


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    bg = radial_background()
    acc = accent_layer()
    mask = p_mask()

    # soft glow behind the mark
    glow = mask.filter(ImageFilter.GaussianBlur(radius=W * 0.02))
    glow = glow.point(lambda v: int(v * 0.55))
    bg = Image.composite(acc, bg, glow)

    bg = Image.composite(acc, bg, mask)
    icon = bg.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(OUT_PNG, "PNG", optimize=True)
    print("wrote", OUT_PNG, icon.size)


if __name__ == "__main__":
    main()

"""Builds the mod icon and the Workshop preview from one square PNG.

    python3 dev/make_icon.py [dev/art/icon_source.png]

Writes AutoOrganizeChests.tex (DST KTEX texture, DXT5, 128x128 with 8 mip levels, the same layout as the
original icon) and dev/workshop/preview.png (512x512). AutoOrganizeChests.xml stays as it is.
"""
import os
import struct
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "art", "icon_source.png")
KTEX_SPEC = 0xFFF10220  # platform 0, DXT5, 2D texture, 8 mips, no flags: the header of the original icon


def to565(c):
    r, g, b = (max(0, min(255, int(round(v)))) for v in c)
    return ((r * 31 + 127) // 255) << 11 | ((g * 63 + 127) // 255) << 5 | ((b * 31 + 127) // 255)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def principal_axis(pixels):
    n = len(pixels)
    mean = [sum(p[i] for p in pixels) / n for i in range(3)]
    cov = [[sum((p[i] - mean[i]) * (p[j] - mean[j]) for p in pixels) for j in range(3)] for i in range(3)]
    axis = [1.0, 1.0, 1.0]
    for _ in range(8):
        axis = [sum(cov[i][j] * axis[j] for j in range(3)) for i in range(3)]
        length = sum(a * a for a in axis) ** 0.5
        if length < 1e-9:
            return mean, None
        axis = [a / length for a in axis]
    return mean, axis


def color_block(pixels):
    mean, axis = principal_axis(pixels)
    if axis is None:
        c0 = c1 = to565(mean)
    else:
        t = [sum((p[i] - mean[i]) * axis[i] for i in range(3)) for p in pixels]
        lo, hi = min(t), max(t)
        inset = (hi - lo) / 16
        lo, hi = lo + inset, hi - inset
        c0 = to565([mean[i] + hi * axis[i] for i in range(3)])
        c1 = to565([mean[i] + lo * axis[i] for i in range(3)])
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        return struct.pack("<HHI", c0, c1, 0)
    p0, p1 = from565(c0), from565(c1)
    palette = [p0, p1, tuple((2 * a + b) / 3 for a, b in zip(p0, p1)), tuple((a + 2 * b) / 3 for a, b in zip(p0, p1))]
    bits = 0
    for i, p in enumerate(pixels):
        best = min(range(4), key=lambda k: sum((p[c] - palette[k][c]) ** 2 for c in range(3)))
        bits |= best << (2 * i)
    return struct.pack("<HHI", c0, c1, bits)


def alpha_block(alphas):
    a0, a1 = max(alphas), min(alphas)
    if a0 == a1:
        return bytes([a0, a1, 0, 0, 0, 0, 0, 0])
    palette = [a0, a1] + [((7 - k) * a0 + k * a1) / 7 for k in range(1, 7)]
    bits = 0
    for i, a in enumerate(alphas):
        best = min(range(8), key=lambda k: abs(a - palette[k]))
        bits |= best << (3 * i)
    return bytes([a0, a1]) + bits.to_bytes(6, "little")


def dxt5(image):
    w, h = image.size
    px = image.load()
    out = bytearray()
    for by in range(0, max(h, 4), 4):
        for bx in range(0, max(w, 4), 4):
            block = [px[min(bx + x, w - 1), min(by + y, h - 1)] for y in range(4) for x in range(4)]
            out += alpha_block([p[3] for p in block]) + color_block([p[:3] for p in block])
    return bytes(out)


def main():
    source = Image.open(SOURCE).convert("RGBA")
    headers, data = b"", b""
    for level in range(8):
        size = 128 >> level
        # KTEX stores rows bottom-up
        mip = source.resize((size, size), Image.LANCZOS).transpose(Image.FLIP_TOP_BOTTOM)
        block = dxt5(mip)
        headers += struct.pack("<HHHI", size, size, 0, len(block))
        data += block
    with open(os.path.join(ROOT, "AutoOrganizeChests.tex"), "wb") as f:
        f.write(b"KTEX" + struct.pack("<I", KTEX_SPEC) + headers + data)
    preview = Image.new("RGB", source.size, (40, 34, 28))
    preview.paste(source, mask=source.split()[3])
    preview.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "workshop", "preview.png"), optimize=True)
    print("icon and preview written from", SOURCE)


main()

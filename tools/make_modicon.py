"""Build the Mods-menu icon (modicon.png + modicon.tex) from vanilla art.

The icon is a vanilla item icon (`book_research_station` by default) placed inside
the game's default portrait frame (`images/ui.xml` → `portrait_bg.tex`), the same
frame the Mods screen shows when a mod has no icon.

The game only reads KTEX textures, and ktools' `ktech` is not installed here, so
this script contains a small DXT5 KTEX writer. KTEX stores premultiplied alpha
(the preview decoder in `tests/preview/render.py` un-premultiplies when it reads
a texture), so RGB is premultiplied before encoding; the PNG source stays straight.

Usage:
    python tools/make_modicon.py [--game-data DIR] [--prefab book_research_station]

The `.tex` header and mip layout were copied from a known-good ktech file, so the
output is accepted by `scripts/modindex.lua` icon loading. `modicon.xml` is static
and already checked in.
"""

import argparse
import os
import struct
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests", "preview"))

import render  # noqa: E402  (path set above)

DEFAULT_GAME_DATA = r"C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\data\databundles"
ICON_ATLAS = "images/inventoryimages1.xml"
FRAME_ATLAS = "images/ui.xml"
FRAME_TEX = "portrait_bg.tex"
FRAME_SCALE = 2          # frame is 128x128 -> 256x256
ICON_SCALE = 3           # 64x64 book -> 192x192, inside the frame's inner field
SIZE = 256


# -- DXT5 -------------------------------------------------------------------

def pack565(r, g, b):
    return ((r * 31 // 255) << 11) | ((g * 63 // 255) << 5) | (b * 31 // 255)


def unpack565(c):
    return (((c >> 11) & 31) * 255 // 31,
            ((c >> 5) & 63) * 255 // 63,
            (c & 31) * 255 // 31)


def encode_block(px):
    alphas = [p[3] for p in px]
    a0, a1 = max(alphas), min(alphas)
    if a0 == a1:
        abits = 0
    else:
        pal = [a0, a1] + [((7 - i) * a0 + (i - 1) * a1) // 7 for i in range(2, 8)]
        abits = 0
        for i, a in enumerate(alphas):
            abits |= min(range(8), key=lambda j: abs(pal[j] - a)) << (3 * i)
    alpha = bytes((a0, a1)) + abits.to_bytes(6, "little")

    c0 = pack565(max(p[0] for p in px), max(p[1] for p in px), max(p[2] for p in px))
    c1 = pack565(min(p[0] for p in px), min(p[1] for p in px), min(p[2] for p in px))
    if c0 < c1:
        c0, c1 = c1, c0
    p0, p1 = unpack565(c0), unpack565(c1)
    if c0 > c1:
        pal = [p0, p1,
               tuple((2 * p0[i] + p1[i]) // 3 for i in range(3)),
               tuple((p0[i] + 2 * p1[i]) // 3 for i in range(3))]
    else:
        pal = [p0, p1, tuple((p0[i] + p1[i]) // 2 for i in range(3)), (0, 0, 0)]
    cbits = 0
    for i, p in enumerate(px):
        cbits |= min(range(4), key=lambda j: sum((pal[j][k] - p[k]) ** 2 for k in range(3))) << (2 * i)
    return alpha + struct.pack("<HHI", c0, c1, cbits)


def encode_mip(img):
    w, h = img.size
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    canvas = Image.new("RGBA", (bw * 4, bh * 4), (0, 0, 0, 0))
    canvas.paste(img, (0, 0))
    px = canvas.load()
    out = bytearray()
    for by in range(bh):
        for bx in range(bw):
            block = [px[bx * 4 + x, by * 4 + y] for y in range(4) for x in range(4)]
            out += encode_block(block)
    return bytes(out)


def premultiply(img):
    """Return a copy with RGB scaled by alpha (KTex stores premultiplied alpha)."""
    out = img.copy()
    src, dst = img.load(), out.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = src[x, y]
            dst[x, y] = (r * a // 255, g * a // 255, b * a // 255, a)
    return out


def write_ktex(path, img):
    img = premultiply(img.convert("RGBA"))
    if img.width % 4 or img.height % 4:
        raise ValueError("size must be a multiple of 4")
    entries, blobs = [], []
    cur = img
    while True:
        # KTEX stores rows bottom-up (verified against existing modicon.tex).
        data = encode_mip(cur.transpose(Image.FLIP_TOP_BOTTOM))
        entries.append((cur.width, cur.height, ((cur.width + 3) // 4) * 16, len(data)))
        blobs.append(data)
        if cur.width == 1 and cur.height == 1:
            break
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)), Image.LANCZOS)
    # Known-good 256x256 DXT5 header (0xFFFD2220): 0xFFF little-endian marker,
    # 9 mips, DXT5, flags in bits 18-19. Only the mip count is recomputed.
    header = (0xFFFD2220 & ~(0x1F << 13)) | (len(entries) << 13)
    out = bytearray(b"KTEX" + struct.pack("<I", header))
    for e in entries:
        out += struct.pack("<HHHI", *e)
    for b in blobs:
        out += b
    with open(path, "wb") as f:
        f.write(out)


# -- composition ------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-data", default=os.environ.get("DST_DATA", DEFAULT_GAME_DATA))
    parser.add_argument("--prefab", default="book_research_station")
    parser.add_argument("--out", default=ROOT)
    args = parser.parse_args()

    game = render.GameData(args.game_data)
    icon = game.image(ICON_ATLAS, args.prefab + ".tex")
    if icon is None:
        raise SystemExit("icon %r not found in %s" % (args.prefab, ICON_ATLAS))
    frame = game.image(FRAME_ATLAS, FRAME_TEX)
    if frame is None:
        raise SystemExit("frame %r not found in %s" % (FRAME_TEX, FRAME_ATLAS))

    # Straight-alpha canvas; write_ktex premultiplies a copy for the texture.
    canvas = frame.resize((SIZE, SIZE), Image.LANCZOS)
    big = icon.resize((icon.width * ICON_SCALE, icon.height * ICON_SCALE), Image.NEAREST)
    canvas.alpha_composite(big, ((SIZE - big.width) // 2, (SIZE - big.height) // 2))

    png_path = os.path.join(args.out, "modicon.png")
    tex_path = os.path.join(args.out, "modicon.tex")
    canvas.save(png_path)
    write_ktex(tex_path, canvas)
    print("wrote", png_path)
    print("wrote", tex_path)


if __name__ == "__main__":
    main()

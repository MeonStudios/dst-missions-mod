"""Render tests/preview/out.json (produced by dump.lua) to PNG files.

Uses the game's real atlases and fonts, so the preview matches what the card
drawn from scripts/widgets/guidedmissiontracker.lua looks like in game.

    python tests/preview/render.py [--game-data PATH] [--out DIR] [--scale N]

Requires Pillow (`pip install pillow`) and Python 3.8+.
"""

import argparse
import io
import json
import math
import os
import sys
import xml.etree.ElementTree as ET
import zipfile

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")

DEFAULT_GAME_DATA = r"C:\Program Files (x86)\Steam\steamapps\common\Don't Starve Together\data\databundles"
HERE = os.path.dirname(os.path.abspath(__file__))
MOD_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

FONT_FILES = {
    "belisaplumilla50": "fonts/belisaplumilla50.zip",
    "stint-ucr50": "fonts/stint-ucr50.zip",
    "spirequal_outline": "fonts/spirequal_outline.zip",
}

BG_COLOUR = (42, 33, 24, 255)
RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS
ROTATE_RESAMPLE = getattr(Image, "Resampling", Image).BICUBIC


# --------------------------------------------------------------------------
# KTEX
# --------------------------------------------------------------------------

def rgb565(v):
    return ((v >> 11) & 31) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31


def decode_dxt5_block(b):
    a0, a1 = b[0], b[1]
    abits = int.from_bytes(b[2:8], "little")
    alpha = [a0, a1]
    if a0 > a1:
        alpha += [((7 - i) * a0 + (i - 1) * a1) // 7 for i in range(2, 8)]
    else:
        alpha += [((5 - i) * a0 + (i - 1) * a1) // 5 for i in range(2, 6)] + [0, 255]
    c0, c1 = int.from_bytes(b[8:10], "little"), int.from_bytes(b[10:12], "little")
    bits = int.from_bytes(b[12:16], "little")
    c = [rgb565(c0), rgb565(c1)]
    if c0 > c1:
        c += [tuple((2 * c[0][i] + c[1][i]) // 3 for i in range(3)),
              tuple((c[0][i] + 2 * c[1][i]) // 3 for i in range(3))]
    else:
        c += [tuple((c[0][i] + c[1][i]) // 2 for i in range(3)), (0, 0, 0)]
    px = []
    for p in range(16):
        ai = (abits >> (3 * p)) & 7
        ci = (bits >> (2 * p)) & 3
        r, g, bl = c[ci]
        a = alpha[ai]
        if 0 < a < 255:
            r = min(255, r * 255 // a)
            g = min(255, g * 255 // a)
            bl = min(255, bl * 255 // a)
        px.append((r, g, bl, a))
    return px


class Ktex:
    def __init__(self, data):
        if data[:4] != b"KTEX":
            raise ValueError("not a KTEX file")
        little = int.from_bytes(data[4:8], "little")
        big = int.from_bytes(data[4:8], "big")
        lfill = (little >> 20) & 0xFFF
        bfill = (big >> 20) & 0xFFF
        self.le = lfill == 0xFFF or bfill != 0xFFF
        header = little if self.le else big
        self.compression = (header >> 4) & 0x1F
        self.mip_count = (header >> 13) & 0x1F
        order = "little" if self.le else "big"
        self.mips = []
        cursor = 8
        for _ in range(self.mip_count):
            width = int.from_bytes(data[cursor:cursor + 2], order)
            height = int.from_bytes(data[cursor + 2:cursor + 4], order)
            pitch = int.from_bytes(data[cursor + 4:cursor + 6], order)
            size = int.from_bytes(data[cursor + 6:cursor + 10], order)
            self.mips.append((width, height, pitch, size))
            cursor += 10
        self.data = data[cursor:]

    @property
    def width(self):
        return self.mips[0][0]

    @property
    def height(self):
        return self.mips[0][1]

    def base_pixels(self):
        """Decode the top mip to a top-down RGBA bytearray."""
        if self.compression != 2:
            raise NotImplementedError("only DXT5 KTEX is supported (found %d)" % self.compression)
        w, h, _, size = self.mips[0]
        src = self.data[:size]
        stride_blocks = w // 4
        out = bytearray(w * h * 4)
        for by in range(h // 4):
            row_off = by * stride_blocks * 16
            for bx in range(stride_blocks):
                block = src[row_off + bx * 16: row_off + bx * 16 + 16]
                px = decode_dxt5_block(block)
                base_x = bx * 4
                base_y = by * 4
                for p, (r, g, b, a) in enumerate(px):
                    x = base_x + p % 4
                    # Stored data is bottom-up; write directly into top-down rows.
                    y = (h - 1) - (base_y + p // 4)
                    off = (y * w + x) * 4
                    out[off:off + 4] = bytes((r, g, b, a))
        return w, h, out

    def region(self, x1, y1, x2, y2):
        """Crop in stored-texture coordinates, returned in display (top-down) orientation."""
        if self.compression != 2:
            raise NotImplementedError("only DXT5 KTEX is supported")
        w, h, _, size = self.mips[0]
        src = self.data[:size]
        stride_blocks = w // 4
        cw, ch = x2 - x1, y2 - y1
        out = bytearray(cw * ch * 4)
        for by in range(y1 // 4, (y2 + 3) // 4):
            for bx in range(x1 // 4, (x2 + 3) // 4):
                off = (by * stride_blocks + bx) * 16
                px = decode_dxt5_block(src[off:off + 16])
                for p, (r, g, b, a) in enumerate(px):
                    x = bx * 4 + p % 4
                    y = by * 4 + p // 4
                    if x1 <= x < x2 and y1 <= y < y2:
                        # Flip vertically: stored row y -> displayed row y2-1-y.
                        dx = x - x1
                        dy = (y2 - 1 - y)
                        doff = (dy * cw + dx) * 4
                        out[doff:doff + 4] = bytes((r, g, b, a))
        return Image.frombytes("RGBA", (cw, ch), bytes(out))


# --------------------------------------------------------------------------
# Game data (atlases + fonts)
# --------------------------------------------------------------------------

class GameData:
    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.images_zip = zipfile.ZipFile(os.path.join(data_dir, "images.zip"))
        self.fonts_zip = zipfile.ZipFile(os.path.join(data_dir, "fonts.zip"))
        self._tex_cache = {}
        self._frame_cache = {}
        self._image_cache = {}
        self._font_cache = {}

    def frames(self, atlas_path):
        if atlas_path not in self._frame_cache:
            xml = self.images_zip.read(atlas_path)
            root = ET.fromstring(xml)
            frames = {}
            for el in root.iter("Element"):
                frames[el.get("name")] = (
                    float(el.get("u1")), float(el.get("v1")),
                    float(el.get("u2")), float(el.get("v2")),
                )
            self._frame_cache[atlas_path] = frames
        return self._frame_cache[atlas_path]

    def texture(self, atlas_path):
        if atlas_path not in self._tex_cache:
            tex_path = atlas_path[:-4] + ".tex" if atlas_path.endswith(".xml") else atlas_path
            self._tex_cache[atlas_path] = Ktex(self.images_zip.read(tex_path))
        return self._tex_cache[atlas_path]

    def image(self, atlas_path, tex_name):
        key = (atlas_path, tex_name)
        if key in self._image_cache:
            return self._image_cache[key]
        frames = self.frames(atlas_path)
        if tex_name not in frames:
            print("WARNING: %s not in %s" % (tex_name, atlas_path))
            self._image_cache[key] = None
            return None
        u1, v1, u2, v2 = frames[tex_name]
        tex = self.texture(atlas_path)
        w, h = tex.width, tex.height
        x1, x2 = round(u1 * w), round(u2 * w)
        y1, y2 = round(v1 * h), round(v2 * h)
        img = tex.region(x1, y1, x2, y2)
        self._image_cache[key] = img
        return img

    def font(self, name):
        if name in self._font_cache:
            return self._font_cache[name]
        inner_path = FONT_FILES.get(name)
        if inner_path is None:
            raise KeyError("unknown font %r" % name)
        inner = zipfile.ZipFile(io.BytesIO(self.fonts_zip.read(inner_path)))
        fnt = ET.fromstring(inner.read("font.fnt"))
        info = fnt.find("info")
        common = fnt.find("common")
        chars = {}
        for ch in fnt.find("chars").iter("char"):
            chars[int(ch.get("id"))] = {
                "x": int(ch.get("x")), "y": int(ch.get("y")),
                "w": int(ch.get("width")), "h": int(ch.get("height")),
                "xo": int(ch.get("xoffset")), "yo": int(ch.get("yoffset")),
                "xa": int(ch.get("xadvance")),
            }
        atlas = Ktex(inner.read("font.tex"))
        w, h, pixels = atlas.base_pixels()
        image = Image.frombytes("RGBA", (w, h), bytes(pixels))
        font = {
            "size": int(info.get("size")),
            "line_height": int(common.get("lineHeight")),
            "base": int(common.get("base")),
            "chars": chars,
            "image": image,
        }
        self._font_cache[name] = font
        return font


# --------------------------------------------------------------------------
# Renderer
# --------------------------------------------------------------------------

class Renderer:
    def __init__(self, game, scale):
        self.game = game
        self.S = scale
        # DST local (0,0) maps to (X_OFF, Y_OFF) design pixels; y flips.
        self.X_OFF = 40
        self.Y_OFF = 460
        self.canvas_w = int(900 * self.S)
        self.canvas_h = int(800 * self.S)
        self.canvas = Image.new("RGBA", (self.canvas_w, self.canvas_h), (0, 0, 0, 0))

    def to_px(self, x, y):
        return (x + self.X_OFF) * self.S, (self.Y_OFF - y) * self.S

    def paste_clipped(self, tile, left, top, clip):
        rect = (int(round(left)), int(round(top)),
                int(round(left + tile.width)), int(round(top + tile.height)))
        if clip:
            rect = (max(rect[0], clip[0]), max(rect[1], clip[1]),
                    min(rect[2], clip[2]), min(rect[3], clip[3]))
        if rect[2] <= rect[0] or rect[3] <= rect[1]:
            return
        if clip:
            crop = (rect[0] - int(round(left)), rect[1] - int(round(top)),
                    rect[2] - int(round(left)), rect[3] - int(round(top)))
            tile = tile.crop(crop)
        self.canvas.alpha_composite(tile, (rect[0], rect[1]))

    def draw_image(self, node, x, y, sx, sy, clip):
        src = self.game.image(node.get("atlas"), node.get("tex"))
        if src is None:
            return
        tw = max(1, int(round(node["w"] * abs(sx) * self.S)))
        th = max(1, int(round(node["h"] * abs(sy) * self.S)))
        tile = src.resize((tw, th), RESAMPLE)
        if sx < 0:
            tile = tile.transpose(Image.FLIP_LEFT_RIGHT)
        if sy < 0:
            tile = tile.transpose(Image.FLIP_TOP_BOTTOM)
        rotation = node.get("rot", 0) or 0
        if rotation:
            # DST's positive rotation is clockwise on screen; PIL's is CCW.
            tile = tile.rotate(-rotation, resample=ROTATE_RESAMPLE, expand=True)
        tw, th = tile.size
        r, g, b, a = node.get("tint", [1, 1, 1, 1])
        if (r, g, b, a) != (1, 1, 1, 1):
            if r != 1 or g != 1 or b != 1:
                chans = list(tile.split())
                chans[0] = chans[0].point(lambda v, m=r: int(v * m))
                chans[1] = chans[1].point(lambda v, m=g: int(v * m))
                chans[2] = chans[2].point(lambda v, m=b: int(v * m))
                tile = Image.merge("RGBA", chans)
            if a != 1:
                alpha = tile.split()[3].point(lambda v, m=a: int(v * m))
                tile.putalpha(alpha)
        cx, cy = self.to_px(x, y)
        self.paste_clipped(tile, cx - tw / 2, cy - th / 2, clip)

    def draw_text(self, node, x, y, sx, sy, clip):
        text = node.get("string") or ""
        if text == "":
            return
        font = self.game.font(node["font"])
        scale = node["size"] / float(font["size"]) * sx
        if scale == 0:
            return
        line_h = font["line_height"] * scale
        # DST Text honours embedded newlines; the hint tooltip is wrapped by the
        # tracker into such a string. Align and centre the block as a whole.
        lines = text.split("\n")
        line_widths = [
            sum(font["chars"].get(ord(c), {}).get("xa", 0) for c in line) * scale
            for line in lines
        ]
        total_w = max(line_widths) if line_widths else 0
        total_h = line_h * len(lines)
        region_w = node.get("region_w") or total_w
        region_h = node.get("region_h") or total_h
        halign = node.get("halign", 0)
        valign = node.get("valign", 0)

        region_top = y + region_h / 2
        if valign == 1:       # TOP
            block_top = region_top
        elif valign == 2:     # BOTTOM
            block_top = region_top - region_h + total_h
        else:                 # centre the whole block
            block_top = region_top - (region_h - total_h) / 2

        colour = node.get("colour", [1, 1, 1, 1])
        cr, cg, cb = (int(colour[0] * 255), int(colour[1] * 255), int(colour[2] * 255))
        ca = colour[3] if len(colour) > 3 else 1
        for line_index, line in enumerate(lines):
            if halign == 1:       # ANCHOR_LEFT
                pen = x - region_w / 2
            elif halign == 2:     # ANCHOR_RIGHT
                pen = x + region_w / 2 - line_widths[line_index]
            else:                 # centre each line
                pen = x - line_widths[line_index] / 2
            line_top = block_top - line_index * line_h

            for ch in line:
                glyph = font["chars"].get(ord(ch))
                if glyph is None:
                    continue
                gw = max(1, int(round(glyph["w"] * scale * self.S)))
                gh = max(1, int(round(glyph["h"] * scale * self.S)))
                if glyph["w"] > 0 and glyph["h"] > 0:
                    crop = font["image"].crop(
                        (glyph["x"], glyph["y"], glyph["x"] + glyph["w"], glyph["y"] + glyph["h"])
                    ).resize((gw, gh), RESAMPLE).convert("RGBA")
                    # The BMFont atlases bake the outline into the RGB channels:
                    # a white glyph face, a black outline, opaque alpha. Tint the
                    # glyph (multiply by the text colour) as the engine does, so
                    # black stays black. Repainting from the alpha channel alone
                    # would colour the outline too and lose it (letters look fat).
                    ca_i = ca
                    tile = Image.new("RGBA", (gw, gh))
                    tile.putdata([
                        (
                            r * cr // 255,
                            g * cg // 255,
                            b * cb // 255,
                            int(a * ca_i),
                        )
                        for (r, g, b, a) in crop.getdata()
                    ])
                    gx_center = pen + (glyph["xo"] + glyph["w"] / 2) * scale
                    gy_center = line_top - (glyph["yo"] + glyph["h"] / 2) * scale
                    cxp, cyp = self.to_px(gx_center, gy_center)
                    self.paste_clipped(tile, cxp - gw / 2, cyp - gh / 2, clip)
                pen += glyph["xa"] * scale

    def draw(self, node, px, py, psx, psy, clip):
        if not node.get("shown", True):
            return
        x = px + node["x"] * psx
        y = py + node["y"] * psy
        sx = psx * node["sx"]
        sy = psy * node["sy"]

        new_clip = clip
        if "scissor" in node:
            sx0, sy0, sw, sh = node["scissor"]
            left = int(round((x + sx0 + self.X_OFF) * self.S))
            right = int(round((x + sx0 + sw + self.X_OFF) * self.S))
            top = int(round((self.Y_OFF - (y + sy0 + sh)) * self.S))
            bottom = int(round((self.Y_OFF - (y + sy0)) * self.S))
            rect = (min(left, right), min(top, bottom), max(left, right), max(top, bottom))
            if clip:
                rect = (max(rect[0], clip[0]), max(rect[1], clip[1]),
                        min(rect[2], clip[2]), min(rect[3], clip[3]))
            new_clip = rect

        kind = node.get("kind")
        if kind == "Image":
            self.draw_image(node, x, y, sx, sy, new_clip)
        elif kind == "Text":
            self.draw_text(node, x, y, sx, sy, new_clip)

        for child in node.get("children", []):
            self.draw(child, x, y, sx, sy, new_clip)

    def save(self, path):
        bbox = self.canvas.getbbox()
        img = self.canvas
        if bbox:
            pad = int(12 * self.S)
            bbox = (max(0, bbox[0] - pad), max(0, bbox[1] - pad),
                    min(self.canvas_w, bbox[2] + pad), min(self.canvas_h, bbox[3] + pad))
            img = img.crop(bbox)
        bg = Image.new("RGBA", img.size, BG_COLOUR)
        bg.alpha_composite(img)
        bg.convert("RGB").save(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-data", default=os.environ.get("DST_DATA", DEFAULT_GAME_DATA))
    parser.add_argument("--out", default=os.path.join(HERE, "out"))
    parser.add_argument("--scale", type=int, default=2)
    parser.add_argument("--json", default=os.path.join(HERE, "out.json"))
    args = parser.parse_args()

    with open(args.json, encoding="utf-8") as fh:
        data = json.load(fh)

    game = GameData(args.game_data)
    os.makedirs(args.out, exist_ok=True)
    for scenario in data["scenarios"]:
        renderer = Renderer(game, args.scale)
        renderer.draw(scenario["tree"], 0, 0, 1, 1, None)
        path = os.path.join(args.out, scenario["name"] + ".png")
        renderer.save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()

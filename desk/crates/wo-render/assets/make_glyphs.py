#!/usr/bin/env python3
"""The ascii treatment's glyph ramp (v1: show_dance.dart _makeGlyphs): ` .:-=+*#%@`, light to
dense, white on clear, 24x40 a glyph side by side, monospace 34 px w600, each glyph
centred in its box. Made once; glyphs.png is what the stage ships.

    python3 make_glyphs.py [font.ttf]   (default: Noto Sans Mono Bold: what Skia asks fontconfig for at w600 on Linux's "monospace")
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

RAMP = " .:-=+*#%@"
GW, GH, SIZE = 24, 40, 34
font = ImageFont.truetype(sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/noto/NotoSansMono-Bold.ttf", SIZE)
img = Image.new("RGBA", (GW * len(RAMP), GH), (255, 255, 255, 0))
d = ImageDraw.Draw(img)
ascent, descent = font.getmetrics()
for i, ch in enumerate(RAMP):
    w = font.getlength(ch)
    # a line box of the font's size (Flutter's height: 1), centred in the glyph's box
    top = (GH - SIZE) / 2 + (SIZE - (ascent + descent)) / 2
    d.text((i * GW + (GW - w) / 2, top), ch, font=font, fill=(255, 255, 255, 255))
img.save(Path(__file__).with_name("glyphs.png"))

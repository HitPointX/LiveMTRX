#!/usr/bin/env python3
"""
Bake a glyph atlas PNG and JSON map from a font.

Usage:
    ./bake_atlas.py --font /Library/Fonts/SFMono-Regular.otf --size 20 --cell 20 --out assets/glyph_atlas.png --map assets/glyph_map.json

Generates a grid atlas of chosen glyphs and writes a JSON mapping with indices.
"""
import argparse
import json
from PIL import Image, ImageDraw, ImageFont
import os

DEFAULT_GLYPHS = (
    # ASCII
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789"
    "@#$%&*+=-:;.,!?/\\|[]{}()<>"
    # Katakana subset
    "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉ"
    # Greek subset
    "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"
    "αβγδεζηθικλμνξοπρστυφχψω"
    # Box drawing
    "│┃━─┌┐└┘├┤┬┴┼╭╮╰╯"
)


def bake(font_path: str, font_size: int, cell: int, cols: int, out_png: str, out_json: str, glyphs: str):
    font = ImageFont.truetype(font_path, font_size)
    rows = (len(glyphs) + cols - 1) // cols
    w = cols * cell
    h = rows * cell
    img = Image.new('RGBA', (w, h), (0,0,0,0))
    draw = ImageDraw.Draw(img)

    mapping = {}
    i = 0
    for ch in glyphs:
        cx = (i % cols) * cell
        cy = (i // cols) * cell
        # center glyph in cell
        bbox = font.getbbox(ch)
        gw = bbox[2] - bbox[0]
        gh = bbox[3] - bbox[1]
        gx = cx + (cell - gw) // 2 - bbox[0]
        gy = cy + (cell - gh) // 2 - bbox[1]
        draw.text((gx, gy), ch, font=font, fill=(255,255,255,255))
        mapping[ch] = i
        i += 1

    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    img.save(out_png)
    meta = {
        'cell': cell,
        'cols': cols,
        'rows': rows,
        'count': i,
        'mapping': mapping,
    }
    with open(out_json, 'w') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--font', required=True)
    p.add_argument('--size', type=int, default=18)
    p.add_argument('--cell', type=int, default=20)
    p.add_argument('--cols', type=int, default=32)
    p.add_argument('--out', default='assets/glyph_atlas.png')
    p.add_argument('--map', default='assets/glyph_map.json')
    p.add_argument('--glyphs', default=None)
    args = p.parse_args()

    glyphs = args.glyphs if args.glyphs is not None else DEFAULT_GLYPHS
    bake(args.font, args.size, args.cell, args.cols, args.out, args.map, glyphs)

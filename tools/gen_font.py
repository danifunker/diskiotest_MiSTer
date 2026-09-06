#!/usr/bin/env python3
"""Generate rtl/font8x8.hex from Main_MiSTer's OSD font (charrom.cpp, GPL).

charrom.cpp stores every glyph as 8 column bytes (bit 0 = top row).
The video renderer wants 8 row bytes per glyph with bit 7 = leftmost pixel,
so the table is transposed here. 256 glyphs are emitted (missing ones blank).

usage: gen_font.py [path/to/charrom.cpp] [out.hex]
"""
import pathlib
import re
import sys

src_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "../Main_MiSTer/charrom.cpp")
out_path = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).parent.parent / "rtl" / "font8x8.hex")

src = src_path.read_text()
start = src.index("unsigned char charfont[256][8] =")
end = src.index("};", start)
body = src[src.index("{", start) + 1:end]
glyphs = [[int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", g)]
          for g in re.findall(r"\{\s*((?:0x[0-9A-Fa-f]{2}\s*,?\s*){8})\}", body)]

rows = []
for g in range(256):
    cols = glyphs[g] if g < len(glyphs) else [0] * 8
    for r in range(8):
        byte = 0
        for c in range(8):
            if (cols[c] >> r) & 1:
                byte |= 0x80 >> c
        rows.append(byte)

out_path.write_text("".join(f"{b:02X}\n" for b in rows))
print(f"{out_path}: {len(glyphs)} source glyphs -> 256 glyphs, {len(rows)} bytes")

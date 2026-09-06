#!/usr/bin/env python3
"""Generate the static screen, string table and field descriptors.

Outputs (all relative to the repo root):
  rtl/screen_chr.hex  4096 x 8-bit  character RAM initial contents (80x30 used)
  rtl/screen_att.hex  4096 x 4-bit  colour attribute ROM
  rtl/strings.hex      512 x 8-bit  32 string slots of 16 chars
  rtl/fields.svh      field descriptor function, value-source ids, string slots
  docs/screen_preview.txt  what the screen looks like

Layout markup: ^X sets colour X (hex digit) for the following literal text,
{name} inserts a dynamic field (width/kind/source from FIELDS below),
a few unicode glyphs map to the font's box/block characters.
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
COLS, ROWS = 80, 30

# colour indices (see palette in rtl/text_video.sv)
BLACK, BLUE, GREEN, CYAN, RED, MAGENTA, BROWN, LGRAY = range(8)
DGRAY, LBLUE, LGREEN, LCYAN, LRED, PINK, YELLOW, WHITE = range(8, 16)

# test matrix: transfer sizes (rows) x {SEQ READ, SEQ WRITE, RND READ, RND WRITE}
SIZES = ["512B", " 1KB", " 2KB", " 4KB", " 8KB", "16KB", "32KB", "64KB", " 1MB", " 4MB"]
NTESTS = len(SIZES) * 4          # 40; result slots 0..79
BUS_TEST = NTESTS                # extra bus-only test -> result slots 80/81

# value source ids: 0x00..0x51 are results RAM (test*2 = KB/s, +1 = IOPS),
# named sources start at 0x80 (must match rtl/bench.sv, emitted into fields.svh)
SRC = {
    "IMGMB": 0x80, "TNUM": 0x81, "TTOT": 0x82, "REQS": 0x83, "KB": 0x84,
    "LAVG": 0x85, "LMIN": 0x86, "LMAX": 0x87, "VOK": 0x88, "VBAD": 0x89,
    "VSKIP": 0x8A, "ELAPSED": 0x8B, "RUNS": 0x8C, "STATE": 0x8D, "OP": 0x8E,
    "SIZE": 0x8F, "BAR": 0x90, "WRMODE": 0x91, "TTIME": 0x92, "ERRS": 0x93,
    "LBA": 0x94, "BUS": 0x95,
}

NUM, STR, BAR = 0, 1, 2

# name -> (kind, source, width, colour)
FIELDS = {
    "imgmb":   (NUM, SRC["IMGMB"], 7, WHITE),
    "wrmode":  (STR, SRC["WRMODE"], 8, WHITE),
    "ttime":   (NUM, SRC["TTIME"], 1, WHITE),
    "bus":     (STR, SRC["BUS"], 6, WHITE),
    "state":   (STR, SRC["STATE"], 13, LGREEN),
    "tnum":    (NUM, SRC["TNUM"], 2, WHITE),
    "ttot":    (NUM, SRC["TTOT"], 2, WHITE),
    "op":      (STR, SRC["OP"], 9, LGREEN),
    "size":    (STR, SRC["SIZE"], 4, LGREEN),
    "bar":     (BAR, SRC["BAR"], 16, LCYAN),
    "reqs":    (NUM, SRC["REQS"], 8, WHITE),
    "kb":      (NUM, SRC["KB"], 8, WHITE),
    "lba":     (NUM, SRC["LBA"], 9, WHITE),
    "errs":    (NUM, SRC["ERRS"], 3, LRED),
    "lavg":    (NUM, SRC["LAVG"], 7, WHITE),
    "lmin":    (NUM, SRC["LMIN"], 7, WHITE),
    "lmax":    (NUM, SRC["LMAX"], 7, WHITE),
    "elapsed": (NUM, SRC["ELAPSED"], 5, WHITE),
    "runs":    (NUM, SRC["RUNS"], 2, WHITE),
    "vok":     (NUM, SRC["VOK"], 8, WHITE),
    "vbad":    (NUM, SRC["VBAD"], 6, LRED),
    "vskip":   (NUM, SRC["VSKIP"], 8, LGRAY),
    "busk":    (NUM, BUS_TEST * 2, 7, WHITE),      # bus-only test: KB/s
    "busi":    (NUM, BUS_TEST * 2 + 1, 6, LGRAY),  # bus-only test: IOPS
}
for t in range(NTESTS):
    FIELDS[f"r{t}k"] = (NUM, t * 2, 7, WHITE)
    FIELDS[f"r{t}i"] = (NUM, t * 2 + 1, 6, LGRAY)

# string slots (16 chars each); the value returned by a STR source is the slot.
# Names become STR_<NAME> localparams in fields.svh.
STRINGS = [
    (0,  "STATE_NOIMG",  "NO IMAGE"),
    (1,  "STATE_START",  "STARTING"),
    (2,  "STATE_RUN",    "RUNNING"),
    (3,  "STATE_DONE",   "COMPLETE"),
    (4,  "STATE_TMO",    "TIMEOUT"),
    (5,  "STATE_SMALL",  "IMG TOO SMALL"),
    (8,  "OP0",          "SEQ READ"),     # OP0 + kind
    (9,  "OP1",          "SEQ WRITE"),
    (10, "OP2",          "RND READ"),
    (11, "OP3",          "RND WRITE"),
    (12, "OP_NONE",      "-"),
    (13, "OP_BUS",       "CACHED RD"),
    (26, "SIZE_NONE",    " -"),
    (27, "WR_ON",        "ENABLED"),
    (28, "WR_OFF",       "DISABLED"),
    (29, "WR_RO",        "RO IMAGE"),
    (30, "BUS16",        "16-bit"),
    (31, "BUS8",         " 8-bit"),
]
for i, s in enumerate(SIZES):                  # SIZE0 + size index
    STRINGS.append((16 + i, f"SIZE{i}", s))

GLYPH = {"─": 0x87, "·": 0x1B, "█": 0x7F, "→": 0x16, "░": 0x1B}

def table_row(size_idx):
    line = "   ^B " + SIZES[size_idx] + "   "
    for kind in range(4):
        t = size_idx * 4 + kind
        line += "^F{r%dk} ^7{r%di}" % (t, t)
        if kind != 3:
            line += "   "
    return line

L = [""] * ROWS
L[1]  = "   ^FMiSTer Disk I/O Benchmark   ^8DiskIOTest"
L[2]  = "   ^8" + "─" * 74
L[3]  = "   ^7Image: ^F{imgmb} MB   ^7Write tests: ^F{wrmode}   ^7Time/test: ^F{ttime} s   ^7Bus: ^F{bus}"
L[5]  = "   ^E           " + "   ".join(s.center(14) for s in ("SEQ READ", "SEQ WRITE", "RND READ", "RND WRITE"))
L[6]  = "   ^7Transfer   " + "   ".join("   KB/s   IOPS" for _ in range(4))
L[7]  = "   ^8" + "─" * 74
for i in range(len(SIZES)):
    L[8 + i] = table_row(i)
L[18] = "   ^8" + "─" * 74
L[19] = "   ^7Status: ^A{state}    ^7Test ^F{tnum}^7/^F{ttot}   ^A{op} {size}   ^7[^B{bar}^7]"
L[20] = "   ^7Requests: ^F{reqs}   ^7KB: ^F{kb}   ^7LBA: ^F{lba}   ^7Errors: ^C{errs}   ^7Run: ^F{runs}"
L[21] = "   ^7Latency us:  avg ^F{lavg}  ^7min ^F{lmin}  ^7max ^F{lmax}       ^7Elapsed: ^F{elapsed} s"
L[22] = "   ^7Verify:  ^Aok ^F{vok}   ^Cbad ^F{vbad}   ^8unsigned ^F{vskip}"
L[23] = "   ^7HPS bus only (8KB reads from ARM cache):  ^F{busk} ^7KB/s  ^F{busi} ^7IOPS"
L[25] = "   ^8hps_io moves 16KB per request; 32KB..4MB rows are back-to-back 16KB requests."
L[26] = "   ^8512B = Mac LC SCSI pattern, 16KB = IDE READ MULTIPLE. Same ARM path for all."
L[27] = "   ^8Use a >= 1GB scratch image (ARM page cache). ^CWrite tests overwrite the image!"
L[28] = "   ^7OSD: mount / options / restart.   Enter or gamepad button = restart."

chars = [0x20] * (COLS * ROWS)
attrs = [LGRAY] * (COLS * ROWS)
fields = []   # (name, kind, src, width, colour, row, col)

for row, line in enumerate(L):
    col = 0
    colour = LGRAY
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "^":
            colour = int(line[i + 1], 16)
            i += 2
            continue
        if ch == "{":
            j = line.index("}", i)
            name = line[i + 1:j]
            kind, src, width, fcol = FIELDS[name]
            fields.append((name, kind, src, width, fcol, row, col))
            for k in range(width):
                chars[row * COLS + col + k] = 0x20
                attrs[row * COLS + col + k] = fcol
            col += width
            i = j + 1
            continue
        code = GLYPH.get(ch, ord(ch))
        assert code < 256, (row, ch)
        assert col < COLS, f"row {row} exceeds {COLS} columns: {line!r}"
        chars[row * COLS + col] = code
        attrs[row * COLS + col] = colour
        col += 1
        i += 1
    assert col <= COLS, f"row {row} is {col} columns wide"

# ---- outputs -------------------------------------------------------------
rtl = ROOT / "rtl"
rtl.mkdir(exist_ok=True)

chr_mem = chars + [0x20] * (4096 - len(chars))
att_mem = attrs + [0] * (4096 - len(attrs))
(rtl / "screen_chr.hex").write_text("".join(f"{c:02X}\n" for c in chr_mem))
(rtl / "screen_att.hex").write_text("".join(f"{a:X}\n" for a in att_mem))

str_mem = [0x20] * 512
seen = set()
for slot, name, text in STRINGS:
    assert len(text) <= 16 and slot < 32 and slot not in seen
    seen.add(slot)
    for k, ch in enumerate(text.ljust(16)):
        str_mem[slot * 16 + k] = ord(ch)
(rtl / "strings.hex").write_text("".join(f"{c:02X}\n" for c in str_mem))

# descriptor packing: [1:0] kind, [6:2] row, [13:7] col, [18:14] width, [26:19] src
lines = ["// Generated by tools/gen_screen.py - do not edit.",
         "// Field descriptor: [1:0] kind (0 num,1 str,2 bar) [6:2] row [13:7] col [18:14] width [26:19] source",
         f"localparam FIELD_COUNT = {len(fields)};",
         f"localparam NTESTS = {NTESTS};",
         f"localparam [5:0] T_BUS = 6'd{BUS_TEST};"]
for name, val in SRC.items():
    lines.append(f"localparam [7:0] SRC_{name} = 8'h{val:02X};")
for slot, name, text in STRINGS:
    lines.append(f"localparam [7:0] STR_{name} = 8'd{slot};")
lines.append("function automatic [31:0] field_desc(input [7:0] idx);")
lines.append("\tcase (idx)")
for n, (name, kind, src, width, fcol, row, col) in enumerate(fields):
    desc = kind | (row << 2) | (col << 7) | (width << 14) | (src << 19)
    lines.append(f"\t\t8'd{n}: field_desc = 32'h{desc:08X}; // {name}: row {row} col {col} w {width}")
lines.append("\t\tdefault: field_desc = 32'h0;")
lines.append("\tendcase")
lines.append("endfunction")
(rtl / "fields.svh").write_text("\n".join(lines) + "\n")

# preview
rev = {v: k for k, v in GLYPH.items()}
prev = []
for row in range(ROWS):
    s = ""
    for col in range(COLS):
        c = chars[row * COLS + col]
        s += rev.get(c, chr(c) if 32 <= c < 127 else "?")
    prev.append(s)
for name, kind, src, width, fcol, row, col in fields:
    prev[row] = prev[row][:col] + ("#" * width) + prev[row][col + width:]
(ROOT / "docs" / "screen_preview.txt").write_text("\n".join(p.rstrip() for p in prev) + "\n")
print(f"{len(fields)} fields, {len(STRINGS)} strings")
print("\n".join(p.rstrip() for p in prev))

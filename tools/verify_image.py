#!/usr/bin/env python3
"""Offline check of a scratch image written by the DiskIOTest core.

Every sector the core writes starts with "DIOT" + LBA (little-endian 32-bit)
followed by a pattern derived from the LBA (see rtl/pattern.sv).  This scans
an image, verifies every signed sector and classifies the failures:

  ok        signature + LBA field + data match the sector's position
  moved     signature ok, data matches the LBA *in the field* (sector landed at
            the wrong position: addressing problem on write)
  shifted   data matches the expected pattern displaced by a few bytes
            (dropped or duplicated byte/word on the bus)
  torn      part of the sector matches, the rest is other data (interrupted or
            mixed write)
  bad       none of the above

    python3 verify_image.py scratch_1024M.img [--limit 20] [--fix]

--fix rewrites every signed sector that does not verify with the correct
pattern for its position, so the core's verify counters are clean again.
"""
import argparse
import os
import struct
import sys

try:
    import numpy as np
except ImportError:      # pragma: no cover
    np = None

SIG = b"DIOT"


_WS = [(w, (w << 8) + 0x9E37) for w in range(4, 256)]


def pattern_words(lba):
    """256 little-endian 16-bit words of the sector at `lba` (rtl/pattern.sv)."""
    h = (lba & 0xFFFF) ^ (lba >> 16)
    hs = ((h & 0xFF) << 8) | (h >> 8)
    return [0x4944, 0x544F, lba & 0xFFFF, lba >> 16] + \
           [((h + c) & 0xFFFF) ^ ((hs + w) & 0xFFFF) for w, c in _WS]


def pattern_bytes(lba):
    return struct.pack("<256H", *pattern_words(lba))


def classify(data, index):
    exp = pattern_bytes(index)
    if data == exp:
        return "ok", ""
    field = struct.unpack_from("<I", data, 4)[0]
    if field != index and data == pattern_bytes(field):
        return "moved", "field lba %d at position %d" % (field, index)
    # displaced copy?
    for shift in range(1, 9):
        if data[shift:] == exp[:-shift]:
            return "shifted", "+%d bytes (duplicated/inserted)" % shift
        if data[:-shift] == exp[shift:]:
            return "shifted", "-%d bytes (dropped)" % shift
    good = sum(1 for a, b in zip(data, exp) if a == b)
    first_bad = next(i for i in range(512) if data[i] != exp[i])
    if good > 64:
        return "torn", "%d/512 bytes match, first mismatch at byte %d, lba field %d" % (good, first_bad, field)
    return "bad", "first mismatch at byte %d, lba field %d" % (first_bad, field)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--limit", type=int, default=20, help="how many failures to print per class")
    ap.add_argument("--fix", action="store_true", help="rewrite failing signed sectors with the correct pattern")
    args = ap.parse_args()
    fixfd = os.open(args.image, os.O_WRONLY) if args.fix else None
    fixed = 0

    counts = {"ok": 0, "moved": 0, "shifted": 0, "torn": 0, "bad": 0, "unsigned": 0}
    shown = {k: 0 for k in counts}
    chunk = 16 << 20
    index = 0
    with open(args.image, "rb") as f:
        while True:
            buf = f.read(chunk)
            if not buf:
                break
            nsec = len(buf) // 512
            if np is not None:
                arr = np.frombuffer(buf[:nsec * 512], dtype=np.uint8).reshape(nsec, 512)
                signed = np.flatnonzero((arr[:, 0] == 0x44) & (arr[:, 1] == 0x49) & (arr[:, 2] == 0x4F) & (arr[:, 3] == 0x54))
                candidates = signed.tolist()
            else:
                candidates = [i for i in range(nsec) if buf[i * 512:i * 512 + 4] == SIG]
            counts["unsigned"] += nsec - len(candidates)
            for i in candidates:
                data = buf[i * 512:(i + 1) * 512]
                kind, why = classify(data, index + i)
                counts[kind] += 1
                if kind != "ok":
                    if shown[kind] < args.limit:
                        shown[kind] += 1
                        print("%-8s lba %9d  %s" % (kind, index + i, why))
                    if fixfd is not None:
                        os.pwrite(fixfd, pattern_bytes(index + i), (index + i) * 512)
                        fixed += 1
            index += nsec
            sys.stderr.write("\r%d MB scanned" % (index // 2048))
    sys.stderr.write("\n")
    if fixfd is not None:
        os.fsync(fixfd)
        os.close(fixfd)
        print("rewrote %d sectors with the correct pattern" % fixed)
    total_signed = sum(v for k, v in counts.items() if k != "unsigned")
    print("sectors: %d signed, %d unsigned" % (total_signed, counts["unsigned"]))
    for k in ("ok", "moved", "shifted", "torn", "bad"):
        print("  %-8s %d" % (k, counts[k]))
    return 0 if total_signed == counts["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Build releases/DiskIOTest_scratch_<size>M.zip: a zero-filled scratch image
laid out as games/DiskIOTest/scratch_<size>M.img so the archive can be
extracted onto the root of the MiSTer SD card.  Streams the zeros straight
into the archive (no temporary file); 1 GB of zeros deflates to about 1 MB.

    python3 tools/make_scratch_zip.py [--size 1024]
"""
import argparse
import datetime
import pathlib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

README = """DiskIOTest scratch image
========================

scratch_{size}M.img is a {size} MB file of zeros for the DiskIOTest core and
for tools/diskio_bench.py.  WRITE TESTS OVERWRITE IT - never point the
benchmark at an image you care about.

1. Extract this archive onto the root of the MiSTer SD card, so the file
   ends up as /media/fat/games/DiskIOTest/scratch_{size}M.img.
   Make sure your extractor really writes the zeros (a "sparse" extraction
   would give unrepresentative write numbers); normal unzip does.
2. Start DiskIOTest, OSD -> Mount scratch image -> pick the file.
   The cycle starts one second after the mount and the mount is remembered.

The native script uses the same file:
   cd /media/fat/games/DiskIOTest && python3 diskio_bench.py scratch_{size}M.img
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", type=int, default=1024, help="image size in MB (default 1024)")
    args = ap.parse_args()

    out = ROOT / "releases" / ("DiskIOTest_scratch_%dM.zip" % args.size)
    out.parent.mkdir(exist_ok=True)
    chunk = bytes(1 << 20)
    now = datetime.datetime.now().timetuple()[:6]

    def entry(name):
        info = zipfile.ZipInfo(name, date_time=now)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16          # -rw-r--r--
        return info

    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        zf.writestr(entry("games/DiskIOTest/README.txt"), README.format(size=args.size))
        with zf.open(entry("games/DiskIOTest/scratch_%dM.img" % args.size), "w", force_zip64=True) as f:
            for _ in range(args.size):
                f.write(chunk)
    print("%s: %d bytes" % (out, out.stat().st_size))
    with zipfile.ZipFile(out) as zf:
        for info in zf.infolist():
            print("  %-40s %12d -> %8d" % (info.filename, info.file_size, info.compress_size))


if __name__ == "__main__":
    main()

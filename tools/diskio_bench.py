#!/usr/bin/env python3
"""diskio_bench.py - native Linux counterpart of the DiskIOTest MiSTer core.

Runs the same matrix as the core (transfer sizes 512 B .. 4 MB x SEQ/RND x
READ/WRITE, queue depth 1, a fixed time per test) against a scratch file with
plain pread/pwrite calls, prints the same table and writes a timestamped log
next to the script.  Runs on the MiSTer's own Linux (python3 3.9 is in the
stock image), on a Raspberry Pi, or on any Linux box; only the standard
library is used.

    python3 diskio_bench.py /media/fat/games/DiskIOTest/scratch_1024M.img
    python3 diskio_bench.py --direct /mnt/sdcard/scratch.img      # bypass page cache
    python3 diskio_bench.py --time 1 --no-write --sizes 512,4K,16K,1M scratch.img

Defaults mimic Main_MiSTer's file access: buffered I/O with O_SYNC, no
O_DIRECT, one syscall per transfer.  --chunk 16384 reproduces the 16 KB
requests the hps_io path is limited to.  WRITE TESTS OVERWRITE THE FILE.
"""
import argparse
import datetime
import mmap
import os
import platform
import random
import socket
import subprocess
import sys
import time

SIZES = [("512B", 512), ("1KB", 1024), ("2KB", 2048), ("4KB", 4096), ("8KB", 8192),
         ("16KB", 16384), ("32KB", 32768), ("64KB", 65536), ("1MB", 1 << 20), ("4MB", 1 << 22)]
KINDS = ["SEQ READ", "SEQ WRITE", "RND READ", "RND WRITE"]
MAXSZ = max(sz for _, sz in SIZES)


class Log:
    """Print to the terminal and to the log file at the same time."""

    def __init__(self, path):
        self.f = open(path, "w")
        self.path = path

    def __call__(self, *parts):
        line = " ".join(str(p) for p in parts)
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()

    def close(self):
        self.f.close()


def parse_size(text):
    t = text.strip().upper()
    mult = 1
    if t.endswith("KB") or t.endswith("K"):
        mult, t = 1024, t.rstrip("B").rstrip("K")
    elif t.endswith("MB") or t.endswith("M"):
        mult, t = 1 << 20, t.rstrip("B").rstrip("M")
    elif t.endswith("B"):
        t = t[:-1]
    return int(t) * mult


def size_name(n):
    for name, sz in SIZES:
        if sz == n:
            return name
    return "%dK" % (n // 1024) if n % 1024 == 0 else "%dB" % n


def read_first_line(path, default=""):
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError:
        return default


def cpu_model():
    """'model name' (x86, most ARM), else 'Model'/'Hardware' (Raspberry Pi, MiSTer)."""
    found = {}
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if ":" in line:
                    key, val = line.split(":", 1)
                    found.setdefault(key.strip(), val.strip())
    except OSError:
        pass
    for key in ("model name", "Model", "Hardware"):
        if found.get(key):
            return found[key]
    return platform.machine()


def mem_total_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal"):
                    return int(line.split()[1]) // 1024
    except OSError:
        pass
    return 0


def mount_info(path):
    try:
        out = subprocess.run(["findmnt", "-n", "-T", path, "-o", "TARGET,SOURCE,FSTYPE,OPTIONS"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if out:
            return out
    except (OSError, subprocess.SubprocessError):
        pass
    return "?"


def drop_caches(log):
    try:
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3\n")
    except OSError as e:
        log("   (drop_caches not possible: %s)" % e)


def ensure_file(path, size_mb, log):
    """Create the scratch file fully written (like dd), reporting the write rate."""
    want = size_mb << 20
    if os.path.exists(path) and os.path.getsize(path) >= 1 << 20:
        return os.path.getsize(path)
    log("Creating %s (%d MB, fully written) ..." % (path, size_mb))
    block = os.urandom(1 << 20)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    t0 = time.perf_counter()
    done = 0
    try:
        while done < want:
            done += os.write(fd, block)
            if done % (128 << 20) == 0:
                log("   %d MB" % (done >> 20))
        os.fsync(fd)
    finally:
        os.close(fd)
    dt = time.perf_counter() - t0
    log("   created in %.1f s = %.1f MB/s (1 MB buffered writes + fsync)" % (dt, size_mb / dt))
    return want


def open_scratch(path, direct, sync, log):
    flags = os.O_RDWR
    if sync:
        flags |= os.O_SYNC
    if direct:
        try:
            fd = os.open(path, flags | os.O_DIRECT)
            # probe: an unaligned-unfriendly file system rejects O_DIRECT at the first read
            buf = mmap.mmap(-1, 4096)
            try:
                os.preadv(fd, [buf], 0)
            finally:
                buf.close()
            return fd, True
        except OSError as e:
            log("   O_DIRECT not usable here (%s); falling back to buffered I/O" % e)
            try:
                os.close(fd)
            except Exception:
                pass
    return os.open(path, flags), False


def do_io(fd, write, off, view, chunk):
    n = len(view)
    if chunk and n > chunk:
        for o in range(0, n, chunk):
            part = view[o:o + chunk]
            got = os.pwritev(fd, [part], off + o) if write else os.preadv(fd, [part], off + o)
            if got != len(part):
                raise IOError("short %s: %d of %d at %d" % ("write" if write else "read", got, len(part), off + o))
    else:
        got = os.pwritev(fd, [view], off) if write else os.preadv(fd, [view], off)
        if got != n:
            raise IOError("short %s: %d of %d at %d" % ("write" if write else "read", got, n, off))


def run_test(fd, size, seq, write, secs, view, rnd, cursor, filesize, chunk, fixed_off=None):
    """Queue depth 1: issue transfers back to back for `secs` seconds."""
    nchunks = filesize // size
    cur = (cursor + 16383) & ~16383           # like the core: sequential runs start 16 KB aligned
    lats = []
    total = 0
    t0 = time.perf_counter_ns()
    t_last = t0
    limit = int(secs * 1e9)
    while True:
        if fixed_off is not None:
            off = fixed_off
        elif seq:
            if cur + size > filesize:
                cur = 0
            off = cur
            cur += size
        else:
            off = rnd.randrange(nchunks) * size
        t1 = time.perf_counter_ns()
        do_io(fd, write, off, view, chunk)
        t2 = time.perf_counter_ns()
        lats.append(t2 - t1)
        total += size
        t_last = t2
        if t2 - t0 >= limit:
            break
    elapsed = (t_last - t0) / 1e9
    n = len(lats)
    return {
        "kbps": total / 1024 / elapsed if elapsed else 0.0,
        "iops": n / elapsed if elapsed else 0.0,
        "n": n,
        "bytes": total,
        "lat_avg": sum(lats) / n / 1000.0,
        "lat_min": min(lats) / 1000.0,
        "lat_max": max(lats) / 1000.0,
        "elapsed": elapsed,
    }, cur


def fmt_cell(r):
    if r is None:
        return "      -      -"
    return "%7d %6d" % (round(r["kbps"]), round(r["iops"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", default="scratch_1024M.img",
                    help="scratch file (created if missing; WRITE TESTS OVERWRITE IT)")
    ap.add_argument("--size", type=int, default=1024, help="size in MB when the file has to be created (default 1024)")
    ap.add_argument("--time", type=float, default=2.0, help="seconds per test (default 2)")
    ap.add_argument("--sizes", default=",".join(n for n, _ in SIZES), help="comma separated transfer sizes, e.g. 512,4K,16K,1M")
    ap.add_argument("--no-write", action="store_true", help="skip the write tests")
    ap.add_argument("--direct", action="store_true", help="open with O_DIRECT (bypass the page cache; use on machines with more RAM than the file)")
    ap.add_argument("--nosync", action="store_true", help="do not open with O_SYNC (Main_MiSTer uses O_SYNC)")
    ap.add_argument("--chunk", type=parse_size, default=0, help="split transfers into syscalls of this size (16K mimics hps_io requests)")
    ap.add_argument("--drop-caches", action="store_true", help="drop the page cache before every read test (root)")
    ap.add_argument("--seed", type=int, default=0x2545F491, help="random LBA seed")
    ap.add_argument("--logdir", default=os.path.dirname(os.path.abspath(__file__)), help="where to write the log (default: the script's folder)")
    args = ap.parse_args()

    host = socket.gethostname()
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    os.makedirs(args.logdir, exist_ok=True)
    log = Log(os.path.join(args.logdir, "diskio_%s_%s.log" % (stamp, host)))

    sizes = [parse_size(s) for s in args.sizes.split(",") if s.strip()]
    path = os.path.abspath(args.file)
    filesize = ensure_file(path, args.size, log)
    fd, direct = open_scratch(path, args.direct, not args.nosync, log)
    ram = mem_total_mb()

    log("=" * 78)
    log("   MiSTer Disk I/O Benchmark   diskio_bench.py (native Linux)   %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    log("=" * 78)
    log("   Host: %s   %s %s %s   %d CPU   %d MB RAM   Python %s" % (
        host, platform.system(), platform.release(), platform.machine(), os.cpu_count() or 1, ram, platform.python_version()))
    log("   CPU:  %s" % cpu_model())
    log("   File: %s   %d MB" % (path, filesize >> 20))
    log("   Mount: %s" % mount_info(path))
    flags = ("O_DIRECT " if direct else "buffered ") + ("O_SYNC" if not args.nosync else "no O_SYNC")
    log("   Flags: %s   Time/test: %g s   Chunk: %s   Writes: %s" % (
        flags, args.time, ("%d B per syscall" % args.chunk) if args.chunk else "whole transfer per syscall",
        "disabled" if args.no_write else "ENABLED (file is overwritten)"))
    if not direct and ram > (filesize >> 20):
        log("   NOTE: RAM (%d MB) exceeds the file (%d MB): reads may come from the page cache. Use --direct for card numbers." % (ram, filesize >> 20))
    log("")

    # separate buffers: reads must never feed the write data, or the write tests
    # would copy previously read blocks around the file (and confuse any verifier)
    rview = memoryview(mmap.mmap(-1, MAXSZ))     # page aligned, fine for O_DIRECT
    wview = memoryview(mmap.mmap(-1, MAXSZ))
    rnd = random.Random(args.seed)
    for i in range(0, MAXSZ, 4096):              # non-zero, incompressible write data
        wview[i:i + 4096] = os.urandom(4096)

    results = {}
    cursor = 0
    t_run = time.perf_counter()

    if not direct:
        r, _ = run_test(fd, 8192, True, False, args.time / 2, rview[:8192], rnd, 0, filesize, 0, fixed_off=0)
        log("   syscall floor (8KB reads from page cache):  %7d KB/s %7d IOPS   avg %.0f us" % (round(r["kbps"]), round(r["iops"]), r["lat_avg"]))
        results["floor"] = r
        log("")

    for size in sizes:
        if size > filesize or size > MAXSZ:
            log("   %5s: transfer larger than the file, skipped" % size_name(size))
            continue
        for k, kind in enumerate(KINDS):
            write = k % 2 == 1
            seq = k < 2
            if write and args.no_write:
                results[(size, k)] = None
                continue
            if args.drop_caches and not write:
                drop_caches(log)
            view = wview if write else rview
            r, cursor2 = run_test(fd, size, seq, write, args.time, view[:size], rnd, cursor, filesize, args.chunk)
            if seq:
                cursor = cursor2
            results[(size, k)] = r
            log("   %-9s %5s  %7d KB/s %7d IOPS   n=%-6d lat us avg %8.0f  min %8.0f  max %8.0f" % (
                kind, size_name(size), round(r["kbps"]), round(r["iops"]), r["n"], r["lat_avg"], r["lat_min"], r["lat_max"]))
    os.close(fd)
    total = time.perf_counter() - t_run

    log("")
    log(("   %-9s %s" % ("", "".join("%s   " % h.center(14) for h in KINDS))).rstrip())
    log("   Transfer  " + "   ".join("   KB/s   IOPS" for _ in KINDS))
    log("   " + "-" * 74)
    for size in sizes:
        if size > filesize or size > MAXSZ:
            continue
        cells = [fmt_cell(results.get((size, k))) for k in range(4)]
        log("   %5s     %s" % (size_name(size), "   ".join(cells)))
    log("   " + "-" * 74)
    log("")
    log("   Latency us (avg / min / max):")
    for size in sizes:
        if size > filesize or size > MAXSZ:
            continue
        parts = []
        for k in range(4):
            r = results.get((size, k))
            parts.append("        -        " if r is None else "%6.0f/%6.0f/%7.0f" % (r["lat_avg"], r["lat_min"], r["lat_max"]))
        log("   %5s   %s" % (size_name(size), "  ".join(parts)))
    log("")
    log("   Total run %.0f s.  Log: %s" % (total, log.path))
    log.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

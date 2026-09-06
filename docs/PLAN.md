# DiskIOTest — plan

## Goal
A small MiSTer core that benchmarks the disk I/O path the way CrystalDiskMark
does for PCs: sequential vs random, several request sizes, read and write,
one full cycle then stop, live results on screen.

## What is actually being measured (and why the "subsystem" barely matters)
Every MiSTer core that emulates a hard disk (Mac LC SCSI, Minimig/ao486 IDE,
every 8-bit core) reaches the SD card through the same path:

    core FSM -> hps_io.sv sd_* bus -> Main_MiSTer user_io_poll()
             -> FileSeek/FileRead/FileWrite on the image -> Linux exFAT -> SD card

* The bus is a 16-bit parallel register (HPS gp_out/gp_in) strobed by the ARM.
  `fpga_spi_fast_block_write/read` push one word per two posted writes without
  waiting for an ack, so throughput is set by the ARM's posted-write pace (and
  a bus read per word for FPGA->ARM, i.e. disk writes are slower on the bus).
* Per request the ARM does one GET_SDSTAT poll, a file seek/read/write and one
  block transfer of up to 16 KB (`sd_blk_cnt` = 0..31 blocks of 512 B).
  Request size is therefore the dominant variable.
* Reads have a 16 KB read-ahead buffer on the ARM (sequential 512 B reads hit
  it 31 times out of 32; random reads miss every time).
* Mac LC `scsi.v` issues 1 sector per request, back to back (ring buffer) ->
  its ceiling is the "512B SEQ READ" row of this benchmark.
  `ide.cpp` READ/WRITE MULTIPLE moves up to 32 sectors per transfer -> the
  "16KB" rows. The IDE (`UIO_DMA_*`) path uses the same block-transfer
  routines on the same bus and is only served for Minimig/ao486 core types, so
  it cannot be exercised from a generic core; the `sd_*` path is the common
  denominator and is what this core drives directly.

So: one engine, one bus, a matrix of request size x pattern x direction.

## Test matrix (one cycle)
Request sizes: 512 B, 1 K, 2 K, 4 K, 8 K, 16 K (sd_blk_cnt = 2^n - 1, BLKSZ=2, WIDE=1)
For each size: SEQ READ, SEQ WRITE, RND READ, RND WRITE  -> 24 tests, queue depth 1.
Each test runs for a fixed time (OSD: 1/2/4/8 s, default 2 s) issuing requests
back to back; reports KB/s and IOPS (live while running), latency min/avg/max.
Sequential tests continue from a running cursor (aligned to 16 KB) so no two
tests re-read the same region; random LBAs are uniform over the whole image
(32x32 multiply, no modulo). Write tests can be disabled in the OSD and are
skipped automatically for read-only images.

## Data integrity
No buffer RAM: write data is generated combinationally from (LBA, word index)
and read data is compared on the fly. Each sector starts with "DIOT" + LBA, so
reads of sectors this core wrote are verified (ok/bad) and other sectors are
counted as "unsigned". Any bus corruption (e.g. a too-slow clk_sys missing
strobes) shows up as "bad".

## Hardware structure (all at clk_sys = 50 MHz from the core PLL)
* `DiskIOTest.sv`   framework glue: hps_io (WIDE=1, VDNUM=1), OSD, video assigns
* `rtl/bench.sv`    test sequencer, request engine, us timebase, stats, results
                    RAM, calc FSM (serial divider) producing KB/s, IOPS, latency,
                    progress; value mux for the display
* `rtl/pattern.sv`  pattern generator (sd_buff_din) and read verifier
* `rtl/divider.sv`, `rtl/bin2bcd.sv`  arithmetic helpers
* `rtl/text_video.sv`  640x480@60 text mode, 80x30 cells, 8x8 font doubled to
                    8x16, char RAM (initialised from generated screen), attribute
                    ROM, 16-colour palette
* `rtl/text_update.sv` walks a generated field table forever and rewrites the
                    dynamic cells (numbers right-aligned, strings, progress bar)
* `tools/gen_font.py`, `tools/gen_screen.py` generate the ROM images and
  `rtl/fields.svh` (single source of truth for screen positions / value ids)

## Verification and delivery
1. Icarus testbench with a behavioural model of the ARM side of hps_io
   (acks, data, latency) to check sequencing, stats, verify logic and the
   rendered text (char RAM dumped as ASCII).
2. Quartus 17.0.2 Lite compile (`scripts/build.sh`).
3. Deploy to 192.168.99.92: rbf to `_Utility`, a 1 GB scratch image in
   `games/DiskIOTest`, `config/DiskIOTest.s0` pre-written so the image
   auto-mounts, `load_core` via `/dev/MiSTer_cmd`, screenshot through the
   MiSTer Remote API, results read back from the screen.

## Outcome (2026-09-06)
Built with Quartus 17.0.2 Lite (20 % of the ALMs, mostly framework; timing met
with 7 ns slack on the 50 MHz domain), simulated with Icarus, run on the
DE10-nano at 192.168.99.92. Measured results and their interpretation are in
`results.md`. One addition after the first hardware run: a "bus only" test
(8 KB re-reads served from Main_MiSTer's read-ahead buffer) that isolates the
HPS transfer ceiling from the SD card.

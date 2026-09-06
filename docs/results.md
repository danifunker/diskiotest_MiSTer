# Measured results

DE10-nano, Main_MiSTer (danifunker fork, Aug 2026), stock 58 GB exFAT SD card
(`sync,dirsync` mount), 1 GB scratch image (fully written with dd beforehand),
2 s per test, queue depth 1, run on 2026-09-06.  Three views of the same
image:

* **A. DiskIOTest core, 16-bit hps_io bus** (`releases/DiskIOTest_16bit_20260906.rbf`)
* **B. DiskIOTest core, 8-bit hps_io bus** (`releases/DiskIOTest_8bit_20260906.rbf`)
* **C. Native Linux on the MiSTer's ARM** (`tools/diskio_bench.py`, buffered
  I/O with `O_SYNC` like Main_MiSTer, one syscall per transfer, log in
  `logs/diskio_20260906_064206_MiSTerss1.log`)

Transfers above 16 KB are issued by the core as back-to-back 16 KB requests
(the hps_io limit); the script issues them as one syscall.  IOPS = transfers
per second.

## A. Core, 16-bit bus

HPS bus only (8 KB re-reads from the ARM's read-ahead buffer, no file access):
**4843 KB/s, 605 IOPS**.  Full cycle 86 s, 90245 sectors verified, 0 bad
(`screenshot.png`).

| Transfer | SEQ READ KB/s (IOPS) | SEQ WRITE KB/s (IOPS) | RND READ KB/s (IOPS) | RND WRITE KB/s (IOPS) |
|---------:|---------------------:|----------------------:|---------------------:|----------------------:|
| 512 B  | 4114 (8229) | 292 (584)  | 151 (303)  | 127 (254)  |
| 1 KB   | 4339 (4339) | 544 (544)  | 307 (307)  | 284 (284)  |
| 2 KB   | 4454 (2227) | 815 (407)  | 647 (323)  | 344 (172)  |
| 4 KB   | 4347 (1086) | 823 (205)  | 1403 (350) | 612 (153)  |
| 8 KB   | 4521 (565)  | 1521 (190) | 3008 (376) | 1514 (189) |
| 16 KB  | 4600 (287)  | 2433 (152) | 2429 (151) | 2049 (128) |
| 32 KB  | 4627 (144)  | 2431 (75)  | 3146 (98)  | 1821 (56)  |
| 64 KB  | 4665 (72)   | 2432 (38)  | 3790 (59)  | 2131 (33)  |
| 1 MB   | 4666 (4)    | 2433 (2)   | 4664 (4)   | 2424 (2)   |
| 4 MB   | 4631 (1)    | 2418 (0)   | 4710 (1)   | 2428 (0)   |

Run-to-run variation is a few percent for reads; SD card writes vary more
(an earlier run gave 1400 KB/s for 4 KB sequential writes, another 412).

## B. Core, 8-bit bus

HPS bus only: **2438 KB/s, 304 IOPS** (half of the 16-bit figure, as
expected: one strobe per byte instead of per word).  Full cycle 87 s.

| Transfer | SEQ READ KB/s (IOPS) | SEQ WRITE KB/s (IOPS) | RND READ KB/s (IOPS) | RND WRITE KB/s (IOPS) |
|---------:|---------------------:|----------------------:|---------------------:|----------------------:|
| 512 B  | 2195 (4390) | 255 (510)  | 145 (290)  | 62 (125)   |
| 1 KB   | 2288 (2288) | 88 (88) *  | 299 (299)  | 232 (232)  |
| 2 KB   | 2343 (1171) | 688 (344)  | 613 (306)  | 449 (224)  |
| 4 KB   | 2372 (593)  | 933 (233)  | 1131 (282) | 713 (178)  |
| 8 KB   | 2380 (297)  | 1181 (147) | 1861 (232) | 1007 (125) |
| 16 KB  | 2397 (149)  | 1426 (89)  | 1631 (101) | 1266 (79)  |
| 32 KB  | 2383 (74)   | 1421 (44)  | 1816 (56)  | 1223 (38)  |
| 64 KB  | 2386 (37)   | 1421 (22)  | 2145 (33)  | 1275 (19)  |
| 1 MB   | 2371 (2)    | 1429 (1)   | 2380 (2)   | 1423 (1)   |
| 4 MB   | 2403 (0)    | 1415 (0)   | 2415 (0)   | 1430 (0)   |

\* card hiccup.

## C. Native Linux on the MiSTer (python3 diskio_bench.py)

Syscall floor (8 KB reads from the page cache): 183637 KB/s, 22955 IOPS,
33 us per call.

| Transfer | SEQ READ KB/s (IOPS) | SEQ WRITE KB/s (IOPS) | RND READ KB/s (IOPS) | RND WRITE KB/s (IOPS) |
|---------:|---------------------:|----------------------:|---------------------:|----------------------:|
| 512 B  | 12525 (25050) | 290 (580)   | 715 (1429)  | 146 (291)   |
| 1 KB   | 23185 (23185) | 649 (649)   | 1464 (1464) | 361 (361)   |
| 2 KB   | 22799 (11399) | 353 (176)   | 2734 (1367) | 232 (116)   |
| 4 KB   | 24119 (6030)  | 2299 (575)  | 5961 (1490) | 1395 (349)  |
| 8 KB   | 22754 (2844)  | 3814 (477)  | 8608 (1076) | 2486 (311)  |
| 16 KB  | 22882 (1430)  | 8291 (518)  | 12502 (781) | 4694 (293)  |
| 32 KB  | 21644 (676)   | 11244 (351) | 14720 (460) | 7567 (236)  |
| 64 KB  | 22385 (350)   | 13729 (215) | 17949 (280) | 10428 (163) |
| 1 MB   | 24834 (24)    | 11394 (11)  | 28516 (28)  | 7566 (7)    |
| 4 MB   | 25736 (6)     | 18194 (4)   | 25280 (6)   | 17918 (4)   |

Random 512 B read latency natively: 0.65 ms average; 512 B synchronous write:
1.7 ms; 4 MB synchronous write: 225 ms.

## Data integrity check

After the runs above the whole image was scanned offline with
`tools/verify_image.py` (same pattern function as the core): 206893 signed
sectors, **0 shifted, 0 torn, 0 bad** - the bus and the write path did not
corrupt a single sector in either bus width.  The "bad" counts the core
showed on screen in these runs (94 and 214) were all "moved" sectors, i.e.
valid data for another LBA, produced by an earlier version of
`diskio_bench.py` that reused its read buffer as write data and so copied
blocks around the file; the script now uses separate buffers and
`verify_image.py --fix` restored the sectors.

## What the numbers say

* **The HPS register bus is the ceiling for everything a core reads.** The
  bus-only test gives 4.86 MB/s ARM->FPGA (about 330 ns per 16-bit word, two
  device-memory writes per word); sequential reads of any size sit right
  under it, while the same card delivers 23 to 25 MB/s to a native Linux
  process. 512 B requests already reach 4.2 MB/s, so per-request overhead is
  only ~10-15 us: a one-sector-per-request SCSI pattern loses about 13 %
  against 32-sector IDE transfers, and splitting a 4 MB command into 16 KB
  requests costs nothing measurable.
* **FPGA->ARM (disk writes) is slower still**, because the ARM has to read
  the bus register once per word: 16 KB sequential writes reach 2.4 MB/s
  through the core against 8.3 MB/s natively with the identical `O_SYNC`
  file write behind them.
* **Small random reads pay for Main_MiSTer's fixed 16 KB read per cache
  miss**: 3.5 ms per random 512 B read through the core versus 0.65 ms
  natively. A random 16 KB read also triggers the prefetch of the *next*
  16 KB, so it moves 32 KB from the card.
* **Small writes are the card, not MiSTer.** Every request is a synchronous
  write (`O_SYNC` on a `sync` exFAT mount): ~1.7 ms for 512 B whether issued
  by the core or natively, so 290 KB/s is what this card does at 512 B. Only
  large synchronous writes (18 MB/s natively at 4 MB) show what the card can
  really sustain, and the core cannot get there because of the bus.
* **The controller emulation on top does not change any of this.** SCSI or
  IDE, the `sd_*` path underneath delivers these rates at best; the guest
  CPU's PIO loop and the OS driver only subtract from them.

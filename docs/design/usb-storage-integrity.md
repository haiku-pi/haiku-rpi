# USB storage integrity: the stick or our USB stack? (KNOWN-ISSUES C13)

2026-11-04 07:05–07:55. **Answer: our USB stack.** The bench's USB stick reads and writes correctly under Linux
on the same Pi and port. Haiku moved wrong data in both directions because the xHCI driver did no cache
maintenance for usb_disk's transfers, which DMA straight into and out of ordinary cacheable pages, and the VL805
does not snoop the CPU caches. **Fix: haiku `usb-dma-coherency` eabad7a921** (`xhci: cache maintenance for
physical transfers on arm64`; pushed, not merged into `rpi4`). With it, Haiku reads exactly what Linux reads
(the same SHA-256 over four 64 MiB regions), a pattern Haiku writes reads back under Linux with 0 differing
bytes, and a BFS made on the stick mounts, keeps 329 MB of files intact across a remount and passes `checkfs`.

## What was seen

During H20 N6 ([perf-round-h20.md](perf-round-h20.md), "N6 results", side finding 1) the stick (SanDisk Ultra,
0781:5581, 32 GB, USB 3, `/dev/disk/usb/*/0/raw`) gave a different MD5 for each of three reads of the same 1 MiB,
and a BFS made on it with `mkfs -t bfs` would not mount ("bfs: invalid superblock!"). The raw read speeds in
HARDWARE-SUPPORT (78–90 MB/s, 10-18 to 10-25, `tools/pi-tests/usbcheck.sh`) measured time only; no data was
ever compared. One N6 boot (`artifacts/uart/20261104-064008-session-n6-basepc3.log`, lines ~236–250) stalled
with xHCI "USB transaction" errors on the stick at enumeration; see "Not explained" below.

## Linux, the reference (same Pi, same port, same stick)

The flash lane (Linux 6.18.56-v8+ netbooted with a busybox initramfs) gained a mode that runs a script from the
host: `scripts/sd-cycle.sh --script FILE [--script-file F]...` (job `MODE=script` in `tools/flashlane/init`).
**The SD card is made read-only before the script runs** (`blockdev --setro` on `/dev/mmcblk0` and its
partitions, checked with `--getro`; the lane dies otherwise); the output comes back as `HFL out` lines and as
`artifacts/uart/<ts>-<label>-script.txt`. The SD card (the owner's mega21) was never written.

`tools/flashlane/usb-check.sh` (runs 07:10 and 07:21, `artifacts/uart/20261104-071036-usbcheck-linux-script.txt`,
`…072139-usbcheck-linux2…`): Linux enumerates the stick at 5000 Mbit/s on usb-storage (bulk-only, not UAS),
`max_sectors_kb` 256. Every read with `O_DIRECT`, page cache dropped and buffers flushed before each:

| Linux | result |
|---|---|
| first 1 MiB, 5 reads | 5 × `fc35fa167af341c2` (identical) |
| first 64 MiB, 5 reads (×2 runs) | 5 × `7ab423ef69c4f7d5` |
| 64 MiB at 3000 MiB, 3 reads | 3 × `3b6a07d0d404fab4` |
| 512 MiB at 0, 2 reads | 2 × `6460a45f86f1191e`, 43.1 MB/s |
| write 64 MiB test pattern at 1024 MiB, read back 3 times | 3 × the pattern's own SHA (`3d483593a8cdf105`), 42.5–42.7 MB/s |
| kernel log | no USB, SCSI or xHCI error, reset or timeout |

The test pattern (`tools/flashlane/usb-pattern.py gen FILE BASE_MIB 64`) is pseudo-random with every 512-byte
sector stamped `USBCHK` + its absolute LBA, so a wrong sector read later tells where its bytes came from.

What Haiku had left on the stick, read by Linux (identically every time): sectors 0 and 2 hold Haiku kernel
memory (64-bit pointers `0xffff0000003fe378`, …), the BFS superblock in sector 1 has valid magics but the volume
name is 32 bytes of junk, and the block bitmap (2 KiB block 1) has the right `0xff` bytes only in the first
64 bytes of each 512-byte sector, junk after. So Haiku's **writes** were wrong too, at cache-line granularity.

**No second USB storage device is on the bench** (Linux and `listusb` see a VIA hub, the K120 keyboard, the
Pixart mouse and this stick only), so the comparison is one stick, two systems.

## Haiku before the fix

Network session on `artifacts/images/haiku-pi4-2026-11-04.img` (07:24, `…072404-session-usbcheck.log`), the
same stick at `/dev/disk/usb/0/0/raw`, `tools/pi-tests/usb-integrity.sh` over ssh
(output: `artifacts/usb-integrity/haiku-read1.txt`, `haiku-write1.txt`):

| Haiku, stock xHCI | result |
|---|---|
| first 4 KiB, 3 reads | 2 equal, 1 different |
| first 1 MiB, 5 reads | 5 different SHAs |
| first 64 MiB, 3 reads | 3 different SHAs |
| Linux's pattern at 1024 MiB, `dd bs=1M`, 3 reads | 3 different SHAs; 43 067 / 57 199 of 131 072 sectors wrong; 41.9 / 85.7 / 70.3 MB/s |
| same, `bs=128k` | 130 759 sectors wrong |
| same, `bs=4k` (8 MiB) | every 4 KiB block after the first returns **the first block's data** (LBA tags 2097152–2097159 over and over) |
| syslog | no USB error |
| `mkfs -t bfs` + `mount` | mkfs exit 0, mount "Invalid Argument", "bfs: invalid superblock!" |
| write pattern at 2048 MiB, Haiku reads back 3 times | 3 different SHAs |
| …that write, read by Linux (07:41, `…074122-usbverify-linux1-script.txt`) | identical twice, **13 451 sectors (22 114 64-byte lines) wrong** |

Every wrong span is a whole 64-byte line, the Cortex-A72's cache line (0 lines were half right). In the
`bs=1M` reads, 55–59 % of the wrong lines hold exactly the pattern from 1 MiB earlier: the previous `dd`
iteration's contents of the same buffer, still in the cache. The `bs=4k` read is the extreme case: the 4 KiB
buffer stays cached, so every later read returns the first one's data. That is the fingerprint of a missing
invalidate after a device write to memory, not of a transport fault (a transport fault would not care about
cache lines, and would leave errors in the xHCI log).

## Cause

usb_disk submits its I/O through `IOSchedulerSimple` with **physical** vectors (`queue_bulk_v_physical`): the
TRBs point at the request's own pages — the block cache, the file cache, a user buffer (locked), or a
`DMAResource` bounce buffer. Those are normal cacheable memory. Since 71bc709601 the USB stack's *own* DMA memory
is non-cacheable on arm64, which covers control transfers, HID and every non-physical transfer (they are copied
through those buffers), but nothing handled the payload of a physical transfer: `XHCI::SubmitNormalRequest()`
put the addresses into TRBs and `FinishTransfers()` completed them without touching the caches. The SD
controller's driver does the equivalent (`SdhciBus::_SyncForDevice()`), the xHCI driver did not. On x86 the
controller snoops, so upstream never needed it; usb_disk is the only user of physical transfers in the tree.

- **Write**: the device reads RAM while the new data may still be in dirty cache lines → stale RAM (old page
  contents, kernel memory) on the stick.
- **Read**: the device writes RAM, but lines of the buffer still in the cache (or fetched speculatively during
  the transfer) hide it → the CPU sees the buffer's earlier contents, different on every read.

## Fix: haiku `usb-dma-coherency` eabad7a921

`XHCI::_SyncPhysicalFragment()` cleans and invalidates (`dc civac`, `arm64_dcache_flush_range()` through the
physical map) the current fragment's vectors before the TD is linked (OUT: the device reads the new data; IN: no
dirty line can be evicted over what the device writes), and invalidates them again in `FinishTransfers()` when
an IN transfer completes, before `AdvanceByFragment()` (drops speculatively fetched lines). +41 lines in
`xhci.cpp`/`xhci.h`, compiled only on arm64. Like 71bc709601 it assumes a non-snooping controller on all of
arm64 (TODO: take it from the bus). Built in the worktree `sources/haiku-usbdma` (`scripts/build.sh --generated
… -sHAIKU_REVISION=hrev60314+263 '<usb>xhci'`, no warnings) and tested by booting the 11-04 image with the new
driver in `/boot/system/non-packaged/add-ons/kernel/busses/usb/xhci` and the packaged one blocked
(`/boot/system/settings/packages` `BlockedEntries`), via `pi-session.sh --add`. The binary of the last round is
the committed source (md5 `2056544e43def0a165c616f0cc08a066` on the Pi).

## Haiku with the fix

Sessions `usbfix2` (07:43) and `usbfix3` (07:50), `artifacts/usb-integrity/haiku-read-fix1.txt`,
`haiku-write-fix.txt`, `haiku-bfs-fix2.txt`, `haiku-final-fix.txt`, `haiku-final-bfs.txt`:

| Haiku, fixed xHCI | result |
|---|---|
| first 4 KiB ×3, 1 MiB ×5, 64 MiB ×3 | identical each time |
| 64 MiB at 1024 MiB, `bs=1M` ×3, `bs=128k`, `bs=4k` | all identical, and equal to Linux's read of that region |
| speed, `bs=1M` (first / later reads) | 38.9–50.9 / 59.8–81.1 MB/s (before: 41.9 / 70.3–85.7; within the run-to-run spread) |
| write pattern at 2048 MiB / at 20 000 MiB, read back ×3 | the pattern's SHA every time; 48.5–49.4 MB/s write (before 38.9) |
| …the 20 000 MiB write, read by Linux (07:53, `…usbverify-linux3-script.txt`) | **0 differing bytes**, twice |
| after the BFS cycle: SHA of 64 MiB at 0, 1024, 2048, 20 000 MiB, Haiku vs Linux | `eba6ab60…`, `01416e21…`, `0977b86c…`, `7dbb295d…` on both |
| BFS cycle, twice (`tools/pi-tests/usb-bfs.sh`) | mkfs, mount, copy 72 packages (329 MB): md5 equal; unmount, mount, md5 equal; `checkfs -c` 0 not allocated / 0 already set / 0 could be freed; Linux sees a clean superblock (name `usbbfs`, flags CLEN, contiguous bitmap) |
| syslog | no USB error; automount of the stick's BFS at boot works |

## Side findings

1. **A corrupt BFS volume panics the kernel at mount.** The first boots with the fix read the stick correctly for
   the first time, so the BFS that the old driver had written was found valid by its superblock and automounted:
   "bfs: inode at block 0 corrupt!", "could not create root node!", "volume reports 0 used blocks", then
   `PANIC: block_cache::FreeBlock(): 1, original …, parent 0x0` from `block_cache_delete()` in `DeviceOpener::~DeviceOpener()`
   in `Volume::Mount()`'s error path (mount_server; 4 of 4 boots, `…07{3016,3258,3527,3811}-session-usbfix.log`).
   A block left with `original_data` (in a transaction) when the failed mount deletes the cache. This is
   Haiku's BFS/block cache, independent of USB: any corrupt BFS volume plugged in at boot stops the system.
   Not fixed here (scope). Workaround used: the stick's first 16 MiB zeroed from Linux.
2. That failed mount (or its log replay) also wrote over the first 5 sectors at 1024 MiB (`0xff…` bytes, a
   bitmap- or log-like block; seen identically by Linux and Haiku), inferred from timing: no other writer touched
   that region.
3. **3 GiB.** usb_disk's `DMAResource` allows physical addresses up to 4 GiB (`high_address = UINT32_MAX`), but
   the PCIe bus masters reach only the first 3 GiB (device tree `dma-ranges`; the reason 71bc709601 allocates the
   stack's memory below `0xc0000000`). A diagnostic in a test build of the fix counted payload vectors above
   3 GiB: **0** in the whole `usbfix2` session (all of the reads, writes and BFS cycles above), so it did not
   affect these results, but nothing prevents it under memory pressure on a 4 GB Pi. Follow-up: limit usb_disk to
   the bus's reach (e.g. arm64 `high_address = 0xc0000000`, bounced by the `DMAResource`), with the same TODO.
4. Linux reads this stick at 43 MB/s (256 KiB commands, one `dd` request at a time), Haiku at 60–81 MB/s after the
   first read (128 KiB commands). Not investigated; Haiku's numbers now come with correct data.

## Not explained

The stall of `…064008-session-n6-basepc3.log` (lines ~236–250: "transfer error on slot 5 endpoint 4: USB
transaction", "sending the command block wrapper failed: Device check-sum error", "TRB … was not found in the
endpoint", then a control-pipe timeout, "halted endpoint, reset", "unsuccessful command 15, error Context state",
silence with all CPUs idle) happened **during enumeration** ("usb error hub 2: new device on a port that is already
in use": the stick's SuperSpeed port reconnected), before any usb_disk data transfer, and on buffers the stack
owns (CBW/CSW, non-cacheable). The cache bug cannot cause it. 1 of 57 session boots on 11-03/11-04 shows these
errors; none of the 7 boots here did. Open; a separate item if it recurs.

## For the user-facing docs (not edited here)

- **KNOWN-ISSUES C13**: root cause found — the xHCI driver did no cache maintenance for USB mass-storage data,
  so reads returned stale data and writes stored stale memory, on every USB disk, silently (no error in the log);
  the stick itself is fine (Linux, same Pi and port: consistent reads, correct write-back, no errors). Fixed by
  haiku eabad7a921 (branch `usb-dma-coherency`); until a release carries it: **do not write to, or trust data
  read from, USB disks on images up to 2026-11-04**. Move to resolved when a release includes the fix. A USB disk
  that such an image wrote may hold a corrupt BFS that the fixed system then panics on at boot (side finding 1).
- **HARDWARE-SUPPORT §9, USB mass storage**: 🟡 (data corrupted) on released images; with the fix ✅ — "raw
  reads repeatable and equal to Linux's; Haiku-written data verified under Linux (0 differing bytes in 64 MiB);
  BFS mkfs/mount/329 MB copy/remount/checkfs clean (11-04)". The VL805 row's "USB 3 stick 78–90 MB/s" should say
  that those runs moved corrupt data; with the fix: reads 60–81 MB/s (`dd bs=1M`, after the first), writes 49 MB/s.
- A new KNOWN-ISSUES item for side finding 1 (a corrupt BFS volume at boot panics in `block_cache_delete()`).

## How to repeat

```
python3 tools/flashlane/usb-pattern.py gen usb-pattern.bin 1024 64     # the name usb-check.sh fetches
scripts/sd-cycle.sh --script tools/flashlane/usb-check.sh --script-file usb-pattern.bin --label usbcheck-linux
scripts/pi-session.sh start --image IMG [--add xhci:/boot/system/non-packaged/add-ons/kernel/busses/usb/xhci \
    --add packages:/boot/system/settings/packages]
scripts/pi-ssh.sh put tools/pi-tests/usb-integrity.sh tools/pi-tests/usb-bfs.sh /boot/home/
scripts/pi-ssh.sh 'sh /boot/home/usb-integrity.sh read'                  # then usb-pattern.py cmp on the saved regions
scripts/pi-ssh.sh 'sh /boot/home/usb-integrity.sh write 20000'           # after: put patN.bin in /boot/home/usbint/
scripts/pi-ssh.sh 'sh /boot/home/usb-bfs.sh'                             # destroys the stick's contents
scripts/pi-session.sh stop
scripts/sd-cycle.sh --script tools/flashlane/usb-verify.sh --script-file usb-verify.txt --script-file pat20000.bin
    # usb-verify.txt: "check 20000 pat20000.bin", "sum MIB", "dump KIB", "wipe MIB"
```

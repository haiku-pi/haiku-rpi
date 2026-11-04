# USB storage integrity: the stick or our USB stack? (KNOWN-ISSUES C13)

2026-11-04 07:05–07:55. **Answer: our USB stack.** The bench's USB stick reads and writes correctly under Linux
on the same Pi and port. Haiku moved wrong data in both directions because the xHCI driver did no cache
maintenance for usb_disk's transfers, which DMA straight into and out of ordinary cacheable pages, and the VL805
does not snoop the CPU caches. **Fix: haiku branch `usb-dma-coherency`** (pushed, not merged into `rpi4`):
eabad7a921 `xhci: cache maintenance for physical transfers on arm64` and b90cb3f0d4 `usb_disk: keep buffers
cache-line aligned on arm64`. With it, Haiku reads exactly what Linux reads
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

## Second commit: cache-line alignment (b90cb3f0d4)

Cache maintenance works on whole 64-byte lines. usb_disk's `DMAResource` had no alignment requirement, so a
buffer that does not start or end on a line boundary shares its edge lines with other data; if the CPU writes
that data while the device fills the buffer, the line (written back, or invalidated, around the transfer) loses
one side's bytes. `tools/haiku-tests/usbalign.c` reads 64 KiB into a buffer starting 16 bytes into a line while a
second thread keeps writing the 16 bytes before and after it, 300 rounds, compared with an aligned read:

| Haiku | wrong reads | wrong bytes |
|---|---|---|
| xHCI fix only (sessions `usbalignA`, `usbalignB` with the stock usb_disk) | **300 / 300**, twice | 17 480 in 300 rounds: ≤ 64 per round, i.e. the edge lines (the neighbour's bytes survived) |
| xHCI fix + b90cb3f0d4 (`usbalignB`, both drivers non-packaged) | **0 / 300**, twice | 0 |

b90cb3f0d4 sets `restrictions.alignment = 64` on arm64, so the `DMAResource` bounces such buffers (lengths are
multiples of the 512-byte block, so the end is aligned once the start is). Block cache, file cache and large
`malloc` buffers are page-aligned and go directly as before. With both commits, the same session repeated the
raw reads (identical, equal to Linux's SHA of the regions at 1024 and 20 000 MiB), 39–81 MB/s, and the BFS cycle
(clean): `artifacts/usb-integrity/haiku-final-both.txt`.

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
   Not fixed here (scope). Workaround used: the stick's first 16 MiB zeroed from Linux. **Root cause and fix:
   "Follow-ups" below.**
2. That failed mount (or its log replay) also wrote over the first 5 sectors at 1024 MiB (`0xff…` bytes, a
   bitmap- or log-like block; seen identically by Linux and Haiku), inferred from timing: no other writer touched
   that region.
3. **3 GiB.** usb_disk's `DMAResource` allows physical addresses up to 4 GiB (`high_address = UINT32_MAX`), but
   the PCIe bus masters reach only the first 3 GiB (device tree `dma-ranges`; the reason 71bc709601 allocates the
   stack's memory below `0xc0000000`). A diagnostic in a test build of the fix counted payload vectors above
   3 GiB: **0** in the whole `usbfix2` session (all of the reads, writes and BFS cycles above), so it did not
   affect these results, but nothing prevents it under memory pressure on a 4 GB Pi. Follow-up: limit usb_disk to
   the bus's reach (e.g. arm64 `high_address = 0xc0000000`, bounced by the `DMAResource`), with the same TODO.
   **It does happen under memory pressure (silent wrong reads, then a dead controller); fixed: "Follow-ups".**
4. Linux reads this stick at 43 MB/s (256 KiB commands, one `dd` request at a time), Haiku at 60–81 MB/s after the
   first read (128 KiB commands). Not investigated; Haiku's numbers now come with correct data.

5. **Bench state after this work**: the stick's first 16 MiB are zeros (wiped from Linux at 07:54 and again
   after the last BFS cycle), so it holds no file system. The 64 MiB test patterns at 1024, 2048 and 20 000 MiB
   remain (harmless). Do not make a file system on it from an image without these commits: a stock image would
   write it wrong, and a later fixed (or Linux) boot may then find a corrupt BFS (side finding 1).

## Follow-ups (haiku branch `usb-followups`, 11-04 08:30–11:00)

Two commits on top of `rpi4` b90cb3f0d4, built in the worktree `sources/haiku-usbfollow` (image
`-sHAIKU_PI_GL=1 @pi-mmc`, hrev60314+267; no new warnings in the touched files): **9799738757** `bfs: end the
journal before failing a mount` (side finding 1, KNOWN-ISSUES C14) and **61fe84cd93** `usb_disk: honour the
host controller's DMA high address` (side finding 3). Line numbers below are `rpi4`'s.

### C14: the panic was BFS's failed-mount path, not the block cache

Upstream code (`upstream/master` 8e209770d1, 11-03, fetched 11-04: no newer commit to BFS, the block cache,
DeviceOpener or usb_disk; the code is unchanged there). Sequence on a volume whose root inode is unreadable and
whose block bitmap does not mark the bitmap and log as used (both true of the stick the old driver wrote):

1. `Volume::Mount()` creates the journal (`Volume.cpp:227`) and starts the block allocator, whose initializer
   thread finds the reserved area free and repairs it in a `Transaction` (`BlockAllocator.cpp:830`: "Space for
   block bitmap or log area was not reserved!"). The journal batches small transactions: `Transaction::Done()`
   leaves it open in the block cache (`Journal.cpp:1114`, `fUnwrittenTransactions++`).
2. The root node fails (`Volume.cpp:289`, "could not create root node!"); the error path waits for the allocator
   thread and returns, without deleting the journal.
3. The `DeviceOpener` (`Volume.cpp:190`) destructor deletes the block cache: `block_cache_delete()`
   (`block_cache.cpp:3783`) frees every block, and `FreeBlock()` panics on block 1 (the first bitmap block),
   still holding the open transaction's `original_data` (`block_cache.cpp:1775`).

The leaked journal also leaves its log flusher thread behind. **Not our block-cache change**: the panicking
boots ran hrev60314+262 = 162164220d, before a9db442988 (+263), and the host shell below uses its own copy of
the block cache. **Fix (9799738757)**: on every failure after the journal exists, wait for the allocator, delete
the root node and the journal (whose destructor ends the transaction, as `Unmount()` does), then return; the
mount fails with "Invalid Argument" (B_BAD_VALUE).

| test | stock | with 9799738757 |
|---|---|---|
| host: `bfs_shell` (built from the worktree) on a 64 MiB BFS made with `bfs_shell --initialize`, bitmap blocks 1–2 and the root inode block zeroed (`tools/diagnostics/bfs-corrupt.py IMG --bitmap --root`) | `block_cache::FreeBlock(): 1, original 0x…, parent (nil)`, exit 139 | `Mounting FS failed: Invalid argument`, exit 1 |
| host controls: only `--root` / only `--bitmap` | mount fails cleanly / mounts (repaired) | same |
| Pi, that image written to the stick (sha `3203afd67dd0d318`, read back equal), `mount -t bfs` | hrev60314+265 (image-2026-11-04b), session `c14A5-stock`: the same `PANIC: block_cache::FreeBlock(): 1` from `block_cache_delete` / `DeviceOpener::~DeviceOpener()` / `Volume::Mount` (`artifacts/uart/20261104-104628-session-c14A5-stock.log` line 398) | +267, sessions `c14B1`, `c14B2`: `mount` 5 times and `mountvolume -all` once: each "Invalid Argument", no panic, the system keeps running (`artifacts/usb-integrity/haiku-high-B.txt`, `haiku-c14-B2.txt`) |

Observations:

- **Automount at boot is a race.** The 4 panicking boots of side finding 1 mounted the stick through
  `B_DEVICE_ADDED` (the stick enumerated at ~45 s, after mount_server started), where removable disks use "all
  volumes" (`AutoMounter.cpp:452-460`). Three stock boots today (`c14A2`–`c14A4`, stick published at ~39.6 s)
  never tried: the initial scan uses the normal mode, "previously mounted volumes" (`AutoMounter.cpp:171-186`).
  So whether a corrupt stick stopped a boot depended on enumeration timing. The Pi tests above therefore used
  `mount` and `mountvolume`, which reach the same `fs_mount()` → `bfs_mount()` → `Volume::Mount()`; the
  boot-time trigger itself was not reproduced today with either kernel.
- **A failed mount still writes.** Deleting the journal flushes the repair: after the first failed mount the
  stick's first 64 MiB had changed (sha `6901b9972f755ff2`), and later mounts no longer repaired anything. This is
  what an `Unmount()` would write too, and BFS's normal mount-time repair; not changed.
- **Upstream quirk, not fixed:** `_Initialize()` computes the used-block count before the repair and stores it
  over the count the repair just raised (`BlockAllocator.cpp:843-850`): "volume reports 2188 used blocks, correct
  is 0", next mount "reports 0 …, correct is 2051". A repaired volume reports too much free space until `checkfs`.
- `block_cache_delete()` still panics for any file system that deletes a cache with a transaction open; its
  comment ("they will all be aborted") suggests it was meant to abort them. Left as is; BFS was the caller at fault.

### 3 GiB: usb_disk handed the xHCI controller memory it cannot reach

- The Pi 4 with 4 GB has RAM up to `0xfc000000` (the loader's ranges: `0x40000000` + 3 154 116 608 bytes), and
  the PCIe inbound window covers `0`–`0xc0000000`. `BrcmPCIController` publishes that as `B_DMA_HIGH_ADDRESS`
  (`BrcmPCIController.cpp:136-145, 184`), "inherited by the PCI devices behind us", but nothing below it read it.
- The USB stack's own memory (rings, contexts, the buffers non-physical transfers are copied through) is below
  `0xc0000000` on arm64 (`PhysicalMemoryAllocator.cpp:38-47`, `Stack.cpp:316`, 71bc709601): safe.
- usb_disk is the one user of physical transfers (`usb_disk.cpp:227`, `:1817`): the request's own pages go into
  the TRBs. Its `DMAResource` allowed up to `UINT32_MAX` (`usb_disk.cpp:957`; boot log: `DMAResource…: low/high
  0/ffffffff`), so block cache, file cache and locked user pages above 3 GiB went to the controller as they were.
- **Fix (61fe84cd93)**: usb_disk reads `B_DMA_HIGH_ADDRESS` from its device node's ancestors (usb_disk → USB
  device → root hub → xHCI bus → xHCI PCI → PCI device → … → `brcmstb_pci`) and keeps the lower value; the
  `DMAResource` bounces buffers above it (`dma_resources.cpp:605-608`; its bounce buffers are allocated below the
  limit, `:262`, 128 KiB since 8edea64c6b). Boot log with it: `DMAResource…: low/high 0/c0000000`. No
  arm64-specific constant: platforms whose PCI host does not publish the attribute keep 4 GiB.

`tools/haiku-tests/usbhigh.c` forces high memory on the 4 GB bench Pi: it takes all but 320 MiB of the free
memory in 64 MiB chunks (touched), then reads the stick's pattern region at 20 000 MiB into every 1 MiB slice of
every chunk (each slice prefilled with `0x5a`), checking each sector's `USBCHK`+LBA tag and comparing the
slice's hash with the same MiB in the first chunk:

| session | usb_disk | slices | wrong | other |
|---|---|---|---|---|
| `c14A` (image-2026-11-04b, +265) | stock + a diagnostic counter (not committed) | 3 392 (3 392 MiB in 53 chunks) | **866**, all in chunks 39–52 (the last allocated); 1 968–2 048 of 2 048 sectors untagged: the buffer kept its `0x5a`, **no read error, no USB error** | counter: ≥ 4 096 payload vectors above 3 GiB (first `0xbfff6000`+); the next command (a 64 MiB `dd` write) ended in xHCI **"Host System Error"**: the controller dead, the stick unreadable until power-off (`artifacts/usb-integrity/haiku-high-A.txt`, `haiku-high-A-syslog.txt`) |
| `c14B1` (+267) | 61fe84cd93 | 3 392, then 3 520 | **0**, 0 | 65.1 / 62.6 MB/s (stock: 66.0); no USB error |

So on a 4 GB Pi, reading a USB disk into memory above 3 GiB silently returned nothing (stale buffer contents),
and writing from it killed the controller; it needs only enough memory in use (the earlier diagnostic saw 0 such
vectors in a lightly loaded session). With the fix, `c14B2` also ran the BFS cycle (`usb-bfs.sh`: 72 files,
325 MB, md5 equal after copy and remount, `checkfs` 0/0/0) and repeatable raw reads
(`artifacts/usb-integrity/haiku-bfs-followups.txt`); 0 panics and 0 "Host System Error" in the `c14B1`/`c14B2`
UART logs. The stick's first 16 MiB were zeroed afterwards (read back as zeros): no file system on it, as
before; the pattern at 20 000 MiB remains (the one at 1024 MiB is now BFS data).

**Bench incident (c14B2, ~10:56):** `mountvolume -all` also mounted the **SD card** (`/dev/disk/mmc/0/1`, the
mega22 card, BFS read-write, and its FAT) for about a minute before both were unmounted (exit 0). **The FAT
partition was written:** a read-write FAT mount sets the volume's dirty bit in the FAT and a clean unmount clears
it (`fat/kernel_interface.cpp:3534`, `:3573`, `markvoldirty()`), so its content should be back as it was. BFS
writes nothing at mount or unmount without a transaction and reported no log replay or repair; nothing was run
on either volume, but Tracker activity on a newly mounted volume was not ruled out. Not verified: re-run the
mega22 card boot check (the 09:57 one predates this) before the card is used. Use `mount DEV DIR`, never
`mountvolume -all`, on the bench.

Still open: the same window applies to any other PCIe bus master that DMAs into request memory (an NVMe disk on
a CM4 board, say); the controller's cache coherency is still assumed per architecture (the TODOs of 71bc709601
and eabad7a921).

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
  haiku eabad7a921 + b90cb3f0d4 (branch `usb-dma-coherency`); until a release carries it: **do not write to, or trust data
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
scripts/pi-ssh.sh '/boot/home/usbalign /dev/disk/usb/0/0/raw 1024 300'   # tools/haiku-tests/usbalign.c, cross-built
scripts/pi-ssh.sh '/boot/home/usbhigh /dev/disk/usb/0/0/raw 20000 320'   # tools/haiku-tests/usbhigh.c: buffers above 3 GiB
# C14: a corrupt BFS (host), written to the stick, then mounted (stock kernel: panic; fixed: "Invalid Argument")
truncate -s 64M c14.img && bfs_shell --initialize c14.img test   # bfs_shell: generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/
python3 tools/diagnostics/bfs-corrupt.py c14.img --bitmap --root
scripts/pi-ssh.sh 'dd if=/boot/home/c14.img of=/dev/disk/usb/0/0/raw bs=1M conv=notrunc; sync; mkdir -p /c14; mount -t bfs /dev/disk/usb/0/0/raw /c14'
scripts/pi-session.sh stop
scripts/sd-cycle.sh --script tools/flashlane/usb-verify.sh --script-file usb-verify.txt --script-file pat20000.bin
    # usb-verify.txt: "check 20000 pat20000.bin", "sum MIB", "dump KIB", "wipe MIB"
```

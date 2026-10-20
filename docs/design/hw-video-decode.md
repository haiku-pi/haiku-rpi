# Hardware video decoding on the Raspberry Pi 4 (HEVC on the rpivid block)

Status (2026-10-20): stages 1-3 written and built (driver, hwaccel in the ffmpeg6 package, test tool),
host-tested (§6), not yet run on the Pi. Owner's goal: hardware video decode "integrated with the standard video
libraries": MediaPlayer → media kit → its ffmpeg plugin → libavcodec decodes on the hardware.

Citation keys:
- **[L]** Raspberry Pi Linux, `drivers/media/platform/raspberrypi/hevc_dec/` (`hevc_d_h265.c`,
  `hevc_d_hw.[ch]`, `hevc_d_video.c`), rpi-6.18.y. GPL: facts only, our code is written anew (MIT).
- **[DTS]** the firmware's `bcm2711-rpi-4-b.dtb` (`artifacts/pi-firmware/`).
- **[FF]** FFmpeg 6.1.6 (`libavcodec/hevcdec.[ch]`, `hwaccel_internal.h`, `pthread_frame.c`).
- **[H]** `sources/haiku` (`rpi4`).

## 0. Summary

- The BCM2711 has one directly programmable video decoder: the **rpivid** HEVC block
  (`codec@7eb10000`, `brcm,bcm2711-hevc-dec`). It is a stateless, register-driven decoder: no
  firmware, no VCHIQ, no microcode. It needs a clock from the VideoCore firmware (mailbox clock 11),
  memory it can DMA, and its interrupt. **H.264 is not reachable this way**: on the Pi 4 it is decoded
  by the VideoCore firmware behind MMAL/VCHIQ — a different, much larger project, out of scope.
- **Split**: libavcodec's own HEVC decoder parses everything (parameter sets, slice headers, the DPB,
  reference lists, output order). A new hwaccel in libavcodec turns that state into the block's
  programming — a command buffer for phase 1 plus phase-2 register values — exactly the information
  Linux's V4L2 stateless HEVC controls carry. A kernel driver validates and runs it: it owns the
  physical addresses, the scratch buffers, the interrupt and the clock.
- **Integration**: a second libavcodec decoder, `hevc_rpivid`, registered ahead of `hevc`, so
  `avcodec_find_decoder(AV_CODEC_ID_HEVC)` — what the media kit's ffmpeg plugin calls — returns it.
  It is FFmpeg's HEVC decoder with the hwaccel attached when the stream fits the block and the
  device opens; otherwise it is the plain CPU decoder. Frames are ordinary `yuv420p` /
  `yuv420p10le` system-memory frames, which the plugin already converts for its consumers. No
  change to the plugin or to MediaPlayer is needed for stage 2.

## 1. Hardware facts

From [DTS] and [L]:

| What | Value |
|---|---|
| DT node | `/scb/codec@7eb10000`, `compatible = "brcm,bcm2711-hevc-dec", "raspberrypi,hevc-dec"`, no `status` (enabled), no power domain |
| Registers | `reg[0]` "hevc" bus 0x7eb00000 + 0x10000 → CPU 0xfeb00000; `reg[1]` "intc" 0x7eb10000 + 0x1000 → 0xfeb10000 |
| Interrupt | GIC SPI 98, level |
| Clock | `clocks = <&firmware_clocks 11>`: mailbox clock ID 11 (`RPI_FIRMWARE_HEVC_CLK_ID`); [L] sets it to the firmware's maximum rate before enabling |
| Identification | `VERSION` (block + 60) must read **0x202** ([L] refuses anything else). MMIO to the block with its clock off does not complete: nothing touches it before the clock is on |
| DMA | `/scb` dma-ranges: bus 0 → CPU 0, 16 GiB: plain physical addresses. Address registers take `addr >> 6` (64-byte alignment), length/stride registers `(bytes + 63) >> 6` |

**Two phases per picture.**

1. *Phase 1 (entropy decode)* executes a **command buffer** from memory: 64-bit entries
   `register offset | value << 32`, `CFNUM` entries at `CFBASE`. It writes prediction-unit (PU) and
   coefficient data into two scratch buffers (`PUWBASE/STRIDE`, `COEFFWBASE/STRIDE`, a stride per CTB
   row). Success is `CFSTATUS == CFNUM`. If either scratch buffer is too small, `STATUS` has bit 4
   (PU exhausted) or bit 3 (coefficients exhausted): enlarge and run phase 1 again ([L]
   `check_status`, sizes from `round_up_size`: the next 3·2ⁿ or 4·2ⁿ, starting at w·h/4 and w·h).
2. *Phase 2 (reconstruction)* is programmed by direct register writes: the PU/coefficient read
   bases, the output planes, 16 reference slots (luma/chroma base each), `CONFIG2`, `FRAMESIZE`,
   `CURRPOC`, the collocated motion-vector buffers (`MVBASE` for this picture's, `COLBASE` for the
   collocated picture's), then `NUMROWS` = picture height in CTBs starts it.

Completion: the "intc" (ARGON) controller, `ICTRL` at +0: `ACTIVE1` (bit 0) ends phase 1, `ACTIVE2`
(bit 4) phase 2; enables are bits 2 and 6. Acknowledge by writing the value back with
`SET_ZERO_MASK` (bits 11-19) cleared. Status bits only latch once enabled: enable first, then clear
([L] `hw_setup`).

**Phase-1 programming** ([L] `hevc_d_h265.c`): per slice segment, the slice messages (slice kind,
reference descriptors with POC and — for weighted prediction — six weight words per reference,
deblocking, chroma QP offsets; sent for I slices too), the bitstream (`BFBASE`, `BFNUM`, two
`BFCONTROL` writes: stop, then start with emulation-prevention removal, `data offset & 63`), the
CABAC initial probabilities (156 bytes at 0x1000, computed from the slice QP and init type) and a
`TRANSFER` that backs them up, `SPS0/SPS1/PPS`, the scaling factors (4064 bytes at 0x2000, the first
slice only), `SLICESTART`, then one *entry point* per tile or wavefront row (`TILESTART/TILEEND`,
`BEGINTILEEND`, `SLICE`, `QP`, `MODE`, `CONTROL`), with `STATUS` writes marking where each ends.

**Output: SAND, column 128.** Each plane is a sequence of 128-byte wide columns; byte *b* of row *y*
of column *c* is at `base + c · column_stride + y · 128 + b`. Luma column stride = height (rounded
to 16) × 128; chroma (interleaved Cb/Cr, half the rows) half that. 8-bit: one sample per byte, 128
per column. 10-bit: three samples per little-endian 32-bit word, low bits first (96 per column),
values 0..1023 (`yuv420p10le` order, not P010). Column count = ⌈width / 128⌉ (8-bit) or
⌈⌈width / 3⌉ / 32⌉ (10-bit). Collocated MV buffer: stride = width rounded to 64, size = stride ·
(height rounded to 64) / 16 per picture.

**Limits** ([L] format and SPS checks): Main and Main 10, 4:2:0 only, 32..4096 luma samples per side,
CTB 16/32/64, transform blocks ≤ 32, at most 16 reference slots, no range-extension or SCC tools.

**Ordering** (non-coherent DMA master): `dsb sy` after writing the command buffer and bitstream and
before the kick register; `dsb sy` after a completion is observed and before the output is read. A
completion can be observed twice (the interrupt handler and a polling waiter): before starting a
phase, a pending completion of that phase is cleared, or the next wait ends at once on the previous
picture's completion. A rare, non-deterministic pixel mismatch under heavy decode DMA has been
reported on this SoC and never explained; a *deterministic* mismatch is a bug of ours, an
intermittent one is not a stage-2 blocker.

## 2. Kernel driver: `drivers/video/rpivid`

New-style device-manager driver in the style of `drivers/graphics/v3d`: `support()` matches the fdt
node by its first `compatible`; `init_driver` reads `reg[0]`, `reg[1]`, the interrupt and the clock
cell, and the bus's DMA window (`fdt->get_dma_window`). It publishes **`/dev/video/rpivid/0`** (the
`video` directory: opening it probes `drivers/video`). `B_KEEP_DRIVER_LOADED`.

**Power**: nothing touches the block at boot. The first open: mailbox `GET_MAX_CLOCK_RATE(11)`,
`SET_CLOCK_STATE(11, on)`, `SET_CLOCK_RATE(11, max)`, confirmed by `GET_CLOCK_STATE`; then the
registers are mapped, `VERSION` must be 0x202, the interrupt controller is enabled and cleared and
the handler installed. The last close masks the interrupts, removes the handler and switches the
clock off (as [L], which gates the clock while idle). `read()` returns a one-line report (version,
clock, interrupt, addresses, pictures decoded) — the stage-1 test is `cat /dev/video/rpivid/0`.

**Memory** (per open file, by handle, freed with the file):

| Kind | Who writes / reads | Allocation and mapping |
|---|---|---|
| *bitstream* buffer | CPU writes, block reads | contiguous below the DMA window end, kernel + client mappings write-combining (the client mapping is a clone of the kernel area, as v3d's `MMAP_BO`) |
| *picture* buffer | block writes (output) and reads (reference), CPU reads | one contiguous area: luma columns, chroma columns, the collocated MV buffer; geometry computed by the kernel from width/height/bit depth; cached and mapped **read-only** into the client (the CPU never dirties it), invalidated by the kernel after each decode into it. `RPIVID_PICTURE_UNCACHED` maps it write-combining instead (no cache maintenance; a diagnostic) |
| command buffer, PU and coefficient scratch, a zeroed MV buffer | kernel / block only | device-owned, contiguous, grown on demand |

**Decode** (`RPIVID_DECODE`, synchronous, one at a time under the device lock): the client passes
the command entries (a user pointer), the bitstream handle, the output picture, 16 reference picture
handles (0 = the output picture, as [L] fills unused slots), the collocated picture, `CONFIG2`,
`CURRPOC`. The kernel:

1. checks every handle and that all pictures have the output's geometry;
2. copies the command entries and **validates** them: only phase-1 registers (the 0..0x7c block
   minus `VERSION`, the address/stride and kick registers 80..92 and 108..116; the probability,
   scaling and slice-message arrays); `BFBASE` values are byte offsets (>> 6) into the bitstream
   buffer and are rebased to its bus address; every `BFNUM` must stay inside the buffer; `SPS0`'s
   bit depth and CTB size must match the picture; `CONFIG2`'s bit depth, CTB size and MV flags must
   match the buffers (a picture without an MV buffer cannot be written or read as collocated);
3. writes them to the command buffer, sizes the scratch buffers, runs phase 1 (re-running it up to
   five times on PU/coefficient exhaustion), then phase 2 with the addresses it owns;
4. invalidates the output picture's cache lines, returns `STATUS`, `CFSTATUS`, runs and times.

The wait sleeps on a semaphore the interrupt handler releases, re-checking the controller every
10 ms (a lost interrupt costs 10 ms, not the picture). A phase that does not finish in 1 s (phase 1)
or 2 s (phase 2) marks the device **broken**: the clock goes off, every later decode fails, and the
buffers the block was given are kept for good (a block that stopped may still write them).

ioctl API: `headers/private/drivers/rpivid.h` (`RPIVID_GET_INFO`, `RPIVID_CREATE_BUFFER`,
`RPIVID_CREATE_PICTURE`, `RPIVID_DELETE_BUFFER`, `RPIVID_DECODE`; `RPIVID_API_VERSION` checked by
the client). Why the command buffer is built in userland rather than in the kernel (as [L] does from
V4L2 controls): ~1000 lines of HEVC-specific programming stay out of the kernel, which keeps the
security boundary — addresses, buffer bounds, a register whitelist — small; it is the same split as
V3D (Mesa builds control lists, the kernel validates and relocates).

Not in v1: overlapping phase 1 of picture N+1 with phase 2 of picture N ([L] pipelines them with two
scratch sets) — the obvious next performance step; zero-copy scanout of the SAND buffers.

## 3. libavcodec: the `rpivid` hwaccel and `hevc_rpivid`

Files (ours, MIT, Haiku style; copied into `libavcodec/` by the ffmpeg6 build):
`patches/ffmpeg6/files/libavcodec/` — `rpivid_hevc.[ch]` (FFmpeg state → parameters, the hwaccel
callbacks, buffer pools), `rpivid_cmd.[ch]` (parameters → command entries and `CONFIG2`, no OS
dependency: host testable), `rpivid_device.[ch]` (the ioctls; on any OS but Haiku, "no device"),
`rpivid_sand.[ch]` (SAND → planar, NEON for 8-bit chroma), `rpivid_haiku.h` (a copy of the uAPI
header). The hooks into FFmpeg's own files are `patches/ffmpeg6/0001-hevc-rpivid.patch` (LGPL, like
the files it changes).

**Parameters.** `rpivid_cmd.h` has codec-neutral structs shaped like the V4L2 stateless HEVC
controls (SPS/PPS fields per picture, slice-header fields + reference lists per slice segment), so
the mapping from `HEVCContext` (`s->ps.sps`, `s->ps.pps`, `s->sh`, `s->ref->refPicList`,
`s->collocated_ref`) is the one FFmpeg's v4l2-request HEVC code performs. Details that matter:
the slice data offset is FFmpeg's bit position after the slice header (`get_bits_count` + the
alignment bits) converted from RBSP to raw NAL bytes (emulation prevention bytes counted, as
`BFCONTROL` removes them); trailing zero bytes are not slice data; FFmpeg's `chroma_offset_lX` is
already the derived ChromaOffset and `luma_weight_lX` the full weight; reference slots are numbered
in first-use order over the picture's lists, a reference the block did not decode (FFmpeg
generated it for a missing picture) points at the output picture as [L] does.

**Pictures.** Each `HEVCFrame` gets a picture buffer through the hwaccel's per-frame private data
(`frame_priv_data_size`), from a pool keyed by the stream geometry: it lives exactly as long as
FFmpeg keeps the frame as a reference. `end_frame` decodes, then converts SAND → `yuv420p` (8-bit) or
`yuv420p10le` (10-bit) into the frame FFmpeg allocated: consumers see a software decoder.

**Attach and fallback.** At `get_format()`, after the software format is chosen, `hevc_rpivid`
attaches the hwaccel if the SPS (and the PPSs seen so far) are inside the block's limits, the device
opens and its API version matches; else it decodes on the CPU and logs why ("rpivid: CPU decode:
..."). Coding tools the programming has but no test stream has verified on the block yet (16x16 CTBs,
PCM, long-term references, tiles, dependent slice segments, lossless CUs, constrained intra
prediction) send the stream to the CPU unless `FFMPEG_RPIVID=2`. A picture the block cannot take
(a later PPS outside the limits, no memory for a picture) continues on the CPU decoder; a picture the
block fails is dropped. The CPU decoder lacks the block's motion fields (temporal MV prediction), so
with TMVP the pictures up to the next IRAP are dropped (the caller keeps its last picture), and the
RASL pictures of a CRA too. At the next IRAP the block is taken again (three times per stream at
most). Knobs: the decoder option `rpivid` (0 off, 1 on, 2 every tool) and `FFMPEG_RPIVID=0|1|2`;
`FFMPEG_RPIVID_UNCACHED=1` maps the pictures write-combining (a diagnostic).

**Threads.** The media kit plugin sets `thread_count = cpu_count`. `hevc_rpivid` offers slice threads
but not frame threads: frame threading would hand the (thread-unsafe) hwaccel state between thread
contexts on every picture ([FF] `pthread_frame.c`), for no gain since the block decodes one picture
at a time. The cost: a stream that `hevc_rpivid` decodes on the CPU (outside the block's limits)
runs without frame threads. Stage 3 removes it: the plugin asks after the first picture whether the
block took the stream and otherwise reopens the plain `hevc` decoder.

## 4. Media kit

Nothing to change for stage 2: `AVCodecDecoder::Setup` calls `avcodec_find_decoder`, which returns
`hevc_rpivid`; MediaPlayer gets `yuv420p` frames as from the CPU decoder. Stage 3: the reopen above,
a log line naming the decoder in use, and (later) handing SAND/NV12 frames to app_server's overlay
instead of converting to planar.

## 5. Build and packaging

- Driver: `scripts/build.sh rpivid`; in the image through `AddNewDriversToPackage video :
  rpivid@arm64` (`build/jam/packages/Haiku`).
- ffmpeg6: `scripts/build-ffmpeg.sh` (called by `scripts/build-packages.sh`): `scripts/cross-port.sh
  --patches patches/ffmpeg6` applies the hooks patch and copies `patches/ffmpeg6/files/` into the
  tree; package revision 2 (`ffmpeg6-6.1.6-2`, also in `build/jam/repositories/HaikuPorts/arm64`).
- Tests: `tools/media-tests/gen-hevc-clips.sh` (host ffmpeg + libx265) and `tools/media-tests/build.sh`
  (`hevcdec`, plus FFmpeg's libraries in `non-packaged/lib`, which come before the packages' — so an
  image with the old ffmpeg6 package tests the new one) fill `artifacts/media-tests/hevc/non-packaged`
  for `mkimage-pi4.sh --add-tree`.

## 6. Stages and tests

| Stage | What | Exit criterion |
|---|---|---|
| 1 | driver probes, clocks the block, reads VERSION | `tools/pi-tests/rpivid.sh`: `RPV ident rpivid: version 0x202 ...` |
| 2 | one intra picture bit-exact | `hevcdec` on `intra.265` (x265 defaults, 1 I picture): `HEV frame 0 match ...` and `HEV result PASS` |
| 3 | inter pictures, MediaPlayer | `hevcdec` PASS on `ipb.265`, `weighted.265`, `main10.265`, `hd.mp4`; MediaPlayer plays `hd.mp4` (HDMI) with "rpivid: hardware HEVC decode" in its log |

Host tests (2026-10-20, x86 host, no Pi; FFmpeg built natively with the patch):
- no device (any OS but Haiku): `hevc_rpivid` is picked by `avcodec_find_decoder` and decodes every
  test clip bit for bit like `hevc`;
- a mock of the driver API that logs every job (command entries, the bitstream CRC per slice,
  CONFIG2, the reference slots and collocated picture by POC) and "decodes" by writing the CPU
  decoder's picture into the output, SAND-tiled: all 4 clips and 24 x265 variants (multiple slices,
  no WPP, CTB 16/32, scaling lists, transform depth, AMP, no SAO, chroma QP offsets, deblocking
  offsets and off, constrained intra, lossless, weighted P+B, 4 references + B pyramid, transform skip,
  no sign hiding, merge candidates, no TMVP, Main 10 WPP + slices, 720p, closed and open GOPs) give
  frames bit-exact with the CPU decoder through the whole output path (DPB, SAND 8/10 bit, cropping,
  frame order), under ASan; and their command streams and phase-2 programming are identical, entry
  for entry, with an independent implementation of the same programming that was proved bit-exact
  on this block;
- faults injected in the mock (a failed picture, no memory for a picture): the stream continues on
  the CPU, every frame it emits equals the CPU decoder's, and the block is taken again at the next
  IRAP.

## 7. Risks

- Contiguous memory: a 1080p picture is ~3.4 MB contiguous, a stream needs DPB size + a few. Late
  allocations can fail on a fragmented system: the hwaccel then falls back to the CPU (logged).
- The intermittent mismatch above (§1).
- Performance: synchronous decode, no phase overlap; the SAND → planar copy costs a few ms per 1080p
  picture on one core.

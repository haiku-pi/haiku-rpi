# Hardware video decoding on the Raspberry Pi 4 (HEVC on the rpivid block)

Status (2026-10-20): stages 1-3 run on the Pi, bit-exact (first version: synchronous). Then the speed
work (§8): the driver runs phase 1 of a picture during phase 2 of the one before, the hwaccel converts a
picture while the block decodes the next, SAND → planar in NEON and on the slice threads; heavy test
streams (1080p/2160p, Main/Main 10, 20-30 Mbit/s) and hevcdec measuring frames/s and CPU time. Host-tested
(§6); the Pi numbers are pending. Owner's goal: hardware video decode "integrated with the standard video
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
  by the VideoCore firmware behind MMAL/VCHIQ — done since as H21 (§0a, `vchiq.md`).
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

## 0a. H.264: a licence-clean route (survey 2026-11-02; done as H21, 2026-11-05)

**Done** (`vchiq.md`): (1) FreeBSD's VCHIQ as the `vchiq` driver (`/dev/vchiq`), (2) Broadcom's libmmal/libvchiq/
VCOS as the raspberrypi_userland package, (3) FFmpeg's own MMAL decoder `h264_mmal` in ffmpeg6 revision 4, which the
media kit's ffmpeg plugin prefers for H.264 and replaces by the software `h264` when it does not open or fails
(`vchiq.md` §8.1): MediaPlayer and WebPositive decode H.264 on the VideoCore (1080p30 at 88 % of one CPU instead of
159 %, 1080p60 at 24 fps instead of collapsing), with the H.264 block held at 500 MHz while MMAL is in use. Unlike
`hevc_rpivid` (inside libavcodec, its own CPU fallback) the fallback is in the plugin, as the VideoCore parses the
whole stream. Branches `vchiq` + `h264-mmal`, not merged yet. The survey as it was:

H.264 on the Pi 4 is decoded by the VideoCore firmware (its `vc.ril.video_decode` MMAL component),
reached through VCHIQ (shared-memory message queues + doorbells). Linux does it in the Raspberry Pi
kernel with `bcm2835-codec` (V4L2 M2M, up to 1920×1920) on `vchiq-mmal`, `vc-sm-cma` and VCHIQ — not
in mainline. Licences of the pieces (headers read 2026-11-02):

| Piece | Where | Licence | Use for us |
|---|---|---|---|
| VCHIQ core (`vchiq_core.c`, `vchiq_arm.c`, headers) | raspberrypi/linux `staging/vc04_services/interface/vchiq_arm` | **GPL-2.0 OR BSD-3-Clause** (Broadcom) | usable under BSD-3 |
| VCHIQ core, already on a non-Linux kernel | FreeBSD `sys/contrib/vchiq` (arm64 since 2025-11, Linux merges 2026-08); NetBSD `sys/external/bsd/vchiq` | Broadcom BSD-3 or GPL-2 | **the base to port** |
| VCHIQ client examples | FreeBSD `bcm2835_audio.c`, NetBSD `bcm2835_vcaudio.c` (service `AUDS`) | BSD-2 | reference |
| MMAL client + userspace VCHIQ library + VCOS | raspberrypi/userland `interface/mmal`, `interface/vchiq_arm`, `interface/vcos` (archived 2025-08); Ultibo's fork | **BSD-3-Clause** | port as libmmal |
| Kernel MMAL client, codec, buffer sharing | Linux `vchiq-mmal`, `bcm2835-codec`, `vc-sm-cma` | GPL-2.0 only | behaviour reference only, no code |
| Circle's VCHIQ port | rsta2/circle `addon/vc4` | GPL (project GPL-3.0) | no |

No BSD system or small OS drives the video decoder; they use VCHIQ for audio only.

Plan if scheduled (estimated 2.5–4 weeks + Pi time): (1) port FreeBSD's VCHIQ to a Haiku kernel driver
exposing `/dev/vchiq` with the ioctls the userland library uses; (2) port userland's libmmal/libvchiq
(VCOS pthreads backend); (3) a media-kit decoder add-on on `vc.ril.video_decode`, frames copied by VCHIQ
bulk transfers first, zero-copy (our own buffer import; `vc-sm-cma` is GPL) and stage-6 overlays later.
Risks: the path is legacy firmware (still in Pi 4 firmware; the Pi 5 has no H.264 block); gain for
playback alone is small (CPU: 1080p H.264 at ~100 fps on 4 threads); VCHIQ also unlocks the camera, the
ISP, H.264 encode and JPEG.

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

**Decode: a two-stage pipeline** (interface version 2). `RPIVID_SUBMIT` queues a picture and returns
at once; `RPIVID_WAIT` returns its result once it is done (`RPIVID_DECODE` = both, the synchronous
form). The client passes the command entries (a user pointer), the bitstream handle, the output
picture, 16 reference picture handles (0 = the output picture, as [L] fills unused slots), the
collocated picture, `CONFIG2`, `CURRPOC`. The submit:

1. checks every handle and that all pictures have the output's geometry;
2. copies the command entries and **validates** them: only phase-1 registers (the 0..0x7c block
   minus `VERSION`, the address/stride and kick registers 80..92 and 108..116; the probability,
   scaling and slice-message arrays); `BFBASE` values are byte offsets (>> 6) into the bitstream
   buffer and are rebased to its bus address; every `BFNUM` must stay inside the buffer; `SPS0`'s
   bit depth and CTB size must match the picture; `CONFIG2`'s bit depth, CTB size and MV flags must
   match the buffers (a picture without an MV buffer cannot be written or read as collocated);
3. queues a job that holds a reference to every buffer it names (a buffer the client deletes stays
   until no job needs it), and wakes the decode thread. At most 4 jobs per file not waited for.

The **decode thread** (one per device, `B_URGENT_DISPLAY_PRIORITY`, woken by the interrupt handler and
by submits) starts each phase as soon as it can: phase 2 of the oldest picture whose phase 1 is done,
then phase 1 of the oldest queued picture into a free **scratch set** (PU + coefficient buffers; two
sets, as [L] keeps several) — so phase 1 of picture N+1 runs while phase 2 reconstructs picture N, the
block's two engines working at once ([L] claims phase 1 of the next picture while phase 2 runs).
Phase 1 takes pictures in submission order and phase 2 in phase-1 order: a picture's references
(submitted before it) are complete before its phase 2 reads them, and a picture buffer that becomes the
output of a later picture is written only after every earlier picture is done with it. Phase 1 is
re-run up to five times on PU/coefficient exhaustion (that set grows; only its job uses it). The wait
invalidates the output picture's cache lines (in the client's time, without the lock: the block goes
on), and returns `STATUS`, `CFSTATUS`, runs, queue/phase times. The device report counts **phase
overlaps** (a phase started while the other phase of another picture ran).

While a phase runs the thread re-checks the controller every 10 ms (a lost interrupt costs 10 ms, not
the picture). A phase that does not finish in 1 s (phase 1) or 2 s (phase 2) marks the device
**broken**: the clock goes off, every queued picture fails, every later decode fails, and the buffers
of the pictures in the block are kept for good (a block that stopped may still write them). Closing a
file waits for its pictures in the pipeline.

ioctl API: `headers/private/drivers/rpivid.h` (`RPIVID_GET_INFO`, `RPIVID_CREATE_BUFFER`,
`RPIVID_CREATE_PICTURE`, `RPIVID_DELETE_BUFFER`, `RPIVID_DECODE`, `RPIVID_SUBMIT`, `RPIVID_WAIT`;
`RPIVID_API_VERSION` 2, checked by the client). Why the command buffer is built in userland rather than in the kernel (as [L] does from
V4L2 controls): ~1000 lines of HEVC-specific programming stay out of the kernel, which keeps the
security boundary — addresses, buffer bounds, a register whitelist — small; it is the same split as
V3D (Mesa builds control lists, the kernel validates and relocates).

Zero-copy display of the SAND pictures on an overlay plane: §9 (V6, 2026-11-20; a GPU shader path is not done).

## 3. libavcodec: the `rpivid` hwaccel and `hevc_rpivid`

Files (ours, MIT, Haiku style; copied into `libavcodec/` by the ffmpeg6 build):
`patches/ffmpeg6/files/libavcodec/` — `rpivid_hevc.[ch]` (FFmpeg state → parameters, the hwaccel
callbacks, buffer pools), `rpivid_cmd.[ch]` (parameters → command entries and `CONFIG2`, no OS
dependency: host testable), `rpivid_device.[ch]` (the ioctls; on any OS but Haiku, "no device"),
`rpivid_sand.[ch]` (SAND → planar, NEON), `rpivid_haiku.h` (a copy of the uAPI
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
(`frame_priv_data_size`), from a pool keyed by the stream geometry: it lives as long as FFmpeg keeps
the frame as a reference (and, until it is converted, as long as the pending picture below needs it:
the buffers are reference counted). Pictures reach the caller as `yuv420p` (8-bit) or `yuv420p10le`
(10-bit) in the frames FFmpeg allocated: consumers see a software decoder.

**Pipelining.** `end_frame` of picture N submits N, then converts picture N-1 (the *pending* one: wait,
SAND → planar) while the block decodes N, and N becomes pending. By the time `end_frame(N)` runs,
`s->output_frame` already names the frame this `hevc_decode_frame` call returns (output happens at
frame start), so a frame never leaves the decoder unconverted: N-1 is converted here, N too when it is
the output (no reordering: low-delay streams get no CPU/block overlap, only the phase overlap of the
pictures queued). The other finish points: an empty packet (drain, a hook in `hevc_decode_frame`
before the last frames are output), the hwaccel's uninit (leaving the block, closing), and a
bitstream buffer about to be refilled (two alternate: the block reads one while the CPU fills the
other). A picture the block fails *after* its submit (bad data, a timeout) is found at its wait: its
frames get `AV_FRAME_FLAG_CORRUPT` (set by nothing else in hevcdec.c) and `rpivid_leave` drops them,
with the pictures up to the next IRAP. `FFMPEG_RPIVID_SYNC=1` waits and converts in each `end_frame`
(the first version's behaviour, for measurements).

**SAND → planar** (`rpivid_sand.c`): in bands of 16 rows, column by column within a band (each column
read in order, the band's output still in the cache); NEON for 8-bit (128-byte moves, `vld2` chroma
split) and 10-bit (`vst3` unpacks a word's three samples in order); row ranges, so the conversion is
split over the decoder's slice threads (`avctx->execute2`, idle while the block decodes;
`FFMPEG_RPIVID_CONVERT_THREADS=N` overrides the count). That cuts the wall time, not the CPU time.
The media kit plugin converts every frame again with swscale (`USE_SWS_FOR_COLOR_SPACE_CONVERSION`)
into `B_RGB32` (or `B_YCbCr422`): handing it NV12 would save only the chroma split; the copy stays
until a consumer reads SAND itself.

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
(the SAND conversion uses them) but not frame threads: frame threading would hand the (thread-unsafe) hwaccel state between thread
contexts on every picture ([FF] `pthread_frame.c`), for no gain since the block decodes one picture
at a time. The cost: a stream that `hevc_rpivid` decodes on the CPU (outside the block's limits)
runs without frame threads. Stage 3 removes it: the plugin asks after the first picture whether the
block took the stream and otherwise reopens the plain `hevc` decoder.

## 4. Media kit

(H.264, for comparison: `h264_mmal` is chosen by name in `AVCodecDecoder` with `h264` kept as its fallback, in place
— see `vchiq.md` §8.1. HEVC needs no such code: `hevc_rpivid` is found by `avcodec_find_decoder()` and falls back
inside libavcodec.)

Nothing to change for stage 2: `AVCodecDecoder::Setup` calls `avcodec_find_decoder`, which returns
`hevc_rpivid`; MediaPlayer gets `yuv420p` frames as from the CPU decoder. Stage 3: the reopen above,
a log line naming the decoder in use, and (later) handing SAND/NV12 frames to app_server's overlay
instead of converting to planar.

## 5. Build and packaging

- Driver: `scripts/build.sh rpivid`; in the image through `AddNewDriversToPackage video :
  rpivid@arm64` (`build/jam/packages/Haiku`).
- ffmpeg6: `scripts/build-ffmpeg.sh` (called by `scripts/build-packages.sh`): `scripts/cross-port.sh
  --patches patches/ffmpeg6` applies the hooks patch and copies `patches/ffmpeg6/files/` into the
  tree; package revision 3 (`ffmpeg6-6.1.6-3`: the pipelined hwaccel, driver interface 2; also in
  `build/jam/repositories/HaikuPorts/arm64`).
- Tests: `tools/media-tests/gen-hevc-clips.sh` (host ffmpeg + libx265; with the heavy streams about
  30 MB) and `tools/media-tests/build.sh` (`hevcdec`, `sandbench`, plus FFmpeg's libraries in
  `non-packaged/lib`, which come before the packages', and the driver in `non-packaged/add-ons`, which
  the module search takes before the packaged one — so an older image tests the new code) fill
  `artifacts/media-tests/hevc/non-packaged` for `mkimage-pi4.sh --add-tree`. Host tests:
  `tools/media-tests/host/host-test.sh`.

## 6. Stages and tests

| Stage | What | Exit criterion |
|---|---|---|
| 1 | driver probes, clocks the block, reads VERSION | `tools/pi-tests/rpivid.sh`: `RPV ident rpivid: version 0x202 ...` |
| 2 | one intra picture bit-exact | `hevcdec` on `intra.265` (x265 defaults, 1 I picture): `HEV frame 0 match ...` and `HEV result PASS` |
| 3 | inter pictures, MediaPlayer | `hevcdec` PASS on `ipb.265`, `weighted.265`, `main10.265`, `hd.mp4`; MediaPlayer plays `hd.mp4` (HDMI) with "rpivid: hardware HEVC decode" in its log |
| speed | the block clearly worth it | `hevcdec` PASS on `fhd`, `fhd10`, `uhd`, `uhd10` (every picture on the block) and its `bench`/`speed` lines: frames/s and CPU time per frame, block vs CPU decoder; the device report's phase overlaps > 0 |

Host tests (2026-10-20, x86 host, no Pi; FFmpeg built natively with the patch;
`tools/media-tests/host/host-test.sh` rebuilds and reruns all of it):
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
- faults injected in the mock (a refused picture, a picture failed in the block after its submit,
  the last one too, no memory for a picture): the stream continues on the CPU, every frame it emits
  equals the CPU decoder's, and the block is taken again at the next IRAP;
- the pipelined interface (version 2): the mock decodes a picture only when it is waited for (until
  then its output holds poison), checks that the bitstream of a queued picture does not change, that
  no buffer a queued picture names is deleted, and at most two pictures outstanding (with a limit of
  one the pipelined path trips it: two pictures are in flight); 25 x265 variants, the test clips and
  the heavy streams bit-exact, pipelined and synchronous, with identical command streams;
- `sandbench -check`: the SAND conversion (C, and NEON under qemu-aarch64) equals a direct reading of
  the layout for 11 sizes, both depths, whole, in bands and in row ranges.

## 7. Risks

- Contiguous memory: a 1080p picture is ~3.4 MB contiguous (4.4 MB in 10 bit), a 2160p one ~13 MB
  (~17 MB), and a stream needs DPB size + a few, plus two scratch sets (~16 MB each at 2160p). Late
  allocations can fail on a fragmented system: the hwaccel then falls back to the CPU (logged).
- The intermittent mismatch above (§1).
- Performance: see §8; the SAND → planar copy stays (a few ms per 1080p picture of memory traffic).
- FFmpeg 6.1.6's own HEVC decoder with slice threads is not deterministic on a 16x16-CTB WPP stream
  (about 1 run in 30 on the host, `hevc` as `hevc_rpivid` on the CPU): upstream's; it matters only
  for streams `hevc_rpivid` decodes on the CPU.

## 8. Speed

First Pi run (synchronous, 720p `hd.mp4`, light): 1.81 ms per picture on the block + 1.32 ms SAND →
planar = 3.76 ms per frame end to end, vs 1.57 ms for FFmpeg's CPU decoder with 4 frame threads — the
block did not pay off on a light clip. What changed:

1. **Phase overlap** in the driver (§2): the block's time per picture becomes max(phase 1, phase 2)
   instead of their sum.
2. **CPU/block overlap** in the hwaccel (§3): the CPU converts N-1 and parses N+1 while the block
   decodes N; the CPU waits only for what is not done yet ("the CPU waited" in the statistics line).
3. **Conversion**: NEON and slice threads (§3).
4. **Measurement** (`hevcdec`): per stream, `cpu` (hevc, 4 frame threads), `hw` (pipelined),
   `hw-1t` (one conversion thread), `hw-sync` (the first version): wall ms and frames/s, and the
   process's CPU time per frame (getrusage: every thread, user + kernel) — the block's real benefit is
   the CPU it leaves free. The decode thread's few register writes per phase are the kernel's, not
   counted. `sandbench` measures the conversion variants alone.

## 9. Zero copy: the display scans out the decoder's pictures (V6, 2026-11-20; haiku-pi/haiku `v6-video`, ffmpeg6 6.1.6-8 test)

Before: every HEVC picture went SAND → planar on the CPU (`rpivid_sand.c`), then the plugin copied the planes into
MediaPlayer's buffer and MediaPlayer copied them into its overlay bitmap (video-overlay.md §1): three passes over
3 MB at 1080p.

### 9.1 The plane takes SAND, in one layout (probe, session `v6p1`, **measured**)

gpu-stage6 §5's probe (never run before): `sandprobe layout 1|2|3` on plane 6 with `overlay_above_desktop`, HDMI
frames graded by eye and `colour-probe.py`:
- **L1, DRM's NV12_COL128** (one column height C = H16 × 3/2, the chroma rows after the luma rows in each column,
  `pitch` = C): the bars right (`artifacts/v6-video/probe1/layout-1.png`).
- L2 (our decoder's layout: luma columns of H16 rows, chroma columns of H16/2 rows in a plane of their own) and L3
  (the same with `vpitch` = H16/2): wrong colours in the right half — the firmware takes one column stride for both
  planes, whatever `vpitch` says.

So the decoder writes NV12_COL128 for pictures that go to the display (Phoenix's M10b §4.1 made the same change).

### 9.2 Design

| Piece | Change |
|---|---|
| rpivid driver (2c6cace0e0) | `RPIVID_PICTURE_SCAN_OUT`: the picture below 1 GiB (the display keeps 30 address bits), NV12_COL128 (both column strides C × 128, chroma at H16 × 128), its client mapping `B_CLONEABLE_AREA`; pictures of the two layouts are not mixed in one decode (`same_geometry`). Additive: API version stays 2, an older driver refuses the flag (B_BAD_VALUE) and the hwaccel falls back to ordinary pictures; the -7 hwaccel never asks |
| libavcodec (ffmpeg6 -8: `patches/ffmpeg6-next`) | option `rpivid_out` (`planar` default, `sand`): scan-out pictures, each frame's picture in `opaque_ref` (`RpividSandFrame`, `rpivid_hevc.h`: area, offset, size, coded size, depth, column height, chroma offset), holding the picture buffer while the frame lives; the SAND → planar conversion is skipped while the option is `sand` (`planar` in the descriptor says whether it ran); the caller may switch back at any time. `FFMPEG_RPIVID_SCAN_OUT=1`: the scan-out layout with conversion (a test). The CPU decoder's frames (pictures the block did not take) have no picture |
| media kit plugin (a592852e59) | a caller asking for `B_YUV420_SAND128` gets, from hevc_rpivid, an `overlay_video_frame` per frame (headers/private/media/OverlayVideoFrame.h: area, offset, size, bytes_per_row = C, space) instead of pixels, and the plugin holds the last 8 frames (`B_OVERLAY_VIDEO_FRAME_HOLD`); 10-bit → `B_YUV420_SAND128_10`; output switched to another space: the decoder converts again, the frames it kept are de-tiled by the plugin |
| interface kit, app_server (cdd1c52acb, 1ff1913b4c) | public color spaces `B_YUV420_SAND128` (0x4028) and `_10` (0x4029), overlays only, bytes_per_row = the column height. `BBitmap(area, offset, bounds, B_BITMAP_WILL_OVERLAY, space, bpr)`: app_server clones the area (read-only) and asks the accelerant to **import** it as the overlay buffer (new optional hook `B_IMPORT_OVERLAY_BUFFER`); refused → no bitmap. Mode changes release and re-import. A server bitmap now releases its overlay before its memory |
| bcm2711_display (c6ad488cd8) | `IMPORT_OVERLAY_BUFFER`: an area of the caller (app_server's clone), contiguous below 1 GiB, kept by a kernel clone until freed; SAND buffers shown as image type 19 (8 bit) / 59 YUV10COL (10 bit), `pitch` = C, `planes[1]` = chroma |
| MediaPlayer (c564022db6) | asks for `B_YUV420_SAND128` when the screen has such overlays (else B_YUV420 as before; the plugin answers B_YUV420 for h264_mmal); the consumer makes one overlay bitmap per picture (≤ 24, LRU, never the shown one or the one it replaced) and flips between them: no copy. `MEDIAPLAYER_SAND=0` turns it off |

Host (2026-11-20 08:01–08:08, x86, ASan, the register-level mock, `HOST_NEXT=1`): `host-test.sh` **PASS** in both
layouts — 34 clips/variants BIT-EXACT each, the fault injections as before — with the ordinary pictures and with
`FFMPEG_RPIVID_SCAN_OUT=1` (NV12_COL128 pictures converted): the hwaccel's planar output is unchanged and the new
layout is read back exactly.

### 9.3 Pi results (sessions `v6s1` 08:52–09:13 and `v6s2` 09:16–09:27, image `v6-base` = rpi4 6a20a50380 + the branch's driver, rpivid, accelerant, app_server, libbe, plugin and MediaPlayer from non-packaged, ffmpeg6 -8 + raspberrypi_userland -4 installed; **measured**)

MediaPlayer, 20 s from 5 s after the start, `teamstat` (the team, and the whole system as a second tool); shown = the
plane's updates in the driver's statistics; the decoder's own counters at the end.

| Clip | B_YUV420 (`MEDIAPLAYER_SAND=0`, same session) | **SAND, zero copy** |
|---|---|---|
| HEVC 1080p30 (8 bit) | 23.0 % (system 6.8 % of 4 CPUs), all shown, 0 dropped | **4.4–6.5 %** (system 2.1–3.1 %), all shown (image type 19), 0 dropped; 745 of 745 pictures handed out as they are, 15 pictures |
| HEVC Main 10 1080p30 | 44.4 % (system 12.1 %) | **5.0–6.0 %** (system 2.4–2.8 %), all shown (image type 59, YUV10COL), 0 dropped |
| HEVC 720p30 | 12.2 % (system 4.0 %) | **3.0–4.1 %** (system 1.7–2.2 %), all shown, 0 dropped |
| HEVC 2160p30 (40 MB clip, 16 Mbit/s) | 77.7 %, B_YUV420 overlay refused (no memory), B_RGB32, 370 dropped | not possible: 15 4K scan-out pictures (190 MB) are not to be had below 1 GiB → `no room for 15 pictures`, ordinary pictures, the same B_RGB32 path: 78.6 %, 358 dropped (no regression; 4K is not playable either way) |

- Branch binaries with ffmpeg6 **-7** (no `rpivid_out`): HEVC 1080p30 as B_YUV420, 23.1 %, 0 dropped — the -7/-8
  boundary is clean. (The first build asked the plugin for SAND and got B_RGB32 at 46 %: fixed before the numbers above.)
- **The block writes NV12_COL128 bit-exactly**: `ffmpeg -f framemd5` of 90 frames with `FFMPEG_RPIVID_SCAN_OUT=1`
  equals the CPU decoder's for `play-hevc-1080p30` (8 bit) and `play-hevc10-1080p30` (10 bit), as does the ordinary layout.
- Colours on the SAND plane (video-overlay.md §7 clips): HEVC BT.709 1080p **3**, BT.601 720p **0**, Main 10 BT.709 **3**
  off the RGB path (max per channel).
- overlaytest `-s sand` and `-s sand10` at 1920×1080 (app_server-allocated SAND buffers): bars right, keyed window,
  moved off-screen: PASS; sand10 bars read within the capture's error.
- Fresh boot, 6 plays in a row (10-bit, 8-bit, 720p, twice): SAND every time, 15 pictures each.
- **Mode change** while SAND plays (1280×720 and back): the picture on the plane before, during and after
  (`artifacts/v6-video/s2/mode-3.png`), 0 problems.
- **No plane** (six overlaytests hold all planes): SAND refused → B_YUV420 refused → B_RGB32, the plugin switches the
  decoder back to converting, 0 dropped.
- **Seek** (`h264.sh seek` with the HEVC clip and the new MediaPlayer): pause holds, seek forward/back land right, 6 quick
  seeks, 0 problems; an HDMI recording around the seeks (64 frames sampled at 4/s) shows no broken picture.
- **kill -9** during SAND play, six times: no imported overlay buffer or rpivid picture left, 0 debugger entries, SAND
  engages afterwards (8 and 10 bit).
- Regression on -8: `h264.sh play/seek/web` 0 problems (stock MediaPlayer, the new plugin); VP9 and MPEG-4 clips play
  as B_YUV420 with the right colours; the new plugin costs the same as the old on H.264 1080p30 (26.2 / 26.6 %).
- 0 debugger entries, 0 PANIC in both sessions.

### 9.4 Limits and what is left

- **Low memory**: a stream gets scan-out pictures only if all it may hold (DPB + 8 held + 2) can be had below 1 GiB up
  front (`pool_reserve`); otherwise it is the B_YUV420 path from its start. Late in a session that had run 4K (v6s1),
  even 1080p 8- and 10-bit fell back this way (`vm_page_allocate_page_run` could not find 3.2 MB runs): no freeze, but
  no saving either. A reserved region in the rpivid driver (as the display driver reserves its overlay buffers at boot)
  would remove that; not done.
- Before the up-front reserve, a 4K stream got 3 scan-out pictures, fell back to the CPU path and the plugin repeated
  its last frame (a frozen picture): the reserve fixed that, and the plugin still repeats the last picture if a stream
  falls back to the CPU *later* (a later PPS the block refuses, a picture the block fails) — then the video stands until
  the next random access point.
- The decoder holds the last 8 frames it handed out; a seek decodes frames nobody shows, so the picture on the screen
  can be reused before it is replaced. Not seen in the seek test; a consumer-side release would be exact.
- 4K: no plane either way (memory); `ffmpeg -c:v h264_mmal` frame rate: see video-overlay.md §7.5.
- Firefox and other media-kit clients are not affected: SAND is only given to a caller that asks for
  `B_YUV420_SAND128`.

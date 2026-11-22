# VideoCore services beyond H.264 decoding (owner 2026-11-18, item 4)

Status: **done (2026-11-19)**; image-2026-11-21 ships ffmpeg6 6.1.6-7 + raspberrypi_userland 20241223-4 (one VideoCore H.264
stream system-wide, the decoder abort at Firefox quit fixed; [firefox-video-overlay.md](firefox-video-overlay.md) §9.6); V8 (§7, rate rule) released in image-2026-11-21b. (a) works on the Pi, (b) measured and decided (no VideoCore JPEG; a CPU-side
translator fix instead), (c) works (ffmpeg, media kit), (d) no camera on the bench Pi: design only. Builds on VCHIQ + MMAL ([vchiq.md](vchiq.md) §6–§8: `/dev/vchiq`, Broadcom's
libmmal in `raspberrypi_userland`, `h264_mmal` in the media kit) and on the YUV overlay work
([video-overlay.md](video-overlay.md), branch `v1-overlay`). In priority order:

| | What | State |
|---|---|---|
| a | H.264 on the VideoCore in **Firefox** | **works**, no Firefox rebuild: `h264_vc` (ffmpeg6 patch 0003). Firefox's decode process 1080p30: 123 % → 58 % of a core; frames dropped unchanged (Firefox's drawing, G2) — §1 |
| b | **JPEG** on the VideoCore for Haiku's translators | **not worth it**: the VideoCore decodes and encodes slower than one A72 core with libjpeg-turbo, no progressive; instead the translator's own overhead cut (1080p 94 → 63 ms) — §2 |
| c | **H.264 encode** | **works**: `h264_mmal` encoder (ffmpeg6 patch 0004), 1080p 50 fps, quality on par with x264 `veryfast`; ffmpeg and the media kit (MediaConverter) — §3. ffmpeg6 -6: option `initial_qp` (first-frame quantiser, default 25; the VideoCore's own banded a flat key frame) and pts in µs as MMAL defines them (blender.md §7.13) |
| d | **Camera** (CSI) | **no camera attached** to the bench Pi (`start_x` firmware: `supported=1 detected=0`); design — §4 |

Numbers are **measured** (with the session) unless marked **estimated**.

§8 (VQ1, 2026-11-22): the kernel PANIC "Failed to unwire page" in `VCHIQ-0` after MediaPlayer starts an H.264 decode
is a kernel VM bug (a cut out of the middle of the heap area unmapped the wired bulk buffer above it); fixed in rpi4
eaeb21e6e6 (branch `vq1-vchiq-unwire`).

## 1. (a) H.264 in Firefox without rebuilding Firefox

### 1.1 How Firefox picks its H.264 decoder

Firefox decodes H.264 with the system's FFmpeg (its FFmpeg platform decoder module dlopens `libavcodec.so.60`).
Its hardware paths (VA-API, V4L2-M2M, Vulkan) are compiled only for GTK (`MOZ_WIDGET_GTK`); the Haiku build
(native toolkit) has the software path only. That path does **not** call `avcodec_find_decoder()`:
`FFmpegDataDecoder::FindSoftwareAVCodec()` (firefox-157.0.1 `dom/media/platforms/ffmpeg/FFmpegDataDecoder.cpp`)
walks `av_codec_iterate()` and takes the **first decoder for the codec id that is neither
`AV_CODEC_CAP_HARDWARE` nor experimental** (`libopenh264` only with a pref). `h264_mmal` is hardware (and listed
after `h264`), so Firefox never takes it; a Firefox patch would need a rebuild (hours; the build tree was deleted).

### 1.2 `h264_vc`: a decoder Firefox takes, with the fallback inside

ffmpeg6 patch `0003-h264-vc.patch` + `files/libavcodec/h264_vcdec.c`: a third H.264 decoder, **`h264_vc`**:

- Listed **before `h264`** in `allcodecs.c` and without `AV_CODEC_CAP_HARDWARE` (its frames are ordinary `yuv420p`
  in system memory), so Firefox's walk takes it.
- **`avcodec_find_decoder()` skips it** (`find_codec()` in `allcodecs.c`): every other FFmpeg user keeps `h264`
  as the default — the media kit plugin (which prefers `h264_mmal` and falls back by itself, vchiq.md §8.1), the
  `ffmpeg` command line, libavformat's probing (which asks for `"h264"` by name anyway). `-c:v h264_vc` picks it
  by name.
- It opens `h264_mmal` in an inner codec context (as FFmpeg's `imm5` nests `h264`) **with the first packet**, not
  in `avcodec_open2()`: Firefox opened 5 decoder instances for one clip in QEMU (§1.4), and the VideoCore's memory
  holds one 1080p decoder (vchiq.md §8.3) — an instance that never decodes must not take it. It moves the stream to the
  software `h264` (another inner context, with the caller's thread settings) when `h264_mmal` **does not open**
  (no `/dev/vchiq`, the VideoCore's memory taken by another decoder) or **fails later** (any error but EAGAIN/EOF,
  e.g. mmaldec's "2 s without a frame it owed"): **from the start** while `h264_mmal` has output no frame (the
  packets it was given are kept, at most 300, and given again), else **from the next key frame** — the media kit
  plugin's policy (vchiq.md §8.1), now inside libavcodec, so a caller without its own fallback (Firefox) gets it.
- Straight to `h264` when the VideoCore would not do: `FFMPEG_H264_MMAL=0` in the environment (the same switch
  as the media plugin's), **low-delay decoding** (`AV_CODEC_FLAG_LOW_DELAY`, WebRTC: h264_mmal holds 8 packets),
  pictures over 1920×1088, and High 10 / 4:2:2 / 4:4:4 profiles (from the avcC record or the SPS).
- What h264_mmal's frames lack, filled in from the packets (found again by pts): `pkt_dts`, the duration, the key
  frame flag. The caller's codec context mirrors the inner decoder's (`pix_fmt`, size, colour properties) — not
  mmaldec's frame rate (always the 24000/1001 it told the VideoCore, video-overlay.md §0.8).
- Capabilities: `AV_CODEC_CAP_DELAY | AV_CODEC_CAP_AVOID_PROBING`; internal `FF_CODEC_CAP_AUTO_THREADS` (else
  `avcodec_open2()` forces `thread_count = 1` before the inner software decoder sees it); **not**
  `FF_CODEC_CAP_NOT_INIT_THREADSAFE` (the inner open of `h264_mmal` takes that global lock itself; holding it
  around the nested open would deadlock).

### 1.3 Host verification (no Pi): the fallback logic, bit-exact

`h264_vcdec.c` compiled on the host against a host build of FFmpeg 6.1.6 (static, h264 only), with a stand-in
`h264_mmal` (the software decoder in a nested context, with h264_mmal's habits: frames only after 8 packets, no
`pkt_dts`/duration/key flag; `FAKE_OPEN_FAIL=1` / `FAKE_FAIL_AT=N`: open fails / an error from the Nth packet on)
and a test program that decodes as Firefox does (send one packet, receive until EAGAIN; drain at the end; a seek
+ `avcodec_flush_buffers()` after 50 frames). Every frame's MD5, pts, duration and key flag against `h264` alone
(720p and 1080p clips, 300 frames, 3 B-frames):

| Case | Result |
|---|---|
| h264_mmal works | 300/300 frames bit-identical, durations and key flags = h264's |
| does not open | `h264_mmal does not open (No space left on device): h264 decodes`; 300/300 identical |
| fails at packet 3 or 5 (no frame out yet) | `h264 continues from the start`: 300/300 identical, none twice |
| fails at packet 9, 12, 100, 295, 300 | `h264 continues at the next key frame`: every frame output identical, in order, none twice; the frames between the failure and the next key frame are lost |
| seek after 50 frames, then fails 5 packets later | replayed from the seek point: 50 + 300 frames, identical |
| `FFMPEG_H264_MMAL=0` | software from the start, identical |

(The first version replayed the recorded packets while still recording them — every packet went twice; found by
this harness, fixed before any Pi run.) Harness: `tools/media-tests/h264vc-host/` (§6).

### 1.4 QEMU: Firefox takes it (no VideoCore there)

QEMU virt, 2026-11-18 21:32 (release image 2026-11-18 + the test libavcodec in `/boot/home/vc/lib`, first in
`LIBRARY_PATH`; a UserBootscript plays `play-720p30.mp4` in Firefox 157 with `MOZ_LOG=FFmpegVideo:4`; serial log
`artifacts/qemu/20261118-213212-virt.log`): **`FFMPEG: Using preferred software codec h264_vc`** (5 decoder
instances); without `/dev/vchiq` h264_mmal does not open and h264_vc decodes in software: the 60-s clip played to
the end (1800 frames, 333 dropped by QEMU's slow CPU, all in the first 30 s), no debugger entry. (Firefox also
takes `hevc_rpivid` for HEVC: the HEVC block decoder is a software decoder to FFmpeg's users, hw-video-decode.md.)

### 1.5 On the Pi (session v4b, 2026-11-19 03:21, image-2026-11-19 + the test libavcodec first in `LIBRARY_PATH`)

`vc-services.sh firefox`: Firefox 157 plays the clip looped and muted in a 1280×720 `<video>`; CPU of every
Firefox team over 15 s from 15 s after the start (`teamstat`); `getVideoPlaybackQuality()` every 5 s.

| Clip | decoder | decode process (`-contentproc`, the one with the FFmpeg decoder) | main process | system (4 CPUs) | dropped / frames at 25 s |
|---|---|---|---|---|---|
| play-720p30 (4 Mbit/s) | **h264_vc → VideoCore** | **29.9 %** of one core | 211 % | 78.7 % | 56 / 408 (at 15 s) |
| | `FFMPEG_H264_MMAL=0` (h264, CPU) | 55.0 % | 204 % | 75.2 % | 80 / 731 |
| play-1080p30 (8 Mbit/s) | **h264_vc → VideoCore** | **57.6 %** | 197 % | 82.1 % | 304 / 719 |
| | `FFMPEG_H264_MMAL=0` | 122.5 % | 179 % | 86.5 % | 284 / 732 |

- **The VideoCore decodes Firefox's H.264**: `MOZ_LOG=FFmpegVideo:4` → `Using preferred software codec h264_vc`
  (5 decoder instances per clip); `/dev/vchiq` shows the `mmal` service open and the H.264 clock held at 500 MHz
  while the video plays, released when Firefox quits; 0 debugger entries over five Firefox runs.
- **Saved: 0.25 core at 720p, 0.65 core at 1080p** in the decode process (what is left there: mmaldec's copy out of
  the VideoCore's buffer and Firefox's copy into its image).
- **Not saved: dropped frames.** Firefox's main process takes ~2 cores either way — drawing the video in software
  (KNOWN-ISSUES G2) — and drops ~40 % of the 1080p frames with the hardware decoder as with the software one; the
  system is 80–87 % busy in all four runs. The decoder was not Firefox's bottleneck; its compositor is.
- The fallback (§1.2) was not needed on the Pi; it was exercised on the host (§1.3) and in QEMU (§1.4).

## 2. (b) JPEG on the VideoCore

### 2.1 What the firmware offers (`mmal-codec probe`, session v4a, 2026-11-18 23:31, standard `start4.elf`)

| Component | Input | Output |
|---|---|---|
| `vc.ril.image_decode` | GIF BMP JPEG PNG PPM TGA | RGB2 (RGB565) I420 I422 RGBA BGRA |
| `vc.ril.image_encode` | RGB2 RGB3 BGR3 RGBA BGRA I420 I422 YUYV YVYU VYUY UYVY OPQV | GIF BMP JPEG PNG PPM TGA |
| `vc.ril.video_encode` | I420 YV12 NV12 NV21 RGB2 RGB3 BGR3 RGBA BGRA YUYV … SAND I422 OPQV | **H264 MJPG** |
| `vc.ril.video_decode` | H264 MVC MJPG (no MPEG-2/VC-1 licence on this board) | I420 YV12 NV12 NV21 SAND RGB2 RGBA BGRA OPQV |
| `vc.ril.isp` | Bayer (8–16 bit), YUV, RGB, SAND | YUV/RGB (two outputs) + statistics |
| `vc.ril.resize` | RGBA BGRA RGB2 I420 | RGBA BGRA RGB2 I420 |
| `vc.ril.camera` | — | not created: `ENOMEM` (no camera stack in `start4.elf`, §4) |

### 2.2 Decoding: the VideoCore is slower than one Cortex-A72 core (**measured**, v4a)

5 decodes each, the file in memory; VideoCore = `mmal-codec jpegdec` (I420 out, bulk-copied into the team, the
component reused); CPU = `jpegtime` (libjpeg-turbo 3.1.4.1, one thread):

| Picture | VideoCore → I420 | libjpeg-turbo → raw YCbCr | libjpeg-turbo → BGRX (B_RGB32) | JPEG translator (`GetBitmapFile`) | translator, `v4-vc` |
|---|---|---|---|---|---|
| 640×480 4:2:0 | 19.1 ms | 4.5 ms | 5.6 ms | – | – |
| 1920×1080 4:2:0 | 53.4 ms (first 56.9) | 30.3 ms | 39.8 ms | 94.0 ms | **62.9 ms** |
| 4032×3024 4:2:0 (12 MP) | 248 ms (first 298) | 177 ms | 231 ms | 374.6 ms | **335.7 ms** |
| 4032×3024 4:2:2 | 287 ms | 215 ms | 263 ms | | |
| 4032×3024 4:4:4 | 334 ms (output I420: chroma halved) | 297 ms | 324 ms | | |
| 4032×3024 progressive | **fails** (`ECORRUPT` error event) | 450 ms | 502 ms | 633.7 ms | 600.4 ms |

- The VideoCore takes 4–6 % of the system's CPU for a decode (the bulk copy is the VideoCore's DMA) where
  libjpeg-turbo takes one core for the whole time — but it is 1.3–4× *slower* in wall time, does no progressive
  JPEG (common on the web), and returns 4:4:4 as 4:2:0. Its output equals libjpeg-turbo's (I420 against the host's
  decode: **63.5 dB**, IDCT rounding).
- `BGRA` output from `image_decode` (which would save the colour conversion) failed (`ECORRUPT`) on all three
  pictures tried; not pursued, since the decode alone is already slower than the CPU's decode + conversion.
- **Decision: no VideoCore path in the JPEG translator.** A photo viewer gains nothing in time; the CPU saving
  (one core for 0.2–0.3 s per 12-MP photo) does not pay for a second code path that must fall back for progressive
  and 4:4:4 files.
- **Found instead**: the translator's own cost on top of libjpeg-turbo (94 vs 40 ms at 1080p): it decoded to RGB and
  widened each row to B_RGB32 with a per-pixel C loop. Haiku `v4-vc` fb3f53a8f0 asks libjpeg-turbo for
  `JCS_EXT_BGRA` (its SIMD colour conversion writes B_RGB32 directly) when no EXIF rotation is to be applied:
  **1080p 94.0 → 62.9 ms (−33 %), 12 MP 374.6 → 335.7 ms (−10 %), progressive 633.7 → 600.4 ms; pixels identical**
  (FNV-1a of the bitmap's bits, same three hashes). The rest (BBitmapStream, row-by-row `Write()`s) is left.

### 2.3 Encoding

Same I420 input on both (v4a/v4b):

| Picture | VideoCore `image_encode`, "quality 85" | libjpeg-turbo, quality 85 (raw 4:2:0 in) |
|---|---|---|
| 1920×1080 `testsrc2` | 38.4 ms, 235 KB | **19.1 ms**, 96 KB |
| 4032×3024 photo (noise) | 198 ms, 11.1 MB | **180 ms**, 3.6 MB |

The VideoCore's "quality 85" is a much finer quantisation (61 dB against its source, 3× the size), but even so it is
not faster than one core. No VideoCore path for JPEG encoding either.

## 3. (c) H.264 encoding

FFmpeg 6.1 has no MMAL encoder (`mmaldec.c` only; the Pi's encoder is reached upstream through V4L2-M2M,
`h264_v4l2m2m`, i.e. Linux's GPL `bcm2835-codec`), and our ffmpeg6 build has no H.264 encoder at all (no
libx264). Patch `0004-h264-mmal-encoder.patch` + `files/libavcodec/mmalenc.c` (~400 lines): an `h264_mmal`
encoder on `vc.ril.video_encode`.

### 3.1 Results (**measured**, v4a; 300 frames of `testsrc2` + temporal noise, looped from 30)

| | 1280×720, 4 Mbit/s | 1920×1080, 8 Mbit/s |
|---|---|---|
| `mmal-codec h264enc` (component alone, 1 input buffer) | **107 fps** (9.3 ms/frame), 11.6 % of the system's CPU | **50 fps** (20.0 ms/frame), 10.1 % |
| `ffmpeg -f rawvideo … -c:v h264_mmal` | 300 frames in 3 s (123 fps reported), 300 packets | 300 frames in 6 s |
| stream | High, level 4.0, I every 60, 4002 kbit/s | High 4.0, 8002 kbit/s; Baseline 8005 kbit/s at the same speed |
| MP4 (ffmpeg) | `h264,High,1280x720,30/1,3999 kbit/s,300 frames` | `…1920x1080,…7998 kbit/s,300 frames` |

- Real time with room: 1080p30 needs 30 fps of the VideoCore's 50; the ARM's work is the copy of each frame into
  the VideoCore's buffer (~10 % of the system).
- **Quality on par with x264 `veryfast`** at the same bit rate (PSNR Y against the source, host, frame by frame):
  noisy 720p 4 Mbit/s 32.8 dB (x264 32.4), noise-free 720p 4 Mbit/s 45.2 dB (x264 47.0); noisy 1080p 8 Mbit/s
  32.9 dB (Baseline 32.6). (A first comparison read the raw `.h264` at ffmpeg's default 25 fps against the 30-fps
  source and showed ~25 dB: a measurement error, not the encoder.)
- **Not at the same time as a 1080p decode with the default `gpu_mem=76`**: with MediaPlayer playing 1080p H.264 on
  the VideoCore (`get_mem reloc` 2 MB free), the encoder's input port does not enable (`ENOMEM`), and `ffmpeg -c:v
  h264_vc -i 1080p.mp4 -c:v h264_mmal` (a hardware transcode) fails the same way. **With `gpu_mem=128`** (session
  v4c): `reloc` 99 MB free, and the 1080p transcode runs: 600 frames (20 s) in 17 s, 36–37 fps, **1.2× real time**,
  627 frames decoded / 600 encoded, 6.0 Mbit/s High. Raising `gpu_mem` costs the ARM 52 MB; not changed (a
  setting for whoever transcodes).
- **Media kit**: Haiku `v4-vc` 6bcab9eb40 lists "H.264 video" in the ffmpeg plugin's encoder table
  (`get_next_encoder()` for MP4 then offers mpeg4, **h264**, theora, mjpeg). The first run (`venc`, BMediaFile as
  MediaConverter) stopped after 76 (720p) / 117 (1080p) frames with `B_ERROR` from `WriteFrames`; two causes found:
  1. mmalenc could return EAGAIN while the caller's frame was still waiting, when an input buffer came back between
     two checks (fixed: EAGAIN only once the caller's frame is taken; the run after the fix got further: 100 / 174
     frames);
  2. the plugin times every packet from one `WriteFrames()` call with the frame count, right only for encoders
     that give exactly one packet per frame at once; h264_mmal gives two or none at times → the same time twice →
     the muxer refuses (non-monotonic DTS). Fixed in `v4-vc` fc81a8ccee (the packet's own pts).
  **After both fixes (v4b): 300 frames → MP4, H.264 High, 720p 43.0 fps, 1080p 19.4 fps** (MPEG-4, FFmpeg's
  software encoder, same path: 26.2 / 11.9 fps). `venc` is CPU-bound in both (one core: it draws each test frame
  and the plugin converts RGB32 → yuv420p with swscale's C path), not by the VideoCore (50 fps at 1080p alone).
  299 packets for 300 frames: the plugin never drains the encoder at the end (its own TODO), so the frames still
  in flight are lost — one with h264_mmal; a follow-up for the plugin (send NULL at `Flush`/close).

## 4. (d) Camera

### 4.1 Two camera stacks on the Pi 4

| | Firmware ("legacy") camera | libcamera |
|---|---|---|
| Who drives the sensor | the VideoCore firmware: sensor over its own I2C, CSI-2 receiver (Unicam), ISP, AWB/AE/AGC, all inside the firmware | the ARM: Unicam CSI-2 driver, a sensor driver per sensor, the ISP through VCHIQ (`bcm2835-isp`), control algorithms (libcamera's IPA) in userland |
| ARM side for us | MMAL `vc.ril.camera` over our VCHIQ + libmmal — **what exists already** | a CSI-2 receiver driver, I2C sensor drivers, an ISP client, libcamera itself (C++, Linux media-controller APIs): weeks |
| Sensors | OV5647 (Camera Module 1), IMX219 (v2), IMX477 (HQ) — the firmware's tuning | also IMX708 (Camera Module 3), IMX296 (Global Shutter), third-party |
| Firmware | **`start_x=1`**: `start4x.elf`/`fixup4x.dat` instead of `start4.elf` (the camera code is not in the standard firmware), **`gpu_mem` ≥ 128** (we run 76 MB) | standard firmware |
| Licences | firmware blob + Broadcom's BSD-3 MMAL | libcamera LGPL-2.1/BSD; Linux's Unicam/sensor drivers GPL (behaviour reference only, H21's rule) |

Raspberry Pi OS dropped the legacy stack in 2021 (Bullseye) and on 64-bit userland altogether (its MMAL is
32-bit only) — the firmware side still ships in `start4x.elf` (pinned commit `6c87074…`: 355 camera/sensor strings,
e.g. the tuning for ov5647/imx219/imx477). Our 64-bit libmmal already speaks the VideoCore's 32-bit message
layout (vchiq.md §7.2 patch 5), so the legacy camera is reachable from Haiku with no new driver.

### 4.2 Is a camera attached?

**No.** With the standard firmware (v4a): `get_camera` → `supported=0 detected=0`, `vc.camera_info` → 0 cameras,
`vc.ril.camera` not created (`ENOMEM`) — that firmware does not look for one. With a session image carrying the
camera firmware (v4c, 2026-11-19 03:28: `start4x.elf`/`fixup4x.dat` from the pinned commit, `start_x=1`,
`gpu_mem=128`; firmware version string 14:15:48 instead of 14:15:04): `get_camera` → **`supported=1 detected=0`**,
camera_info 0 cameras, `vc.ril.camera` still `ENOMEM`. The firmware looked and found no sensor on the CSI
connector. Per the owner's instruction, (d) stops at this design; `mmal-codec camera` (§4.3 step 2) is written and
compiled, never run.

### 4.3 Design (firmware camera, MMAL)

1. **Boot files, opt-in**: `start4x.elf` + `fixup4x.dat` (same pinned commit as the rest,
   `scripts/fetch-pi-firmware.sh`) on the FAT partition and `start_x=1` + `gpu_mem=128` in `config.txt`, only on
   request (a `mkimage-pi4.sh --camera` switch): it takes 52 MB more from the ARM, and the camera firmware is
   larger and boots ~0.1 s slower (**estimated**). Check: `get_camera` → `supported=1 detected=1`,
   `mmal-codec probe` → `camera_info: 1 cameras, <sensor>, <max size>`.
2. **Capture test** (`mmal-codec camera`, to write): `vc.ril.camera` (camera number from camera_info), output 1
   (video) I420 1280×720 at 30 fps, frames by bulk transfer as with the decoder (1.4 MB per 720p frame: ~40 MB/s,
   ~1 % of the system's CPU at the measured copy cost of vchiq.md §7.4); one frame written for a look on the
   host; port 2 (still) JPEG through the VideoCore's encoder (`vc.ril.camera` → `vc.ril.image_encode` tunnel,
   `mmal_connection`) for photos without ARM work.
3. **Recording without the ARM**: `vc.ril.camera` → `vc.ril.video_encode` tunnelled inside the VideoCore
   (`mmal_connection_create` with `MMAL_CONNECTION_FLAG_TUNNELLING`): only the H.264 stream crosses VCHIQ
   (~1 MB/s at 8 Mbit/s).
4. **Media kit**: a video producer add-on (`src/add-ons/media/media-add-ons/vc_camera`, the shape of the
   `usb_webcam` add-on's producer) that outputs **B_YUV420** buffers — which MediaPlayer's consumer and
   CodyCam-style apps can now show on the YUV overlay plane (video-overlay.md) — and B_RGB32 through the
   plugin's conversion otherwise.
5. Effort (**estimated**): steps 1–2 a day; 3 half a day; 4 two to three days (media node, format negotiation,
   start/stop, a camera that is absent).

## 5. Merging (for the main session)

- **ffmpeg6 revision 5** (`scripts/build-ffmpeg.sh` already says 5): patches 0003 (`h264_vc`) and 0004 (`h264_mmal`
  encoder) + their files. Effects: Firefox decodes H.264 on the VideoCore (and falls back by itself); `ffmpeg -c:v
  h264_mmal` encodes; nothing else changes (`avcodec_find_decoder(H264)` is still `h264`). The package then provides
  an H.264 encoder (the image had none). Tested from a private build (`LIBRARY_PATH`), not as a package.
- **Haiku `v4-vc-rpi4`** (the three commits cherry-picked onto rpi4 6ebce0574f, clean, compiled; `v4-vc` is the
  same on `v1-overlay`): ea305c7a9c (v4-vc fb3f53a8f0) JPEG translator BGRA (−33 % at 1080p, same pixels), 49ddfe1e9e "H.264 video" in
  the encoder table, 7e6832e359 encoded packets timed by their pts (needed by h264_mmal in the media kit; harmless
  for one-packet-per-frame encoders: mpeg4 ran through it unchanged). The encoder-table entry only makes sense with
  ffmpeg6 revision 5 (without an H.264 encoder MediaConverter would list one that fails to open).
- KNOWN-ISSUES P2: "Firefox does not use it" → Firefox decodes H.264 on the VideoCore (its decode process 1080p30
  123 % → 58 % of a core), its frame drops (G2) unchanged; `ffmpeg` gains `-c:v h264_mmal` (encode, 1080p 50 fps).
- Not to merge: nothing for the camera (no hardware); no VideoCore JPEG path.

## 6. Files

Binaries of the tested builds and raw session output (not in git): `artifacts/v4-vc/` (libavcodec.so.60 of ffmpeg6
+ patches 0001–0004, the ffmpeg media plugin and JPEGTranslator of `v4-vc`, mmal-codec, jpegtime, venc;
`results/`: probe, jpeg, encode, venc, firefox lines of sessions v4a/v4b/v4c). Serial logs:
`artifacts/uart/*-session-v4{a,b,c}.log`.

- ffmpeg6: `patches/ffmpeg6/0003-h264-vc.patch` + `files/libavcodec/h264_vcdec.c`;
  `patches/ffmpeg6/0004-h264-mmal-encoder.patch` + `files/libavcodec/mmalenc.c`.
- Tests: `tools/haiku-tests/mmal-codec.c` (probe, jpegdec, jpegenc, h264enc), `tools/haiku-tests/jpegtime.cpp`,
  `tools/pi-tests/vc-services.sh` (phases probe, jpeg, jpegenc, h264enc, ffenc, firefox),
  `tools/media-tests/h264vc-host/` (the host harness of §1.3).

## 7. (V8) H.264: the decoder chosen by the stream's rate (2026-11-20)

Haiku branch **`v8-h264-rate`** (haiku-pi, off rpi4 552c42233d; squashed and merged as 289a46c68b, **released in image-2026-11-21b**): a5011fe1cc `ffmpeg: keep H.264 on
the CPU when the VideoCore cannot keep up`, 0807f116bb `ffmpeg: name the hardware decoder's failure as the decoder
choice`. Test: `tools/pi-tests/h264.sh rate` (new phase). Raw output: `artifacts/v8-rate/results/` (not in git).

### 7.1 Why

The pre-gate check (W47 11-20 16:28) found that play-1080p60 on the VideoCore drops ~215 frames in 20 s while the
software decoder plays it with none dropped at ~2 cores: the VideoCore decodes 1080p at ~69 fps (vchiq.md §8.3:
79 fps flat out with the clock held), which leaves no headroom at 60 fps, and MediaPlayer's late-frame path then
skips to the next key frame, so most of the stream is never decoded (below: 210–826 frames decoded of the ~1500 of
a run).

### 7.2 The rule (`AVCodecDecoder::_PreferHardwareDecoder()`, media kit ffmpeg plugin)

- Decided in `Setup()` from the container's format: width × height (`encoded_video.output.display`) × frame rate
  (`field_rate`, from `av_guess_frame_rate()` in AVFormatReader). Above **1920×1080 × 45 fps = 93 Mpixel/s**
  (two thirds of the VideoCore's ~143 Mpixel/s at 69 fps) the software `h264` decodes; at or below, `h264_mmal`
  with the CPU fallback as before. So 1080p30 (62), 720p30 (28) and 720p60 (55) stay on the VideoCore; 1080p48/50/60
  go to the CPU (measured on the Pi: 720p30, 1080p30, 1080p60; 720p60, 1080p48/50 and the unknown-rate case below
  follow from the rule, not run).
- A frame rate the container cannot tell (≤ 0, or above 240 fps: AVFormatReader falls back to the time base's rate,
  e.g. 90000) keeps the VideoCore, as before.
- `FFMPEG_H264_MMAL=0` forces the software decoder (unchanged), **`FFMPEG_H264_MMAL=1` forces the VideoCore**
  whatever the rate (new; the open/decode fallback still applies).
- Logged with a reason, once per decoder, as the `AVCodecDecoder: video decoder` line (before: only for the
  hardware decoder, without a reason):
  `video decoder h264_mmal (1920x1080 at 30 fps: 62 of its 93 Mpixel/s)`,
  `video decoder h264 (1920x1080 at 60 fps: 124 Mpixel/s, more than h264_mmal's 93)`,
  `video decoder h264 (FFMPEG_H264_MMAL=0)`, `video decoder h264_mmal (FFMPEG_H264_MMAL=1; 1920x1080 at 60 fps)`,
  after a failed open `video decoder h264 (h264_mmal failed: does not open)`.
- Not conditional on the output colour space: the decoder is chosen before the output is negotiated, and with
  RGB32 output too the CPU does better than the VideoCore at 1080p60 in MediaPlayer (§7.3; WebPositive at 1080p60
  not measured).
- The CPU is not checked: the rule exists only where `h264_mmal` does (the Pi 4, 4 cores).

### 7.3 Results (Pi 4, network session `v8rate`, 2026-11-20 16:34–16:53, image `haiku-pi4-pregate-1120.img` + the branch's plugin in `~/config/non-packaged`; 0 PANIC, 0 debugger entries)

MediaPlayer, 20 s measured from 5 s after the start (`teamstat`), dropped = "VideoProducer: dropped frame" over the
whole run (~25 s), shown = the overlay plane's updates per 10 s. Three `rate` runs plus one `play` run; ranges:

| Clip | decoder (how chosen) | MediaPlayer CPU (of one core) | system (4 cores) | dropped | shown per 10 s |
|---|---|---|---|---|---|
| 720p30 | h264_mmal (rate) | 13.5–15.0 % | 4.6–5.2 % | 0 | 300–302 (all) |
| 1080p30 | h264_mmal (rate) | 24.5–26.1 % | 7.9–8.2 % | 0 | 301–302 (all) |
| **1080p60** | **h264 (rate)** | **203–207 %** | **52–53 %** | **0, 8, 11, 10** (of ~1500; in the first seconds) | **588–601 of 600** |
| 1080p60 | h264_mmal (`=1`) | 14–76 % | 5–24 % | 216, 420, 538 | 29–170 (210–826 frames decoded in the run) |
| 1080p30 | h264 (`=0`) | 95.8–96.4 % | 24.8–25.0 % | 0 | all |
| 1080p60, RGB32 output (`FFMPEG_YUV420=0`) | h264 (rate) | 318–320 % | 82 % | 832–850 | 181–214 (~20 fps) |
| 1080p60, RGB32 output | h264_mmal (`=1`) | 13.4–13.5 % | 4.6–4.7 % | 172–174 | 91–92 frames decoded in the run (~4 fps) |

- **1080p60 now plays on the CPU with every frame shown** after the first seconds (0–11 of ~1500 dropped), at ~2.05
  cores; on the VideoCore (`=1`) it still collapses as before (the pre-gate numbers).
- The few drops are a pattern, not noise, and not explained: all three `rate` runs dropped 8–11 frames (588–592
  updates in their first 10 s), the `play` run 0 (601). In `rate` the clip plays right after a 1080p30 play on the
  VideoCore, in `play` after a software one. Open, not blocking.
- 720p30 and 1080p30 stay on the VideoCore at the known cost (KNOWN-ISSUES P2: 25.8 % / 13.5 %).
- RGB32 output (MediaPlayer with `FFMPEG_YUV420=0`: what a consumer without the YCbCr plane gets): 1080p60 is poor
  either way, the CPU's ~20 fps at 3.2 cores better than the VideoCore's ~4 (MediaPlayer's late-frame path again) —
  the rule stays unconditional. WebPositive at 1080p60 (`h264.sh web` plays 720p30) not measured.
- `h264.sh two`: the second window prints `h264_mmal failed (does not open): h264 continues from the start` and
  `video decoder h264 (h264_mmal failed: does not open)` (before 0807f116bb its decoder line carried the reason the
  VideoCore had been chosen); ffmpeg's `-c:v h264_mmal` exits 14 ("decoder is in use"); 0 problems. `h264.sh kill`
  (3 kills mid-decode, then a 720p30 player on the VideoCore): 0 problems. `h264.sh play`, `rate`: 0 problems (one
  `rate` run counted 11 drops against a first limit of 10; the limit is now 2 % of the run, 30).
- `late` counts (an update within 2 ms of the blank) vary run to run for the same clip and decoder (720p30 on the
  VideoCore: 0 in three runs, 294 of 302 in one): the producer's phase, as in video-overlay.md §3; no frame lost.

### 7.4 Firefox's `h264_vc` (ffmpeg6 patch 0003): not changed

- `why_not_vc()` (`files/libavcodec/h264_vcdec.c`) is where the same rule would go, but Firefox does not give a frame
  rate: neither `FFmpegVideoDecoder.cpp` (`InitCodecContext()`: width, height, threads, `get_format`, the low-delay
  flag) nor `FFmpegDataDecoder.cpp` (`InitDecoder()`: extradata, `opaque`, `max_pixels`) sets `framerate` or
  `time_base` (Firefox's current main branch, read 2026-11-20, not the 157.0.1 tag; unlikely to differ). The rate would have to come from the stream:
  the SPS's VUI timing (`time_scale / (2 × num_units_in_tick)`), which libavcodec parses cheaply inside h264_vc
  (`ff_h264_decode_extradata()` on the avcC record) — our clips carry it (x264: 120 / 2 → 60 fps); a stream without
  VUI timing would stay on the VideoCore as now.
- Whether it helps Firefox is **unproven**: its main process already takes ~2 cores drawing video (G2) and drops
  ~40 % at 1080p30 with either decoder (§1.5); two more cores of software decoding at 1080p60 would compete with it.
  To measure (`vc-services.sh firefox` on a 1080p60 clip, h264_vc vs `FFMPEG_H264_MMAL=0`) before an ffmpeg6 -9.
  Saturday's gate ships ffmpeg6 -7; nothing changed there.

### 7.5 Merging (for the main session, after the 2026-11-21 gate)

**Merged 2026-11-21** as 289a46c68b (cherry-pick of f83e9d129b) on rpi4; KNOWN-ISSUES P2 updated (W47 11-21 06:19).

- Merge `v8-h264-rate` into rpi4 (the ffmpeg add-on only; no package changes), **squashed into one commit with a
  corrected message**: a5011fe1cc's message says 1080p60 on the VideoCore dropped "216 of ~1200 frames in 20 s, the
  rest shown after seeks to key frames" — the runs show 216–538 dropped, 210–826 frames decoded of ~1500 in a ~25 s
  run and 29–170 shown per 10 s (§7.3); 0807f116bb is a fixup of it. (Pushed: not rewritten here, no force-push.)
- KNOWN-ISSUES P2: replace "1080p60 H.264 now runs in real time but drops ~200 of 240 frames (the VideoCore's ~69
  fps leaves no headroom; before: shown in slow motion at 23.98 fps)" with: "**H.264 above 1080p at 45 fps (1080p50,
  1080p60) is decoded on the CPU** from image-<merge> (the VideoCore's ~69 fps at 1080p leaves no headroom: it showed
  1080p60 with most frames dropped): 1080p60 ~2.05 cores (53 % of the system), every frame shown after the first
  seconds (0–11 of ~1500 dropped); `FFMPEG_H264_MMAL=1` forces the VideoCore", and the workaround column: "CPU
  decoding (`FFMPEG_H264_MMAL=0` forces it, `=1` forces the VideoCore)".

## 8. (VQ1) The kernel PANIC "Failed to unwire page" in VCHIQ-0 (2026-11-22)

Haiku branch **`vq1-vchiq-unwire`** (haiku-pi, off rpi4 519adfacb3), **merged into rpi4 as eaeb21e6e6**
(2026-11-22, §8.6): 02813adf89 `kernel/vm: don't unmap wired pages above a cut out of an area's middle` (the fix),
d0361ca9e1 `vchiq: find a bulk buffer's area once the buffer is locked` (a driver race the tests exposed; it relies on
the first), 66a920ff23 `kernel/vm: above a cut, wait only for lock_memory_etc()'s wired ranges` (§8.4). Tools: `tools/haiku-tests/wiredcut.c`, `tools/haiku-tests/vq1-cut.c` (+ `vchiq_test_cut` in
`scripts/build-vchiq-test.sh`), `tools/pi-tests/vq1-*.sh`. Images, binaries and the diagnostic patches:
`artifacts/vq1/` (not in git).

### 8.1 Symptom

`PANIC: unlock_memory_etc(): Failed to unwire page: address space 0x…, address: 0x…` in thread `VCHIQ-0`,
`slot_handler_func` → `vchiq_complete_bulk` → `vchiq_haiku_buffer_unlock` (+0xd0) → `unlock_memory_etc`. Twice on
11-22 in the MP3 agent's sessions (rpi4 519adfacb3 + two MediaPlayer commits; the vchiq driver and the VM as in
image-2026-11-21b, so the release has it): `artifacts/mp3/uart-session-mp3-{1,2}-panic.log`, each 0.2 s after a new
MediaPlayer's H.264 decoder started on the VideoCore and ~1.2 s after the previous player ended (`kill -9` while
decoding; `hey quit`).

### 8.2 Root cause (the code path)

The message narrows it: `unlock_memory_etc()` panics only when `LookupArea()` finds an area at the address and
`Query()` finds no present page in it. A dead team has no areas (its unlock returns `B_BAD_ADDRESS` silently), and a
buffer rescued at `TEAM_REMOVED` is unlocked at its kernel clone's address; the panic's address is a user one. So a
**live** team's wired pages had lost their mappings while their area still existed. The VM path that does that:

1. libroot's allocator (`PagesAllocator::_UnlockingUnmap()`, "Cut the middle and get the new ID") `munmap()`s a freed
   large chunk in the middle of its heap area (holding its own lock).
2. `_user_unmap_memory()` waits for wired ranges **in the cut range only** (`wait_if_address_range_is_wired()`), then
   `vm_unmap_address_range()` → `cut_area()`.
3. `cut_area()`, middle case: `unmap_pages(area, address, area->Size() - firstNewSize)` unmaps the cut **and the whole
   part above it**, moves that part's pages to a new cache (`Adopt()`) of a new area, which maps them again only when
   they are touched. The `VMAreaWiredRange` stays with the first area.
4. A bulk buffer above the cut is written by the VideoCore's DMA, which never faults: at the end of the transfer
   `vchiq_haiku_buffer_unlock()` → `unlock_memory_etc(team, …)` finds the second area and no page → **"Failed to
   unwire page"**. A cut between `lock_memory_etc()` and `get_memory_map_etc()` in `vchiq_haiku_buffer_lock()` panics
   **"get_memory_map() called on unmapped memory!"** instead.

**Caught in the act on the Pi** (image A below, MediaPlayer on MP3's clip, session vq1 16:03): the new player, team
1469, started at 188.37 s; at 188.775 s the diagnostic kernel printed `VQ1: cut_area: team 1469 area 37621 "heap
area" [0x78f8b61000, 0x78fb289000): the cut [0x78fa90d000, 0x78face7000) unmaps wired pages above it`, and the next
line is `PANIC: unlock_memory_etc(): Failed to unwire page: … address: 0x78face9000` with MP3's stack — two pages
above the cut (a ~3.8 MB block, one 720p frame's worth, freed in the middle of the heap area). All three MediaPlayer
panics on image A (§8.3) came right after such a line for the new player's heap area, two of them the
`get_memory_map()` variant; no `VQ1: cut_area` line ever appeared without a panic following it.

Nothing here is specific to VCHIQ: any driver that keeps user memory wired while another thread of the same team
frees memory can hit it (the disk I/O below shows both panics), on any architecture; upstream's `cut_area()` and
`_user_unmap_memory()` are the same.

The brief's hypotheses, checked against the code and the logs:

| Hypothesis | Verdict |
|---|---|
| a bulk of the dead/quit team completes late against a stale or recycled address space | no: a removed team's address space has no areas (`B_BAD_ADDRESS`, no panic); neither log has the rescue's "went away with a bulk transfer queued" line, so no locked buffer was outstanding when the old team went; the panicking buffer was the new team's |
| a per-team bookkeeping entry is reused by the new team | no: one `vchiq_haiku_buffer` per transfer, freed at its unlock; nothing per team survives |
| double unlock after the `TEAM_REMOVED` rescue | no: a rescued buffer is unlocked at its kernel clone's address, and no rescue happened |
| lock and unlock with different flags or range | no: both use the buffer's own `address`, `size` and `lock_flags()` |
| (found) the area was cut below the wired buffer | **yes**: steps 1–4, seen by the diagnostic, reproduced at will (§8.3) |

The previous player matters only through timing: the panic comes from the new decoder's first transfers, when the
player frees and allocates frame-sized blocks.

### 8.3 Evidence

Diagnostic kernels (`artifacts/vq1/diag-cut.diff`, `diag-fix.diff`; not on the branch): kernel **A** = rpi4 + a
`VQ1: cut_area: … unmaps wired pages above it (n)` line in the middle-cut path; kernel **B** = A + the fix + a
`VQ1: unmap: … waits for wired pages above it (n)` line where the fix waits. Image **A** = the regular image of rpi4
519adfacb3 built in the worktree (hrev60450+368) with kernel A; **B** = A with the haiku package's kernel swapped; **C**
= B + the branch's vchiq driver; **H** = A with the branch's own kernel and driver (no diagnostic). Only the kernel and
the vchiq driver differ between them.

**MediaPlayer back to back** (`vq1-mpswitch.sh` via `vq1-run.sh`: start, 4 s of playback, end, the next one 1 s after
the old team is gone). The clip decides it: MP3's `play-720p30-aac.mp4` (`artifacts/wp3/clips`, served at full speed by
`wp4-httpd.py`) triggers it; the media-tests clips (1080p30 file, 720p30 over http, at full speed or 1500 kB/s) did not
in 185 decodes on A. On C the diagnostic shows the fix at work in exactly that situation: 4 `VQ1: unmap: team … "heap
area" … waits for wired pages above it` lines from 3 players' heaps in 90 starts — on A each such cut was a PANIC
(3 `VQ1: cut_area` lines, 3 panics, in 120 starts). The players whose `free()` waited played on normally (the H.264
clock line, ~100 plane updates per 200 vblanks, ended by their kill or quit). 0 in 90 alone would be weak against a
~2.5 % baseline (a ~10 % chance of luck); the intercepted cuts carry the claim. Both images also had MediaPlayer
debugger entries in these URL runs — all `double free` under `BUrl::UrlString()`, i.e. C16 (fixed in rpi4 fb3d9ac1bd
by MP3, not in these images): A 5 in 120 starts, C 12 in 90 (WP4 measured ~3 in 20); none in a kernel path.

| Image | MP3's clip over http, kill -9 | the same, hey quit | other clips (kill, quit, http, throttled) | encode (`testsrc2` 1080p30, half killed) |
|---|---|---|---|---|
| A (no fix) | **2 PANIC** in 90 starts (84 decodes) | **1 PANIC** in 30 | 0 PANIC in 185 decodes, 0 `VQ1:` lines | 0 PANIC in 20 |
| C (the branch, diagnostic kernel) | **0 PANIC** in 60; the fix waited 3 times | **0 PANIC** in 30; waited once | 0 PANIC in 100 decodes | 0 PANIC in 20 |
| B / H (kernel fix / the branch's own build) | – | – | 0 PANIC in 30 / 10 decodes | – |

**Deterministic tests** (no luck needed):

- **QEMU** (`scripts/qemu-virt.sh`, virt + EDK2, the same build's `haiku-mmc.image`, `wiredcut` as UserBootscript:
  `tools/pi-tests/vq1-wiredcut-boot.sh`): a thread `pread()`s 8 MB from `/dev/disk/virtual/virtio_block/0/raw` into the
  upper half of a 16 MB mapping (the I/O scheduler wires it), the main thread cuts one page near the start after a
  random 0..DELAY µs.
  - A: the first cut panics — DELAY 3000: **"Failed to unwire page"** at the buffer's first page, from
    `IOSchedulerSimple::_Finisher` → `IORequest::NotifyFinished` → `IOBuffer::UnlockMemory` (the same
    `unlock_memory_etc + 0x37c` as on the Pi); DELAY 1500: **"get_memory_map() called on unmapped memory!"** from
    `DMAResource::TranslateNext`.
  - B: 200 of 200 rounds twice, every read complete, every `munmap()` waited (195 / 193 `VQ1: unmap … waits` lines);
    the branch's own kernel: 200 of 200. 0 PANIC.
- **Pi, VCHIQ** (`vchiq_test_cut -b 1024 400`: the firmware's echo bulk test, its 1 MB buffers in the upper half of a
  64 MB mapping, another thread cutting a page below them every 2 ms; `vq1-vchiqcut.sh`):
  - A: **4 of 4** sessions panicked at the first `VQ1: cut_area` line — twice `get_memory_map()` in
    `vchiq_haiku_buffer_lock()`; twice, with a cut every 300 ms (`VQ1_CUT_US=300000`), MP3's exact stack: `VCHIQ-0` →
    `vchiq_complete_bulk` → `vchiq_haiku_buffer_unlock` → "Failed to unwire page".
  - B: 4 of 5 runs complete, 0 PANIC; run 3 aborted on `vchiq: cannot lock the bulk buffer …: Invalid Argument` — the
    driver looked the buffer's area up before locking it, and a cut between `area_for()` and its size check made it
    "not in one area". Fixed by the branch's second commit.
  - C: **10 of 10** complete, 0 PANIC, 6667 cuts of which 3272 waited ≥ 1 ms (6060 kernel wait lines).
  - H (the branch's own build): 5 of 5 complete. **`kill -9` during the waits** (`KILL=1`: `-b 1024 2000` killed after
    2 s, 8 times): every team gone, no buffer kept by the rescue, a normal run afterwards exit 0 — 8 of 8.

**No regression** (C against A, same session plan; network sessions vq1 15:04–15:20, 15:21–15:41 (C), 15:42–15:52 (A)):

| Check | A | C |
|---|---|---|
| `h264.sh audio` MediaPlayer CPU (one CPU), 720p30 hw / sw | 18.2 % / 47.0 % | 19.1 % / 47.1 % |
| 1080p30 hw / sw | 31.4 % / 99.4 % | 31.9 % / 98.6 % |
| frames dropped (VideoProducer), all four | 0 | 0 |
| Firefox (`ffv0.sh`, 10–12 s window) h264-720p: frames / dropped / Firefox CPU | 359 / 0 / 17.9 s | 357 / 1 / 17.0 s |
| h264-1080p | 299 / 10 / 24.0 s | 299 / 9 / 23.5 s |
| ffmpeg `h264_mmal` encode of `testsrc2` 1080p30, 10 complete runs | 120 frames each | 120 frames each |
| plane updates late (display statistics, all MediaPlayer runs of a session) | 8–20 % | 11–23 % |
| debugger entries | 0 | 0 |

### 8.4 The fix

`kernel/vm` (02813adf89): `size_to_unmap(area, base, size)` says how much of an area unmapping a range unmaps from
`base` on — for a cut out of the middle, up to the area's end. `wait_if_address_range_to_unmap_is_wired()` replaces
`wait_if_address_range_is_wired()` before the four `vm_unmap_address_range()` callers (`munmap()`, and
`B_EXACT_ADDRESS` + `CREATE_AREA_UNMAP_ADDRESS_RANGE` in anonymous, null and file areas); rpi4's
`vm_clone_area_etc()` with the same flag refuses (`B_BUSY`) on the same range. `MADV_FREE` keeps the old check: it
discards without cutting.

`kernel/vm` (66a920ff23, the owner's decision of 11-22, below): the cut range itself waits for any wired range, as
upstream always did; the part above a middle cut waits only for ranges of `lock_memory_etc()` (implicit ranges; new
`VMArea` flag `IGNORE_EXPLICIT_WIRED_RANGES` for `AddWaiterIfWired()` and `IsWired()`). Those are the ones that
break: their memory is looked up by address again (`unlock_memory_etc()`, `get_memory_map_etc()`) while a device
transfers. `vm_wire_page()` ranges (explicit) are not hurt by losing the mapping — the page stays wired in its cache,
`vm_unwire_page()` works from the page and area it recorded, the user mutex code keys a shared mutex on the physical
address — but they last as long as a thread waits on a mutex shared between teams (`B_USER_MUTEX_SHARED`: libroot's
process-shared mutexes, condition variables, barriers and unnamed semaphores). With 02813adf89 alone, a `free()`
that cut below such a mutex in the heap blocked until the mutex was released (`tools/haiku-tests/pshcut.c` in QEMU:
10 of 10 `munmap()`s blocked until the holder unlocked; with 66a920ff23 and on the unfixed kernel 10 of 10 returned
at once).

`vchiq` (d0361ca9e1): `vchiq_haiku_buffer_lock()` takes the buffer's area id after `lock_memory_etc()`. With the
kernel fix a locked buffer stays in that area for the whole transfer (a cut below it waits, a cut above leaves it in
the area that keeps the id), which the `TEAM_REMOVED` rescue relies on: with the id taken before the lock, a cut in
between refused a valid buffer (seen), and an id that later named only the part below the buffer would have made the
rescue clone the wrong range.

### 8.5 Decision, limits and what is unchecked

- **Decision (owner, 2026-11-22):** keep the waiting fix, narrowed to `lock_memory_etc()` ranges above the cut
  (66a920ff23), gate it on the Pi and merge it (§8.6). A fix **without** any new waiting — `cut_area()` keeps the
  wired pages of the upper part mapped (moves their page mappings and wired ranges to the new area), keeping "wired
  means mapped", which `get_memory_map_etc()` relies on even with interrupts off — is more VM code (mapping lists,
  page-table pages) and is left as a possible upstream follow-up (UPSTREAM-BUG-REPORTS HK-90 mentions it).
- **What still waits:** a `free()` that cuts below a buffer under `lock_memory_etc()` I/O waits for that I/O,
  uninterruptibly and with libroot's allocator lock held, and `kill -9` of that thread takes effect only then. MMAL's
  transfers end within milliseconds, but back-to-back transfers starve the cut (`vchiq_test_cut` on the branch's
  build, 7.5 ms per iteration: the cutter got only 7–12 cuts in ~3 s). The lock leaked by an aborted bulk the
  VideoCore never acknowledged (vchiq.md §2: the core's dummy bulk drops `remote_data`, as in FreeBSD and Linux) is
  an implicit range: a `free()` that cut below it would wait for good. Not seen. The v3d import and the
  debugger/profiler lock kernel clones, not the user area, and are not affected.
- **Explicit ranges above a cut keep upstream's behaviour:** their pages lose the mapping and the range stays on the
  lower area beyond its end (harmless for `vm_unwire_page()`; deleting that lower area waits for it).
- Unchecked: how long a cut waits in MediaPlayer (not measured); whether the wait changes C16's rate (§8.3); a 1080p
  decode + 1080p encode in one ffmpeg (`h264_vc` → `h264_mmal`) failed with VideoCore `ENOMEM` on C
  (`mmal_vc_port_enable … video_encode:in:0 … ENOMEM`), 10 of 10, not tried on A (the encode checks use `testsrc2`).
- `exec()` with transfers queued (vchiq.md §2) is unchanged.

### 8.6 Gate and merge (2026-11-22)

Gate (owner's plan): rpi4 fb3d9ac1bd merged with the branch, without diagnostics (merge commit **eaeb21e6e6**, the
haiku packages hrev60450_373 swapped into a copy of the mega image, `artifacts/vq1/mega-I.img`); network sessions
`vq1b` 17:23–17:51 and 18:12–18:20 and `mega-smoke` 17:51–18:12, the card and USB untouched;
`tools/pi-tests/vq1-gate-run.sh` / `vq1-gate.sh`:

| Check | Result |
|---|---|
| MediaPlayer on MP3's trigger clip over http, 60 starts, kill -9 / `hey quit` alternating | 60 of 60 on the VideoCore decoder, 0 debugger entries, 0 PANIC |
| `pshcut` (a cut below a waiter on a process-shared mutex in heap memory) | 10 of 10 `munmap()`s returned at once |
| `vchiq_test_cut` ×5, and ×3 killed during the waits | 0 of 5 and 0 of 3 failed (team gone, no kept buffer, next run fine) |
| `clientptr` (GL_MESA_map_buffer_client_pointer: placed maps, the clone-replaces-range path) | GCP PASS |
| Firefox, h264-1080p (`ffv0.sh`, 12 s window) | 360 frames, 6 dropped |
| Blender: open, Cycles viewport with and without denoising, Material Preview, EEVEE F12 (`blender-b7-view.sh`) | 4 of 4 exit 0, 0 wrong-thread lines |
| `pkgman install` (xxhash from a file; plus the session's openssh install) | exit 0 |
| tar of /boot/system/apps + lib (2.8 GB, 18 596 entries) and back | complete, same count |
| mega smoke: 34 Test Apps (Wine x86 and x86-64 programs and games — Notepad++, PuTTY, SumatraPDF, 7-Zip, Warcraft III, StarCraft, …; vkQuake, QuakeSpasm, Quake II/III, SuperTuxKart, OpenArena, glmark2, vkcube, Firefox, WebPositive, Blender, MediaPlayer) | 34 of 34 running (or exited 0 by design) |
| serial logs | 0 PANIC, 0 debugger entries, no hang (every item within its limit) |

Not run: `git clone` (no git in the mega image). The WoW64 Wine A/B with client pointers (`clientptr-ab.sh`,
Warcraft III) was not repeated; Warcraft III ran in the smoke, `clientptr` covers the placed maps.

**Merged** into rpi4 as **eaeb21e6e6** (fast-forward of rpi4 to the merge commit, pushed to haiku-pi); ships in the
next image. QEMU and Pi re-tests: `tools/pi-tests/vq1-gate-run.sh IMAGE [ITEM...]`, `vq1-c-run.sh`, `vq1-run.sh`
(with `wp4-httpd.py artifacts/wp3/clips` for the MediaPlayer reproduction), `vq1-wiredcut-boot.sh` as a QEMU
UserBootscript.

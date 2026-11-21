# VideoCore services beyond H.264 decoding (owner 2026-11-18, item 4)

Status: **done (2026-11-19)**; image-2026-11-21 ships ffmpeg6 6.1.6-7 + raspberrypi_userland 20241223-4 (one VideoCore H.264
stream system-wide, the decoder abort at Firefox quit fixed; [firefox-video-overlay.md](firefox-video-overlay.md) §9.6); V8 (§7, rate rule) not merged yet. (a) works on the Pi, (b) measured and decided (no VideoCore JPEG; a CPU-side
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

Haiku branch **`v8-h264-rate`** (haiku-pi, off rpi4 552c42233d, **not merged**): a5011fe1cc `ffmpeg: keep H.264 on
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

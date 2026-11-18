# VideoCore services beyond H.264 decoding (owner 2026-11-18, item 4)

Status: **in progress (2026-11-18)**. Builds on VCHIQ + MMAL ([vchiq.md](vchiq.md) §6–§8: `/dev/vchiq`, Broadcom's
libmmal in `raspberrypi_userland`, `h264_mmal` in the media kit) and on the YUV overlay work
([video-overlay.md](video-overlay.md), branch `v1-overlay`). In priority order:

| | What | State |
|---|---|---|
| a | H.264 on the VideoCore in **Firefox** | `h264_vc` (ffmpeg6 patch 0003): no Firefox rebuild; host-verified; Pi: §1.4 |
| b | **JPEG** decode (and encode) on the VideoCore for Haiku's translators | measured against libjpeg-turbo: §2 |
| c | **H.264 encode** | `h264_mmal` encoder (ffmpeg6 patch 0004); measured: §3 |
| d | **Camera** (CSI) | §4 |

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

### 1.5 On the Pi

Pending (bench).

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

`mmal-codec jpegenc`, quality 85, from I420: 1920×1080 **46.9 ms** (2.19 MB), 4032×3024 **198 ms** (11.1 MB);
setup 37 / 153 ms (the buffers). The output decodes on the host (PSNR against the source 22.5 / 28.0 dB: the
test pictures carry dense noise). libjpeg-turbo's encode of the same picture: pending (`jpegtime -e`, §5).
Translator encode on the VideoCore not done (same reasoning as decode unless §5 shows a large gap).

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
- Quality on this (noise-heavy) source: 24.9 dB Y at 720p 4 Mbit/s against x264 `veryfast` 32.4 dB at the same
  rate (host); per frame the VideoCore holds ~32.5 dB for 5 frames after each I frame, then ~24.7 until the next
  one. A noise-free source is pending (§5) before calling it the encoder's quality.
- **Not at the same time as a 1080p decode**: with MediaPlayer playing 1080p H.264 on the VideoCore (`get_mem reloc`
  2 MB free), the encoder's input port does not enable (`ENOMEM`); so `ffmpeg -c:v h264_vc -i 1080p.mp4 -c:v
  h264_mmal` (a hardware transcode) fails the same way. The 76 MB `gpu_mem` holds one or the other at 1080p; a
  session with `gpu_mem=128` is pending (§5).
- **Media kit**: Haiku `v4-vc` 6bcab9eb40 lists "H.264 video" in the ffmpeg plugin's encoder table
  (`get_next_encoder()` for MP4 then offers mpeg4, **h264**, theora, mjpeg). The first run (`venc`, BMediaFile as
  MediaConverter) stopped after 76 (720p) / 117 (1080p) frames with `B_ERROR` from `WriteFrames`; two causes found:
  1. mmalenc could return EAGAIN while the caller's frame was still waiting, when an input buffer came back between
     two checks (fixed: EAGAIN only once the caller's frame is taken; the run after the fix got further: 100 / 174
     frames);
  2. the plugin times every packet from one `WriteFrames()` call with the frame count, right only for encoders
     that give exactly one packet per frame at once; h264_mmal gives two or none at times → the same time twice →
     the muxer refuses (non-monotonic DTS). Fixed in `v4-vc` fc81a8ccee (the packet's own pts). Re-run pending (§5).
  MPEG-4 (FFmpeg's software encoder) through the same path: 720p 25.9 fps, 1080p 11.7 fps, 100 % of one core.

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

With the standard firmware (v4a): `get_camera` → `supported=0 detected=0, libcamera interfaces=0`,
`vc.camera_info` → 0 cameras, `vc.ril.camera` not created (`ENOMEM`). That firmware does not probe for a camera at
all, so this says nothing about the connector; the check needs a session image with `start_x=1` (§4.3 step 1),
pending (§5).

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

## 5. Still to run (bench)

1. Firefox on the Pi (§1.5): play-720p30 / play-1080p30, h264_vc vs `FFMPEG_H264_MMAL=0`, Firefox's CPU
   (teamstat over 15 s), frames decoded/dropped, the H.264 clock lines; one run with `MOZ_LOG=FFmpegVideo:4`.
2. `venc` with plugin fc81a8ccee and mmalenc's EAGAIN fix (§3.1).
3. `h264enc` on a noise-free source against x264 at the same rate; `jpegtime -e` (libjpeg-turbo encode).
4. A session with `start_x=1`, `gpu_mem=128` (image ready: start4x.elf/fixup4x.dat from the pinned commit,
   config.txt lines appended): `get_camera`, `camera_info`; the 1080p transcode (decode + encode) with 128 MB.

## 6. Files

- ffmpeg6: `patches/ffmpeg6/0003-h264-vc.patch` + `files/libavcodec/h264_vcdec.c`;
  `patches/ffmpeg6/0004-h264-mmal-encoder.patch` + `files/libavcodec/mmalenc.c`.
- Tests: `tools/haiku-tests/mmal-codec.c` (probe, jpegdec, jpegenc, h264enc), `tools/haiku-tests/jpegtime.cpp`,
  `tools/pi-tests/vc-services.sh` (phases probe, jpeg, jpegenc, h264enc, ffenc, firefox),
  `tools/media-tests/h264vc-host/` (the host harness of §1.3).

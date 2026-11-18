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
- It opens `h264_mmal` in an inner codec context (as FFmpeg's `imm5` nests `h264`), and moves the stream to the
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
this harness, fixed before any Pi run.) Harness: `tools/media-tests/h264vc-host/` (§5).

### 1.4 On the Pi

Pending (bench).

## 2. (b) JPEG on the VideoCore

Pending (bench): `mmal-codec probe` (components and encodings), `mmal-codec jpegdec` vs `jpegtime`
(libjpeg-turbo 3.1.4.1 to BGRX and to raw YCbCr, and Haiku's JPEG translator through
`BTranslationUtils::GetBitmap()`), test pictures 640×480 / 1920×1080 / 4032×3024 (4:2:0, 4:2:2, 4:4:4,
progressive).

## 3. (c) H.264 encoding

FFmpeg 6.1 has no MMAL encoder (`mmaldec.c` only; the Pi's encoder is reached upstream through V4L2-M2M,
`h264_v4l2m2m`, i.e. Linux's GPL `bcm2835-codec`), and our ffmpeg6 build has no H.264 encoder at all (no
libx264). Patch `0004-h264-mmal-encoder.patch` + `files/libavcodec/mmalenc.c` (~390 lines): an `h264_mmal`
encoder on `vc.ril.video_encode`.

Pending (bench): `mmal-codec h264enc` (the component alone) and `ffmpeg -c:v h264_mmal`.

## 4. (d) Camera

Pending (bench): whether a camera is attached (`get_camera`, `vc.camera_info`).

## 5. Files

- ffmpeg6: `patches/ffmpeg6/0003-h264-vc.patch` + `files/libavcodec/h264_vcdec.c`;
  `patches/ffmpeg6/0004-h264-mmal-encoder.patch` + `files/libavcodec/mmalenc.c`.
- Tests: `tools/haiku-tests/mmal-codec.c` (probe, jpegdec, jpegenc, h264enc), `tools/haiku-tests/jpegtime.cpp`,
  `tools/pi-tests/vc-services.sh` (phases probe, jpeg, jpegenc, h264enc, ffenc, firefox),
  `tools/media-tests/h264vc-host/` (the host harness of §1.3).

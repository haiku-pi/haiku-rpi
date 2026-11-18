# Decoded video on a YCbCr display plane (KNOWN-ISSUES F2, P2)

Status: **in progress (2026-11-18)**, branch `v1-overlay` of haiku-pi/haiku (from `rpi4` 2753face8e). Numbers are
marked **measured** (with the source) or **estimated**.

Goal (owner 2026-11-18): hardware-decoded video (H.264 on the VideoCore through ffmpeg's `h264_mmal`, HEVC on rpivid)
cheap to display. Before: MediaPlayer at 1080p30 H.264 took ~88 % of one CPU, mostly the plugin's YUV→RGB32
conversion (swscale has no NEON path for yuv420p → bgra) and copies of 8 MB RGB frames; a YCbCr overlay showed black.

## 0. Decisions in one screen

1. **B_YCbCr422 is not offered.** Haiku's B_YCbCr422 is packed (Y0 Cb Y1 Cr = YUYV). The display's scaler (HVS) has
   no packed 4:2:2 format at all: its pixel formats are RGB, YCbCr 4:2:0 and 4:2:2 in 3 or 2 planes, and 10-bit/SAND
   variants (Linux `vc4_regs.h` `enum hvs_pixel_format`, facts only), and Linux's firmware-KMS table never sends
   the firmware's YUV422YUYV (45). Black is "unsupported", not a byte-order bug. The accelerant now refuses such
   buffers (clients fall back), the driver refuses type 45.
2. **B_YUV420 = planar I420, with a whole-picture bytes_per_row.** The overlay buffer holds Y, then Cb, then Cr
   (half width and height), contiguous. Its `bytes_per_row` is that of the whole picture, 3 bytes per 2 pixels, as
   every B_YUV420 BBitmap and the media kit already define it (`get_raw_bytes_per_row()`:
   `(width + 3) / 4 * 6`; the ffmpeg plugin's `CalculateBytesPerRow…()`): so `bytes_per_row × height` is the
   buffer's size, which BBitmap::BitsLength(), MediaPlayer's producer buffers and its consumer's copy all assume.
   The luma rows are 2/3 of it (64-byte aligned by the accelerant), the chroma rows 1/3. The firmware gets the luma
   pitch and derives the chroma one (pitch/2), as Linux's firmware KMS does.
3. **The ffmpeg plugin puts out B_YUV420 when asked for it**, and RGB32 otherwise as before. A planar 4:2:0 picture
   (`yuv420p`: h264_mmal, hevc_rpivid, the software decoders) is a copy of its three planes; other formats
   (yuv420p10le, yuvj420p, …) go through swscale to yuv420p (still much cheaper than RGB). The caller's
   `bytes_per_row` is kept when it is wider (a consumer's bitmap rows). `FFMPEG_YUV420=0` turns it off.
4. **The decoded picture is converted only in `Decode()`, straight into the caller's buffer** (before: converted
   into the plugin's own buffer when decoded, then copied): one full-frame copy less for every video, RGB too.
5. **An output-only renegotiation keeps the decoder.** When the caller asks again with only another color space or
   `bytes_per_row` (MediaPlayer does when its consumer's bitmaps differ, or when it falls back from an overlay to
   RGB32), the plugin changes its output and goes on decoding; the picture waiting is converted into the new
   format. Before, every renegotiation reopened the codec (for h264_mmal a new VideoCore decoder) and lost the
   position until the next key frame.
6. **MediaPlayer asks for B_YUV420 only where it can be shown**: it already asked for the stream's own format
   (B_YUV420 for yuv420p streams, from the reader); it now asks for B_RGB32 instead when the screen has no B_YUV420
   overlays (other graphics drivers: unchanged behaviour), and knows B_YUV420's bytes per row.
7. **The decoder does not write into the overlay bitmaps themselves** (tried, measured, reverted: §3). MediaPlayer's
   consumer keeps copying each frame into its overlay bitmap: 3 MB at 1080p, lost in the noise of the team's CPU.
8. **A hardware decoder's frame rate is not trusted**: h264_mmal reports the 24000/1001 that mmaldec tells the
   VideoCore, whatever the stream's rate; the plugin took it over the container's 60 (its guess prefers a codec rate
   below 0.7 × the container's), so **1080p60 H.264 played at 23.98 frames/s, in slow motion** — the "24 fps shown"
   of P2 since 11-05 was this, not the CPU.

## 1. Path of a frame (1080p, H.264 on the VideoCore, MediaPlayer)

| Step | Before (image-2026-11-18) | After (`v1-overlay`) |
|---|---|---|
| VideoCore → MMAL buffer | VCHIQ bulk DMA, 3 MB I420 | same |
| mmaldec: MMAL buffer → AVFrame | copy, 3 MB | same (§5) |
| plugin | swscale I420 → BGRA into its own buffer (8 MB written, the C path: no NEON), then a copy of 8 MB into the producer's buffer | a copy of the three planes into the producer's buffer, 3 MB |
| MediaPlayer's consumer | copy of 8 MB into the overlay bitmap (write-combining) | copy of 3 MB |
| display | HVS scales an XRGB plane | HVS converts YCbCr (BT.709 from 720 lines on, BT.601 below) and scales |

HEVC on rpivid: the same, with rpivid's SAND → planar conversion on the CPU in place of mmaldec's copy (§5).

## 2. Changes (haiku-pi/haiku `v1-overlay`, from `rpi4` 2753face8e)

| Commit | What |
|---|---|
| 84d5ea7bdb | bcm2711_display: B_YUV420 overlays with the whole picture's bytes_per_row; no B_YCbCr422 (accelerant), type 45 refused (driver) |
| b0a42969b9 | ffmpeg: B_YUV420 output (plane copy, swscale for other 4:2:0 formats), conversion in `Decode()` straight into the caller's buffer, the caller's wider rows kept, output-only renegotiation without reopening the codec, `FFMPEG_YUV420=0` |
| 098abbcd52 | MediaPlayer: B_YUV420's bytes per row; B_YUV420 asked for only when the screen has B_YUV420 overlays |
| cb891d5b85, 3630e9cc0e | MediaPlayer: the decoder writes into the overlay bitmaps (shared buffer group) — and its revert (§3) |
| a9465e1c3f | ffmpeg: B_YUV420 only from 4:2:0 pictures (no chroma lost on 4:2:2/4:4:4/RGB sources); no frame rate from a hardware decoder |
| 4683784899 | MediaPlayer: B_YUV420 also for streams without a BeOS color space (10-bit HEVC) |
| 6cda54a399 | MediaPlayer: a frame that could not be read is B_YUV420 black, not dark green |
| 92db783ffc | MediaPlayer: no copy into an overlay bitmap while overlays are suspended (the mode-change crash, §3.1) |

This repository: `tools/haiku-tests/overlaytest.cpp` (the new B_YUV420 layout, `-x WIDTHxHEIGHT`, BT.709 from 720
lines, ycbcr422 only on request and expected to fail), `tools/media-tests/vdecode.cpp` (`VDEC_SPACE=yuv420`),
`tools/pi-tests/video-overlay.sh` (phases `ovl`, `play`, `hold`; `MP=` another MediaPlayer binary).
Test clips: `tools/media-tests/gen-h264-clips.sh`'s play clips, plus HEVC play clips made with the host's x265
(`testsrc2` with light noise, keyint 60, `-preset fast`): `play-hevc-720p30.mp4` (60 s, 4 Mbit/s),
`play-hevc-1080p30.mp4` (60 s, 8 Mbit/s), `play-hevc10-1080p30.mp4` (30 s, yuv420p10le, 8 Mbit/s), and
`play-854x480.mp4` (H.264, 30 s: a width that is not a multiple of 64). Kept in `artifacts/v1-overlay/clips/` (not in
git); the command lines are in the log entry of 11-18.

## 3. Results (Pi 4, network session `v1a`, 2026-11-18 17:34–17:47, image `v1-overlay` at 098abbcd52 + the shared-buffer MediaPlayer copied in)

Serial log `artifacts/uart/*-session-v1a.log`, 0 PANIC; raw output and HDMI frames in `artifacts/v1-overlay/` (not in
git). MediaPlayer's CPU = `teamstat` over 20 s from 5 s after the start (of one CPU); shown = the overlay plane's
updates per 10 s in the display driver's statistics (`late`: an update within 2 ms before the predicted vertical
blank); dropped = MediaPlayer's "VideoProducer: dropped frame".

**Correctness** (HDMI capture, **measured**): overlaytest B_YUV420 320×240 (BT.601) shows the eight bars in order,
75 % levels read back as 178–189 of 191 (capture and 4:2:0 rounding), the yellow window over them (keying), the
square moving, 120 flips at 60.2/s, front-buffer census as for RGB32 (0 non-opaque pixels outside, 307 200 keyed
inside), PASS. MediaPlayer on `play-1080p30.mp4` with `B_YUV420 (h264_mmal yuv420p, 1920x1080)`: testsrc2's colours
and geometry right, one decoder line, no renegotiation. `play-854x480.mp4`: the consumer's bitmap rows (1344 =
1.5 × 896) differ from the decoder's (1284): one `video output now B_YUV420, 1344 bytes per row` (the output-only
switch), the same decoder, the picture right.

**Cost** (1 run each, same session, same clips):

| Clip | B_YUV420, copy into the overlay (098abbcd52) | B_YUV420, decoder writes the overlay bitmaps (cb891d5b85) | `FFMPEG_YUV420=0`: the new plugin's RGB32 |
|---|---|---|---|
| H.264 720p30 (h264_mmal) | **13.5 %**, all shown, 0 dropped | 13.4 %, **21 dropped** | 24.5 % |
| H.264 1080p30 | **25.8 %**, 301–302 shown, 0 late, 0 dropped | 26.1 %, 282–290 shown, **26 dropped** | 47.7 %, 254–283 late |
| H.264 1080p60 | 20.0 %, 240 shown (23.98 fps: the frame-rate bug, §0.8) | 17.5 %, 240 | 37.8 %, 240 |
| HEVC 720p30 (rpivid) | **11.8 %**, all shown | 10.9 % | 20.8 % |
| HEVC 1080p30 | **23.6 %**, all shown | 20.5 % | 43.4 % |
| HEVC 10-bit 1080p30 | 67.3 %, ~3 fps, 287 dropped (still RGB32: MediaPlayer asked for B_YCbCr422, fixed in 4683784899) | 55.9 %, 253 dropped | 64.9 %, 286 dropped |

- Against P2's numbers (11-05, the same H.264 clips, release images since): 1080p30 **88 % → 25.8 %**, 720p30
  **40 % → 13.5 %**.
- The shared buffer group saves one 3 MB copy per frame but costs frames (the producer is short of buffers while the
  replaced one waits for the display's update point) and saves nothing measurable: reverted.
- 720p30 in the first column: 298 of 300 updates `late` — the producer's phase sat within 2 ms of the blank for the
  whole run (in the other runs 0–2); all frames shown, none dropped.

### 3.1 Network session `v1b` (2026-11-18 20:44–21:00, image at 4683784899, MediaPlayer of 6cda54a399 copied in; 0 PANIC)

| Clip | MediaPlayer's CPU | shown per 10 s | dropped |
|---|---|---|---|
| H.264 720p30 (h264_mmal) | **13.2 %** | 301–302, 0 late | 0 |
| H.264 1080p30 | **24.7 %** | 301–302, 0 late | 0 |
| H.264 1080p60 | 13.4 % | **now real time** (`rate`: 14.57 s of video after 15 s; before: 23.98 fps slow motion), but only 34–68 frames shown in all: 203 dropped | 203 |
| HEVC 720p30 (rpivid) | 11.9 % | all | 0 |
| HEVC 1080p30 | 23.0 % | all | 0 |
| **HEVC 10-bit 1080p30** | **43.4 %** (was 67.3 % at ~3 fps) | **all**, `B_YUV420 (hevc_rpivid yuv420p10le …)` | **0** (was 287) |
| H.264 1080p30, software decoder (`FFMPEG_H264_MMAL=0`) | 98.3 % (P2: 159 %) | all, 0 late | 0 |

- **1080p60 at real time does not keep up**: the VideoCore decodes ~69 frames/s back to back (`vdecode`, 14.1 ms mean,
  39 ms max), with no headroom at 60; MediaPlayer decodes one frame when it is due and, once a frame is late, drops
  it — and its supplier then *seeks* to the next frame wanted (`ProxyVideoSupplier::FillBuffer`), back to the
  previous key frame (up to 60 frames), which makes every later frame late too: the same collapse as the software
  decoder's at 1080p60 in P2. Before a9465e1c3f the stream ran at 23.98 fps, every frame shown, in slow motion (and
  out of step with any audio track). Open (§5).
- `noplane` (six overlaytests hold all six planes): MediaPlayer's YUV overlay bitmaps fail (`COULDN'T CREATE BUFFERS`),
  NodeManager falls back to B_RGB32 drawn by app_server, the plugin switches its output without reopening the decoder
  (`video output now B_RGB32, 7680 bytes per row`, one `video decoder h264_mmal` line), picture right on HDMI
  (`shots/b-noplane.png`), 60.8 % (the app_server path).
- `mode` (1280×720 and back while playing): **MediaPlayer crashed** — `memcpy` from `VideoConsumer::_HandleBuffer`
  with FAR 0: a frame arrived while app_server had overlays suspended, when an overlay bitmap's `Bits()` is NULL. The
  copy has done that since before this work (RGB32 overlays too); fixed in 92db783ffc (`LockBits()`, which fails
  while suspended; the frame is skipped). Not yet re-run.
- overlaytest B_YUV420 at 1920×1080 (BT.709): bars right on HDMI (`shots/b-ovl1080.png`); its alpha census said
  BAD because the window is larger than the screen and the crashed player's alert sat under it (73 000 non-opaque
  pixels outside the overlay already before it was shown) — the test's geometry, not keying.
- `h264.sh seek` 0 problems (pause, seeks forward and back, 5 reopens on the VideoCore); `h264.sh web` 0 problems
  (WebPositive, h264_mmal, RGB32 through the new `Decode()`-time conversion).

### 3.2 QEMU

QEMU virt (2026-11-18 18:10, the image at 4683784899 with a test bootscript; no VideoCore, no overlays): MediaPlayer
on `play-720p30.mp4` and `play-854x480.mp4` takes `preferred color space: B_YUV420`, the gate turns it into B_RGB32
(no YUV output line, no renegotiation), `h264_mmal failed (does not open): h264 continues from the start`, 0 dropped,
0 PANIC; `vdecode` (software h264): B_YUV420 98.7 frames/s at 330 % CPU vs B_RGB32 53.7 frames/s at 264 % (QEMU's
emulated CPU: only the ratio means anything).

QEMU virt, 2026-11-18 19:45 (the image at 4683784899 + `vdecode` with `VDEC_DUMP`/`VDEC_SWITCH`; software h264,
frames copied out of the disk image with bfs_shell and compared on the host, **measured**):

| Check | Result |
|---|---|
| B_YUV420, 20 frames of `h264-720p.mp4` (plane copy) | 20 of 20 bit-identical to ffmpeg's `framemd5` |
| B_YUV420 → B_RGB32 after 10 frames (output-only switch) | frames 0–9 bit-identical; 10–19 RGB at 51 dB PSNR against the host's bgra of frames 10–19 (another swscale build): the decoder went on, no restart |
| B_RGB32 → B_YUV420 after 10 frames | frames 0–9 RGB at 51 dB; **frames 10–19 bit-identical to ffmpeg's frames 10–19** |
| interlaced 720×576 (yadif in the plugin), B_YUV420 and B_RGB32 | frame k bit-identical (YUV) / 51 dB (RGB) to the host's `yadif` frame k−1: the filter's one-frame delay, as before (frame 0 is the field-interleaved picture); the two spaces agree with each other at 51 dB |
| MediaPlayer, no overlays (RGB32 through the gate) | plays `play-720p30.mp4` to the end, picture right (QEMU screenshot `artifacts/qemu/20261118-194920-virt.png`) |

Also: `6cda54a399` MediaPlayer fills a frame it could not read with B_YUV420 black (Y 16, Cb/Cr 128), not zeros
(dark green).

## 4. Still to run (the bench went to other agents again at 20:55)

- The release image in the same session conditions (the *before* column) and the mode change on it.
- The mode change with 92db783ffc.

Kept: `artifacts/v1-overlay/v1-overlay-4683784899.img` (the image of `v1b`; the worktree's build output was deleted),
`artifacts/v1-overlay/new2/MediaPlayer` (92db783ffc), `artifacts/v1-overlay/bin/` (plugin, accelerant, driver of the
image), the clips in `artifacts/v1-overlay/clips/` and `artifacts/media-tests/h264/`. About 10 minutes each:

```sh
P="artifacts/v1-overlay/teamstat tools/pi-tests/video-overlay.sh artifacts/media-tests/h264/play-720p30.mp4 \
   artifacts/media-tests/h264/play-1080p30.mp4 artifacts/media-tests/h264/play-1080p60.mp4 \
   artifacts/v1-overlay/clips/play-hevc-720p30.mp4 artifacts/v1-overlay/clips/play-hevc-1080p30.mp4 \
   artifacts/v1-overlay/clips/play-hevc10-1080p30.mp4"
# before
scripts/pi-session.sh start --image artifacts/images/haiku-pi4-2026-11-18.img --minutes 15 --label v1-before
scripts/pi-ssh.sh "mkdir -p /boot/home/h264" && scripts/pi-ssh.sh put $P /boot/home/h264/
scripts/pi-ssh.sh "cd /boot/home/h264 && sh video-overlay.sh play before && sh video-overlay.sh rate && sh video-overlay.sh mode"
scripts/pi-ssh.sh "grep -a -c 'entered the debugger' /var/log/syslog"; scripts/pi-session.sh stop
# the mode-change fix (HDMI snapshots while it runs: does the overlay come back after the change?)
scripts/pi-session.sh start --image artifacts/v1-overlay/v1-overlay-4683784899.img --minutes 15 --label v1c
scripts/pi-ssh.sh "mkdir -p /boot/home/h264/new" && scripts/pi-ssh.sh put $P /boot/home/h264/ \
  && scripts/pi-ssh.sh put artifacts/v1-overlay/new2/MediaPlayer /boot/home/h264/new/
scripts/pi-ssh.sh "cd /boot/home/h264 && MP=/boot/home/h264/new/MediaPlayer sh video-overlay.sh mode"
scripts/pi-ssh.sh "grep -a -c 'entered the debugger' /var/log/syslog"; scripts/pi-session.sh stop
```

## 5. Open

- **One copy is left before the consumer's**: mmaldec copies the VideoCore's buffer into an AVFrame (3 MB at 1080p);
  avoiding it means handing the MMAL buffer out as the frame (mmaldec does that only for its opaque format) with
  only 3 output buffers in the VideoCore's memory. rpivid: its SAND → planar conversion on the CPU stays (the SAND
  plane of `gpu-stage6.md` §5 is still design only).
- **Mode change** while a video overlay is shown (F2): MediaPlayer's crash fixed (92db783ffc, not re-run yet); whether
  the overlay stays black afterwards is still open.
- **1080p60 H.264 at real time**: MediaPlayer needs to decode ahead (or skip forward by decoding instead of seeking
  to a key frame) to show it; the VideoCore's rate (~69 fps) leaves no headroom.
- ffmpeg's command line (`-c:v h264_mmal`) still reports 23.98 fps for every stream: mmaldec tells the VideoCore
  24000/1001 and hands the echo back as the stream's rate; fixing it is a ffmpeg6 patch (not done; the plugin no
  longer trusts it).
- Colour: the accelerant picks BT.709 from 720 lines on, BT.601 below, limited range (as the stream's metadata would
  usually say); a full-range or BT.2020 stream would need the plugin to pass its colour space on (no media-kit field
  for it).

## 6. Merging (for the main session)

- `v1-overlay` fast-forwards `rpi4` (2753face8e); touched: the display driver and accelerant, the ffmpeg media
  plugin, MediaPlayer. No package, kernel or Mesa change. Apart from the revert pair, every commit stands alone.
- KNOWN-ISSUES: F2 loses "an overlay in the YCbCr422 format shows black" (not offered: no packed 4:2:2 on the display;
  B_YUV420 overlays work) and "MediaPlayer's video is RGB"; P2's MediaPlayer numbers become 25.8 % at 1080p30, 13.5 %
  at 720p30 (H.264), 23.6 % / 11.8 % (HEVC); "1080p60 24 fps shown" was a frame-rate bug (fixed in a9465e1c3f).
- Verified on the Pi: everything up to 4683784899 (sessions v1a, v1b); 6cda54a399 only in QEMU-built code paths
  (not hit on the Pi); 92db783ffc not yet run (§4).
- One decision for the owner: a9465e1c3f makes 1080p60 H.264 play at its real rate, which MediaPlayer cannot keep
  up with on the VideoCore (drops most frames; before: slow motion, every frame). Correct timing (and A/V sync) is
  the reason to keep it; the frame-rate line can be reverted alone if smooth slow motion is preferred until
  MediaPlayer decodes ahead.
- Behaviour change for other media-kit users: none that asked for B_RGB32 or nothing (WebPositive, Firefox's FFmpeg
  path does not use the plugin); an app that asks for B_YUV420 now gets it (planar, the BBitmap layout) instead of
  B_RGB32; any renegotiation that changes only the output space or rows keeps the decoder.

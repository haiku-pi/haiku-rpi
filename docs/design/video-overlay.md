# Decoded video on a YCbCr display plane (KNOWN-ISSUES F2, P2)

Status: **done, released in image-2026-11-19; the stream's encoding (§7, series A) in image-2026-11-21** (merged into `rpi4` at 92db783ffc; release gate 11-19: 1080p30 H.264
25.1 %, the mode change 0 problems with the video back on the plane, HDMI-recorded). Was branch `v1-overlay` of haiku-pi/haiku (from `rpi4` 2753face8e). Numbers are
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
inside), PASS. MediaPlayer on `play-1080p30.mp4` with `B_YUV420 (h264_mmal yuv420p, 1920x1080)`: geometry right, one decoder
line, no renegotiation. **Colours differ from the RGB path at HD** (same clip, same grabber, `shots/mp-h264-1080p-b.png`
on the plane vs `shots/b-noplane.png` through swscale, bar centres): red 245,23,0 vs 243,1,0; yellow 250,237,1 vs
244,252,2; cyan 2,228,249 vs 0,249,243; blue 0,11,243 vs 0,0,239 — green −15…−21 on yellow/cyan, +22 on red: BT.601
values read with the BT.709 matrix. The test clips are untagged and ffmpeg encoded testsrc2's RGB with BT.601; the
plane follows the usual convention for untagged HD (BT.709 from 720 lines, the accelerant), swscale always uses
BT.601. For real HD video (BT.709, nearly always) the plane is the right one and the old RGB path was the one off;
for 601-encoded HD (these clips) the plane shifts hue. The stream's own tag cannot reach the accelerant (no media-kit
field): §5. `play-854x480.mp4`: the consumer's bitmap rows (1344 =
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
| HEVC 8-bit (`play-hevc-720p30`, hevc_rpivid's CPU path in QEMU), B_YUV420, 10 frames | 10 of 10 bit-identical to the host's framemd5 |
| HEVC 10-bit (`play-hevc10-1080p30`), B_YUV420 through swscale yuv420p10le → yuv420p, 10 frames | identical to the host ffmpeg's `-pix_fmt yuv420p` (PSNR inf) |
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
- (V6, §7 and hw-video-decode.md §9: the colour item below is done, rpivid's SAND pictures go to the plane without a
  copy, and the h264_mmal frame rate is patched in ffmpeg6 -8; branch `v6-video`, not merged.)
- Colour: the accelerant picks BT.709 from 720 lines on, BT.601 below, limited range — the usual convention, but
  not the stream's tag: 601-tagged HD (and our untagged test clips, encoded with BT.601) shows a hue shift against
  the old RGB path (§3); full-range or BT.2020 streams too. Passing the tag on needs a media-kit/overlay field (e.g. a
  flag in `overlay_buffer` or the color space) — not done.

## 6. Merging (for the main session)

- `v1-overlay` fast-forwards `rpi4` (2753face8e); touched: the display driver and accelerant, the ffmpeg media
  plugin, MediaPlayer. No package, kernel or Mesa change. Apart from the revert pair, every commit stands alone.
- KNOWN-ISSUES: F2 loses "an overlay in the YCbCr422 format shows black" (not offered: no packed 4:2:2 on the display;
  B_YUV420 overlays work) and "MediaPlayer's video is RGB"; P2's MediaPlayer numbers become 25.8 % at 1080p30, 13.5 %
  at 720p30 (H.264), 23.6 % / 11.8 % (HEVC); "1080p60 24 fps shown" was a frame-rate bug (fixed in a9465e1c3f).
- Verified on the Pi: everything up to 4683784899 (sessions v1a, v1b); 6cda54a399 ran in v1b's MediaPlayer, but its
  branch (a frame that could not be read) was never taken anywhere; 92db783ffc not yet run (§4).
- One decision for the owner: a9465e1c3f makes 1080p60 H.264 play at its real rate, which MediaPlayer cannot keep
  up with on the VideoCore (drops most frames; before: slow motion, every frame). Correct timing (and A/V sync) is
  the reason to keep it; the frame-rate line can be reverted alone if smooth slow motion is preferred until
  MediaPlayer decodes ahead.
- Behaviour change for other media-kit users: none that asked for B_RGB32 or nothing (WebPositive, Firefox's FFmpeg
  path does not use the plugin); an app that asks for B_YUV420 now gets it (planar, the BBitmap layout) instead of
  B_RGB32; any renegotiation that changes only the output space or rows keeps the decoder.

## 7. V6: the stream's YCbCr encoding reaches the plane (2026-11-20; branch `v6-video`)

**Status: series A (the encoding, §7.2–7.3) merged into `rpi4` 552c42233d and released in image-2026-11-21**
(with Firefox -11 using it); series B (HEVC scanned out from rpivid's SAND pictures) and the rpivid pool are not
merged yet.

Open item of §5 (and KNOWN-ISSUES F2): the accelerant guessed the encoding (BT.709 from 720 lines, BT.601 below,
always limited range), so 601-tagged HD, full-range video and our untagged BT.601 test clips showed shifted hues.

### 7.1 What the firmware's plane does (probe, session `v6p1`, 07:10, **measured**)

`tools/haiku-tests/sandprobe enc CODE` shows a planar YUV420 picture (75 % bars in BT.709 limited range and a luma
ramp) on plane 6 with `color_encoding` = CODE; `tools/pi-tests/colour-probe.sh` takes an HDMI frame per code and
`colour-probe.py` fits each to BT.601/709/2020 × limited/full:

| `color_encoding` | Firmware name | Applied (best fit, mean error per channel) |
|---|---|---|
| 1 | ITUR_BT601 | BT.601 limited (2.1) |
| 2 | ITUR_BT709 | BT.709 limited (2.2) |
| 3 | JPEG_JFIF | **BT.601 full range** (2.9) |
| 9 | REC_2020 | close to BT.709 limited (1.8), not the BT.2020 matrix: probably BT.2020 plus a gamut map to the output; sent for BT.2020 as Linux does, not verified with a BT.2020 source |
| 0, 4–8, 10–12 | unspecified, FCC, SMPTE 240M, BT.470, JFIF Y16-255, … | all BT.709 limited (2.2): **the firmware default is BT.709**, not BT.601 as `vc_image_types.h` says |

No code gives full-range BT.709 or BT.2020 (Linux's firmware KMS says the same). The same session answered the SAND
question of gpu-stage6 §5 (`sandprobe layout 1-3`): see hw-video-decode.md §9.

### 7.2 Shape (upstreamable; default = the old guess)

| Layer | Change (haiku-pi/haiku `v6-video`) |
|---|---|
| public API | `overlay_options` gain `B_OVERLAY_YCbCr_BT601/_BT709/_BT2020` (a 2-bit matrix field, 0x00300000) and `B_OVERLAY_YCbCr_FULL_RANGE` (0x00400000) for `BView::SetViewOverlay()`; `media_video_display_info.flags` gain `B_YCbCr_BT601/_BT709/_BT2020` (0x30 field) and `B_YCbCr_FULL_RANGE` (0x40). No new struct field anywhere (overlay_buffer is returned by pointer by every accelerant) |
| app_server (f3243c7287) | the options become `overlay_window.flags` bits `B_OVERLAY_COLOR_*` (video_overlay.h); `SetFlags()` now runs **before** the configuration (it used to apply one `SetViewOverlay()` late) and replaces the encoding; a configuration the accelerant refuses removes the key and `SetViewOverlay()` returns the error (it returned B_OK for everything, and B_OK with no channel) |
| accelerant (274816191c) | flags → firmware code (1, 2, 3, 9); no matrix → the old guess; full-range BT.709/BT.2020 → `B_NOT_SUPPORTED`; the driver's plane statistics line names `image type N, encoding N` (the marker that the tag arrived) |
| ffmpeg plugin (9eaa066d36) | the reader fills the display flags from `codecpar` (the old `// TODO`); the decoder takes each picture's tags, else the reader's (h264_mmal's pictures have none), and sets them on B_YUV420 output; **swscale now gets the encoding** (`sws_setColorspaceDetails`): the RGB path converted everything as BT.601 limited before; untagged pictures get the same guess as the accelerant, so plane and RGB path agree; B_YUV420 output passes full range on only with BT.601 (the one full-range plane encoding) and converts other full-range pictures to limited range with an exact table (swscale 6.1 only copies between two 4:2:0 formats when the range changes) |
| MediaPlayer (552c42233d) | the decoder's display flags → `SetViewOverlay()` options |

### 7.3 Results (session `v6c1`, 07:21–07:40, image `v6-base` = rpi4 6a20a50380 + the branch's driver, accelerant, app_server, plugin and MediaPlayer, ffmpeg6 -7 + raspberrypi_userland -4 installed; **measured**)

Clips: `tools/media-tests/gen-colour-clips.sh` (pal75bars converted from RGB with the named matrix and range, tagged in
container and stream; 10 s). MediaPlayer, one HDMI frame 7 s after the start, bar centres found and read by
`tools/pi-tests/colour-bars.py` (9×9 means). **plane**: default (B_YUV420 overlay); **RGB**: `FFMPEG_YUV420=0`
(the plugin's swscale into B_RGB32, drawn by app_server). "vs ideal": largest channel difference from the clip's
source RGB (white 255, the others 191/0) — mostly the capture chain's own error (75 % reads 178–189, as in §3).

| Clip | Decoder | Plane encoding (driver line) | plane vs RGB path, max | plane vs ideal | RGB vs ideal |
|---|---|---|---|---|---|
| BT.601 SD 720×480 | h264_mmal | 1 | **0** | 9 | 9 |
| BT.709 HD 1080p | h264_mmal | 2 | **3** | 13 | 11 |
| BT.601-tagged HD 1080p | h264_mmal | 1 | **0** | 9 | 9 |
| BT.601 HD **untagged** | h264_mmal | 2 (guess) | 2 | 33 | 33 |
| full-range BT.601 HD | h264_mmal | 3 | **3** | 11 | 11 |
| full-range BT.601 SD (yuvj420p) | h264_mmal | 3 | **3** | 11 | 11 |
| full-range BT.709 HD | h264_mmal | 2 (converted to limited) | **3** (5 with swscale's range conversion: replaced by a table) | 13 | 11 |
| HEVC BT.709 1080p | hevc_rpivid | 2 | **3** | 13 | 11 |
| HEVC BT.601 720p | hevc_rpivid | 1 | **0** | 9 | 9 |
| HEVC Main 10 BT.709 1080p | hevc_rpivid | 2 | **3** | 11 | 13 |

- Every tagged clip is within ±3 of the RGB path, and both within the capture chain's error of the source.
- The untagged BT.601 HD clip still shows the shift (33 off the source) — on both paths now, since nothing can tell its
  encoding; that is the guess (BT.709 for HD), which real untagged HD video needs. Before this change the plane showed
  the same for the *tagged* 601 HD clip, and the RGB path was the one off for every HD clip.
- overlaytest (rgb32, yuv420 at 320×240): 240 flips each at 60.0/s, 0 failed, PASS on the new app_server. 0 debugger
  entries, 0 PANIC.

### 7.4 For Firefox (patches/firefox 0006, not rebuilt)

0006 declines the plane (`colour-space`) when `aInfo.color_space` is not the accelerant's guess
(`HaikuVideoOverlay`'s caller in `RenderCompositorSWGL`, ~line 481 of the patch). With this branch it can pass its
colour space instead and keep the plane: `Rec601Narrow` → `B_OVERLAY_YCbCr_BT601`, `Rec601Full` → `B_OVERLAY_YCbCr_BT601
| B_OVERLAY_YCbCr_FULL_RANGE`, `Rec709Narrow` → `B_OVERLAY_YCbCr_BT709`, `Rec2020Narrow` → `B_OVERLAY_YCbCr_BT2020`,
or'ed into the options of its `SetViewOverlay()` call (~line 845); `Rec709Full`/`Rec2020Full` stay declined (or are
tried: `SetViewOverlay()` now fails with B_NOT_SUPPORTED, which 0006 already treats as "no plane now"). Needs a Firefox
rebuild (~1 h, scripts/build-firefox.sh); not done here. The §9.7 M1 stream (untagged VP9 sub-720) would then go to the
plane with whatever Firefox assumed for it.

### 7.5 `ffmpeg -c:v h264_mmal` and 23.98 fps (§5): ffmpeg6 -8 patch 0007

mmaldec told the VideoCore 24000/1001 for every stream and copied the output port's echo of it into
`avctx->framerate`. Patch 0007 gives the input port the caller's rate when known and leaves `avctx->framerate` alone.
Measured on the Pi with the -7 and the -8 libavcodec side by side (session `v6s1`): the CLI's stream lines and a
transcode's result show the stream's rate with **both** (60 fps for `play-1080p60.mp4`, 30 for the 30-fps clips;
an Annex-B elementary stream: 25 fps / 120 tbr, the demuxer's guess, with both): the 23.98 of §5 did not reproduce
in these paths (it was seen through the plugin, which ignores a hardware decoder's rate since a9465e1c3f). The patch
removes the wrong value at the API level; nothing that used to work changed (`h264.sh play/seek/web` 0 problems).

## 8. V6: merging (for the main session)

**Merged 2026-11-21** (M1): series B as 8efdb08ecf and the V7 pool as fd21dfd821 on rpi4 (pushed, head 59a8080cce);
`patches/ffmpeg6-next` is folded into `patches/ffmpeg6` and ffmpeg6 6.1.6-8 is the image's (scripts/build-ffmpeg.sh, no
`--next` any more; package not yet published). Pi results on the integration image: W47 2026-11-21 06:19.

Branch `v6-video` of haiku-pi/haiku (from `rpi4` 6a20a50380), two series that merge separately:

| Series | Commits | Needs |
|---|---|---|
| A: the YCbCr encoding (§7) | f3243c7287 app_server, 274816191c bcm2711_display, 9eaa066d36 ffmpeg plugin, 552c42233d MediaPlayer | nothing new: works with ffmpeg6 -7 (the image's set); tested on the Pi (v6c1) |
| B: SAND zero copy (hw-video-decode.md §9) | 2c6cace0e0 rpivid, cdd1c52acb interface kit (public color spaces, BBitmap of client memory), 1ff1913b4c app_server (import), c6ad488cd8 bcm2711_display (import, SAND types), 317dcf80d5 ffmpeg plugin, 25b4611377 MediaPlayer | ffmpeg6 **-8** (`patches/ffmpeg6-next`, `artifacts/packages-test/ffmpeg6-8`) for the saving; with -7 everything works as before (tested) |

- B touches public headers (GraphicsDefs.h, Bitmap.h's private field, MediaDefs.h is A's), the accelerant hook list
  (video_overlay.h) and libbe: an image build, not a binary drop.
- ffmpeg6 -8 = -7 + 0006 (rpivid_out), 0007 (mmaldec rate) + the rpivid files of `patches/ffmpeg6-next`; to adopt it,
  move those into `patches/ffmpeg6` and bump the revision (scripts/build-ffmpeg.sh `--next` builds it today without
  touching the default -7 build or the shared sysroot).
- KNOWN-ISSUES F2 then loses "rpivid's HEVC frames are still converted from SAND on the CPU" and gains the low-memory
  fallback (hw-video-decode.md §9.4); P2's HEVC numbers become 4.4–6.5 % (1080p30), 5–6 % (Main 10), 3–4 % (720p).
- Firefox follow-up (§7.4): pass its colour space with `SetViewOverlay()` in 0006 instead of declining on a mismatch.
- Other overlay clients on the new app_server + libbe (session `v6s3`, 09:44–09:54): Firefox -10 `ffv-a1.sh measure`
  (720p H.264): 1279 frames on the plane, 7 dropped of 1339, the plane at image type 3 (as §9.7 of the Firefox doc);
  `glflip -w -n 1200 -i 1` (full-screen GL on a plane, the image's Mesa): 1200 frames in 20.000 s = 60.00 fps, 0 stalls,
  `602 updates in 602 vblanks, 0 gaps`. 0 debugger entries.

Re-test kit (kept): `artifacts/v6-video/v6-base.img` (rpi4 6a20a50380 built in the worktree before any change),
`artifacts/v6-video/stage/` (the branch's binaries), `artifacts/v6-video/bin/` (clips, tools, ffmpeg6 -7/-8 and
userland -4 packages); `tools/pi-tests/v6-session.sh start LABEL` boots it with the binaries in non-packaged. The
worktree's build directory was deleted (4 GB); to recreate it:

```sh
cd sources/haiku-v6 && mkdir generated.arm64 && cd generated.arm64
../configure --cross-tools-prefix $PWD/../../haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-
cp -al ../../haiku/generated.arm64/download download && cd ../../..
HEAVY_BUILD_LOCK=... scripts/build.sh --generated sources/haiku-v6/generated.arm64 @pi-mmc     # first: everything
scripts/build.sh --generated sources/haiku-v6/generated.arm64 --light libbe.so app_server \
  bcm2711_display.accelerant bcm2711_display rpivid ffmpeg MediaPlayer                         # then: the changed parts
V6_SAND=1 tools/pi-tests/v6-session.sh stage
```

## 9. V7 (2026-11-20): Firefox passes its encoding; BT.2020 on the plane is off; 4K on the plane

- **Firefox** (patches/firefox 0006, firefox 157.0.1-11 test package): §7.4 done — `RenderCompositorSWGL` maps
  `Rec601Narrow`/`Rec601Full`/`Rec709Narrow` to the `B_OVERLAY_YCbCr_*` options of every `SetViewOverlay()` call and no
  longer compares with the accelerant's guess. Results in firefox-video-overlay.md §9.8.
- **BT.2020 is not right on the plane (measured, session `v7a`):** a VP9 1280×720 clip of the colour bars converted
  with the BT.2020 matrix (gen-colour-clips.sh `col-2020-vp9.webm`), shown by Firefox on the plane as `color_encoding`
  9 (the driver line says `encoding 9`), is **up to 11 off** Firefox's software path (cyan 0,179,180 against 1,188,182;
  magenta 190,5,182 against 180,1,182), and the software path is the one within the capture's error of the source.
  That fits the probe of §7.1 (code 9 behaves close to BT.709 plus something; not the BT.2020 matrix). So Firefox -11
  keeps BT.2020 in software. **MediaPlayer with series A still sends BT.2020 as code 9** (not measured with
  MediaPlayer: no BT.2020 clip was played there); the accelerant should probably refuse `B_OVERLAY_YCbCr_BT2020`
  (B_NOT_SUPPORTED) so that the plugin converts. Not changed here (series A is in the gate).
- **4K on the plane**: 4K HEVC now plays on the SAND plane (hw-video-decode.md §10): the rpivid scan-out pool and
  MediaPlayer's smaller overlay probe. `overlaytest -s sand|yuv420 -x 3840x2160` pass (the display scales 4K
  overlays down to the 1920×1080 mode).

## 10. MP1 (2026-11-21): MediaPlayer's full-screen toggle moves the plane (branch `mp1-fullscreen-overlay`, not merged)

Symptom (KNOWN-ISSUES F2's last sentence, seen on rpi4 and the S1 branch): MediaPlayer switched to full screen after
its clip had ended shows the picture where the window was and paints the rest of the screen dark green, the key
colour `{0, 80, 0}`.

### 10.1 Cause (two parts; the symptoms **measured** in session `mp1before`, the paths from reading the code)

1. **The plane does not move without a new frame.** `MainWin::_ToggleFullscreen()` moves and resizes the window;
   `FrameResized()` → `_ResizeVideoView()` moves and resizes the `B_FOLLOW_NONE` VideoView (`AS_VIEW_MOVE_TO`/
   `AS_VIEW_RESIZE_TO`: app_server moves the view's bitmap rectangle but never reconfigures its overlay; only a
   window move/resize and show/hide do) and calls `VideoView::SetVideoFrame()`, which only invalidated. The overlay
   was put into `fVideoFrame` by `SetBitmap()`, i.e. by the next video frame. Paused or ended, none comes: the plane
   stays at the old place and scale while `Draw()` fills the new frame with the key colour. Back from full screen the
   same: the window shows a crop of the full-screen-scaled picture (before/end-col-601-hevc-3back-hdmi.png).
2. **Key pixels written before the plane got there stay opaque.** With keying (gpu-stage6.md, `HWInterface::
   _ShowOverlayKey()`), the frame buffer is blended over the plane, and a key pixel is transparent only if it is
   written while it lies inside a configured overlay rectangle. `SetViewOverlay(… B_OVERLAY_TRANSFER_CHANNEL)` (each
   new frame) did not invalidate the view. So **during playback** too, when `Draw()` ran before the next frame moved
   the plane, the new frame's key stayed opaque green: H.264 854×480 playing, toggled to full screen, 1.48 M green
   pixels 2 s later with the plane already full-screen behind them (only the old window rectangle and a strip
   repainted later let it through: before/play-play-854x480-2full-hdmi.png). HEVC 720p playing happened to win the race
   (0 green).

### 10.2 Change (haiku-pi/haiku `mp1-fullscreen-overlay`, on `rpi4` 4edd36b41a)

| Commit | Change |
|---|---|
| b7eb4b0084 MediaPlayer | `SetVideoFrame()` → `_MoveOverlay()`: in overlay mode with a bitmap shown (under the bitmap lock; the consumer sets the bitmap to NULL before it deletes one, imported SAND pictures included), `SetViewOverlay()` with the same bitmap, the new frame and `B_OVERLAY_TRANSFER_CHANNEL` (app_server: `TakeOverToken()` of itself is a no-op, `Configure()` moves the plane), then `Invalidate(fVideoFrame)`: the key is drawn after the plane is there |
| f814da3263 MediaPlayer | the `ToggleFullscreen` scripting command replied `B_BAD_SCRIPT_SYNTAX` although it toggled (`hey` printed an error; test scripts must ignore it on older images) |
| d0531402e0 app_server | `AS_VIEW_SET_VIEW_BITMAP`: a transfer that changes the overlay's rectangle invalidates the view, as the first `SetViewOverlay()` does (generic: any client moving its overlay with its next frame; MediaPlayer's own invalidate makes it redundant there). A transfer to the same rectangle (every frame) does not. **Not shown to fix anything yet**: every case below was already fixed by b7eb4b0084 (§10.4) |

Not changed: app_server still does not reconfigure an overlay when its view is moved or resized by the client
(`AS_VIEW_MOVE_TO`/`RESIZE_TO`). Doing it there alone would not fix MediaPlayer (the `B_FOLLOW_ALL`-grown rectangle
is not the letterboxed video frame for a 3:2 clip), and it would add two plane configurations at a wrong rectangle per
toggle; left as a possible upstream improvement.

### 10.3 Pi results (network sessions, the card untouched, 0 PANIC / debugger entries; **measured**)

`tools/pi-tests/mp1-fullscreen.sh` (MediaPlayer per case, HDMI snapshot + screenshot per state) and
`tools/pi-tests/key-census.py` (key-colour pixels in the HDMI snapshot; where the colour bars are). Images: before =
`haiku-pi4-integ-1121.img` (rpi4 59a8080cce, one commit before the branch's base: S1's screenshot read-back missing,
nothing else in this path), session `mp1before` 08:31–08:35; MediaPlayer fix only (b7eb4b0084 image), `mp1after`
08:44–08:47; the whole branch (d0531402e0 tree), `mp1final` 08:56–09:03. Clips: col-601-sd (H.264 720×480, 3:2,
`B_YUV420` plane, h264_mmal), col-601-hevc (HEVC 1280×720, SAND plane zero copy, image type 19), play-854x480 (H.264),
play-hevc-720p30.

Key-colour pixels in full screen (HDMI; a window baseline is 21–80: window decorations and controls):

| Case | before | MediaPlayer fix | whole branch |
|---|---|---|---|
| H.264 3:2, ended → full | 1 326 998 | 38 | 38 |
| HEVC SAND, ended → full | 975 388 | 38 | 38 |
| H.264 3:2, paused → full | 1 326 998 | 38 | 38 |
| H.264 854×480, paused → full | 1 486 620 | 42 | 42 |
| HEVC 720p, paused → full | 974 727 | 39 | 41 |
| H.264 854×480, playing → full | 1 482 710 | 11 | 12, 10 |
| HEVC 720p, playing → full | 0 | 1 | 1, 1 |

- Full screen: the bars fill the letterboxed frame (3:2 clip: x 150–1769 on the 1920×1080 mode; the census box of the
  coloured bars 354–1565 = the white and black bars excluded, as computed); before, the picture stayed at the
  window's place (151,22–629,501) at the window's scale.
- Back to the window (ended and paused cases, the ones with a snapshot before the toggle): identical to the window
  before the toggle after the fix (same key and bar counts); before, the window showed a crop of the full-screen-scaled
  picture. Playing cases: the window back with 23–45 key pixels (the window baseline range).
- Second tool: S1's screenshot read-back (branch images only) — 0–13 key pixels in every full-screen screenshot, the
  bars where HDMI has them (after-mp/ and after-final/census-shots.txt). The before image has no read-back (its screenshots show
  the key where the plane is: 1.3–1.5 M).
- Regression check of the app_server change (`video-overlay.sh play`, session `mp1final`): H.264 720p30 13.4–14.4 %
  of one CPU (M1: 13.7–14.9 %), HEVC 720p 2.9 % (M1: 3.0 %), 0 dropped. One of three H.264 plays had nearly every
  plane update "late" (296 of 302), the other two 0–1; one HEVC play of the full-screen cases 141–164 late per 10 s, the
  next 0. Such streaks (more than half of a play's updates late, the next play none) are older than this branch:
  sessions `r1g` (image-2026-11-21's gate: 297 of 302), `m1-integ` (the before image: 285 of 301), `v8rate` (296 of
  302), v1a, v6c1, v7b — a phase effect between 30 fps and the 60 Hz vblank, not caused by the change (by the code, it
  adds no invalidation per frame; not measured separately).

Outputs: `artifacts/mp1/{before,after-mp,after-final}/` (census.txt, *-hdmi.png, *-shot.png, MediaPlayer log lines;
after-final/vov-play.txt). UART: `artifacts/uart/20261121-08*-session-mp1{before,after,final}.log`. The test images
and the worktree's build directory were deleted after the runs (rebuild: §8's recipe with `sources/haiku-mp1`).

### 10.4 Merging

- **Merge up to f814da3263** (the two MediaPlayer commits; a fast-forward of rpi4 4edd36b41a today): session `mp1after`
  (b7eb4b0084 alone) shows the whole fix, and `hey … ToggleFullscreen` answers rc 0 on the final image.
- **d0531402e0 (app_server) not recommended yet**: nothing here exercises it positively, and Firefox, which calls
  `SetViewOverlay()` per frame, has not run with it (a rectangle that changes during a scroll or resize now invalidates
  the view each time). It needs an image with it and the old MediaPlayer, playing → full screen with play-854x480
  (expected ~0 key pixels where rpi4 had 1.48 M; paused/ended still green there), and one Firefox video run.
- With the next release: drop the sentence from KNOWN-ISSUES F2 and add a HAIKU-RPI4-CHANGES line (MediaPlayer).

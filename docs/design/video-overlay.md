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

## 4. Still to run (the bench went to other agents; 2026-11-18 19:45)

The image of 4683784899 is built (`sources/haiku-v1-overlay/generated.arm64/haiku-pi4-regular.img`, hrev of `rpi4`
2753face8e + the branch; rebuild with `scripts/build.sh --generated sources/haiku-v1-overlay/generated.arm64
-sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=4500 @pi-mmc` after configuring that directory as in gl-client-pointer.md §7).
Two short sessions (~10 min each):

```sh
F="artifacts/v1-overlay/overlaytest artifacts/v1-overlay/teamstat artifacts/v1-overlay/vdecode tools/pi-tests/video-overlay.sh \
   artifacts/media-tests/h264/play-720p30.mp4 artifacts/media-tests/h264/play-1080p30.mp4 artifacts/media-tests/h264/play-1080p60.mp4 \
   artifacts/v1-overlay/clips/play-hevc-720p30.mp4 artifacts/v1-overlay/clips/play-hevc-1080p30.mp4 artifacts/v1-overlay/clips/play-hevc10-1080p30.mp4"
# after: the fixes (1080p60 at 60 fps, 10-bit HEVC through B_YUV420), overlaytest at 1080p (BT.709)
scripts/pi-session.sh start --image sources/haiku-v1-overlay/generated.arm64/haiku-pi4-regular.img --minutes 20 --label v1b
scripts/pi-ssh.sh "mkdir -p /boot/home/h264" && scripts/pi-ssh.sh put $F /boot/home/h264/
scripts/pi-ssh.sh "cd /boot/home/h264 && sh video-overlay.sh play after && sh video-overlay.sh ovl"   # HDMI: hdmi_snap during ovl
scripts/pi-session.sh stop
# before: the release image, same clips and script (overlaytest's B_YUV420 layout differs there: no ovl)
scripts/pi-session.sh start --image artifacts/images/haiku-pi4-2026-11-18.img --minutes 15 --label v1-before
scripts/pi-ssh.sh "mkdir -p /boot/home/h264" && scripts/pi-ssh.sh put $F /boot/home/h264/
scripts/pi-ssh.sh "cd /boot/home/h264 && sh video-overlay.sh play before"
scripts/pi-session.sh stop
```

Expected after: `play-1080p60` 600 updates per 10 s (it was 240), `play-hevc10-1080p30` with `video output B_YUV420
(hevc_rpivid yuv420p10le …)` and far fewer drops; the other rows as in §3.

QEMU virt (2026-11-18 18:10, the image at 4683784899 with a test bootscript; no VideoCore, no overlays): MediaPlayer
on `play-720p30.mp4` and `play-854x480.mp4` takes `preferred color space: B_YUV420`, the gate turns it into B_RGB32
(no YUV output line, no renegotiation), `h264_mmal failed (does not open): h264 continues from the start`, 0 dropped,
0 PANIC; `vdecode` (software h264): B_YUV420 98.7 frames/s at 330 % CPU vs B_RGB32 53.7 frames/s at 264 % (QEMU's
emulated CPU: only the ratio means anything).

## 5. Open

- **One copy is left before the consumer's**: mmaldec copies the VideoCore's buffer into an AVFrame (3 MB at 1080p);
  avoiding it means handing the MMAL buffer out as the frame (mmaldec does that only for its opaque format) with
  only 3 output buffers in the VideoCore's memory. rpivid: its SAND → planar conversion on the CPU stays (the SAND
  plane of `gpu-stage6.md` §5 is still design only).
- **Mode change** while a video overlay is shown (F2): not touched; still black until the overlay is shown again.
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
- Behaviour change for other media-kit users: none that asked for B_RGB32 or nothing (WebPositive, Firefox's FFmpeg
  path does not use the plugin); an app that asks for B_YUV420 now gets it (planar, the BBitmap layout) instead of
  B_RGB32; any renegotiation that changes only the output space or rows keeps the decoder.

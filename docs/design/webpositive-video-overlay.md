# WebPositive `<video>` on the YUV overlay plane (WP1)

Status: **published as haikuwebkit 1.10.0-2** (2026-11-22, WP2: full GCC 16.2 build, Pi checks §3.2; in the image list from haiku rpi `86e23ad36a`). Measured first on a test build (2026-11-22, sessions `wp1a`, `wp1b`, §3). A change to HaikuWebKit's media player
(`patches/haikuwebkit/haikuwebkit-1.10.0-video-overlay.patch`). Numbers are
marked **measured** (with the source) or **estimated**. Builds on [video-overlay.md](video-overlay.md) (B_YUV420
overlays, colour encodings §7, MediaPlayer's full-screen fix §10) and
[firefox-video-overlay.md](firefox-video-overlay.md) (A1: key fill; A1b: no window drawing while only the video
changes; 0008: translucent content keeps the video in software).

Citation key: **[W]** `artifacts/cross-ports/haikuwebkit-1.10.0/src/Source` (HaikuWebKit 1.10.0 +
`patches/haikuwebkit`, as `scripts/build-webkit.sh webkit_source` leaves it).

## 0. Answer in one screen

1. **No compositor rework is needed: the cheap shape (a) fits in the media player.** The Haiku port of WebKitLegacy
   has no accelerated compositing (`USE_TEXTURE_MAPPER` off, [W] `cmake/OptionsHaiku.cmake:196`); a video frame is
   drawn by `MediaPlayerPrivate::paint()` straight into BWebView's offscreen view, like any other content. So the
   change is: decode B_YUV420, put the picture on an overlay plane of the BWebView, and paint the overlay key where
   the video is. One file in WebCore (+~650 lines) and two small hooks in WebKitLegacy's `WebPage.cpp`. The stop rule did not apply.
2. **Today's path (§1)**: the ffmpeg plugin converts every picture to B_RGB32 (swscale's C path) into a BBitmap,
   the video thread asks WebCore to repaint the video's rectangle, `paint()` `DrawBitmap()`s the picture into the
   page's offscreen bitmap (app_server scales and copies it), and BWebView's `Draw()` copies the rectangle to the
   window (app_server: into the back buffer, then the front buffer). Four rectangle-sized passes per frame, one with
   colour maths, plus WebCore's paint of the rectangle (background, the video, controls).
3. **With the plane (§2)**: the plugin copies the decoder's planes into the player's B_YUV420 buffer; the video
   thread copies that into an overlay bitmap and flips it with `SetViewOverlay(… B_OVERLAY_TRANSFER_CHANNEL)` and
   the stream's YCbCr encoding. **No repaint of the page per frame** (Firefox's A1b, here for free: the video
   thread is what asked for the repaints). `paint()` is only called when something else changed; it then fills the
   rectangle with the key (exactly the plane's pixels), or draws the picture in software (converted by the player)
   while the plane cannot be used for it.
4. **SAND (hevc_rpivid zero copy) is not used**: WebKit asks for planar B_YUV420, which the plugin makes from rpivid's
   SAND pictures on the CPU (as before V6 series B). Importing the decoder's pictures (MediaPlayer's path,
   hw-video-decode.md §9) is a follow-up.
5. **Build**: the HaikuWebKit tree was compiled by GCC 13.3 in October and its dependencies are no longer in the
   sysroot; a plain `ninja` would rebuild everything (hours). `scripts/webkit-relink.sh` compiles only the changed
   files with today's GCC 16.2 and relinks `libWebKitLegacy.so`: **the test library is a mixed 13.3/16.2 link**,
   good for measurements; publishing needs a full `scripts/build-webkit.sh` rebuild (§5).

## 1. How HaikuWebKit plays `<video>` (analysis, 2026-11-22)

| Step | Where | Today |
|---|---|---|
| open | [W] `WebCore/platform/graphics/haiku/MediaPlayerPrivateHaiku.cpp` `IdentifyTracks()` (loader thread) | `BMediaFile(BUrl)`; per track `DecodedFormat()` with a wildcard format: the ffmpeg plugin answers B_RGB32 for video; a B_RGB32 `BBitmap` of the video's size |
| decode | `videoThread()` | when the video's time is behind the audio's (or the system clock's): `ReadFrames()` into the bitmap's bits, then `callOnMainThread(repaint)` |
| paint | `paint()` (main thread, from `RenderVideo::paintReplaced` through `BWebPage::paint()`) | `DrawBitmap(m_frameBuffer, rect)` into the offscreen view (`BWebView::OffscreenView()`, a BView in a B_RGB32 BBitmap) |
| show | [W] `WebKitLegacy/haiku/API/WebView.cpp` `Draw()` | `DrawBitmap(offscreen, rect, rect)` into the window |

- WebCore's paint thread holds the offscreen bitmap's lock while painting (`BWebPage::paint()`), and `BWebView::Draw()`
  (window thread, window locked) takes the same lock: **a window lock taken inside `paint()` could deadlock**, so the
  overlay calls are made from the video thread (window lock with a timeout, no other lock held).
- Scrolling is a blit inside the offscreen bitmap (`BWebPage::scroll()`, `CopyBits`), not a repaint: key pixels would
  move without the plane. Hence the hook (§2).
- No full-screen API (`ENABLE_FULLSCREEN_API` off): "full screen" is WebPositive's own full-screen window (F11), a
  relayout and repaint like a window resize.
- `MediaPlayerPrivate::seekToTarget()` fell off its end without returning the promise (undefined behaviour; GCC 16
  warns): fixed on the way.
- KNOWN-ISSUES P2: WebPositive takes the RGB32 path, which at 1080p60 shows ~1 frame in 3 (CPU-bound conversion).
- KNOWN-ISSUES F11 (a crash at quit, `ReadFrames` from the video thread): nothing stops the players when the
  application quits; their threads decode on while the add-ons are unloaded. Reproduced on the bench (§3), fixed here (§4).

## 2. Change (shape (a): the plane, the key, software fallback)

`patches/haikuwebkit/haikuwebkit-1.10.0-video-overlay.patch`:

- `IdentifyTracks()`: when the screen has B_YUV420 overlays (`bitmaps_support_space`) and `WEBKIT_VIDEO_OVERLAY` is not
  `0`, asks the track for B_YUV420; takes it only if the plugin gives B_YUV420 (4:2:0 pictures of an even size) and
  not BT.2020 (the plane is wrong for it, video-overlay.md §9); else B_RGB32 as before. The decoder writes into a
  plain buffer.
- Video thread (`serviceOverlay()`, after each loop, paused too): a new picture goes to the plane (3 overlay
  bitmaps, the first reserving the channel; `SetViewOverlay(… B_OVERLAY_TRANSFER_CHANNEL | encoding)`) when the
  plane is where the video was last painted; no repaint. Otherwise the plane is (re)configured at the rectangle of
  the last two paints, and then one repaint puts the key there; or the picture is repainted in software.
- `paint()`: maps the rectangle to the view (`TransformTo(B_VIEW_COORDINATES)`, translation and scale only, wholly in
  the view, only into the page's offscreen view); fills exactly the plane's pixels with the key when the plane is
  there and the paint was asked for by the video thread; else draws the picture, converted from B_YUV420 by the
  player (the stream's matrix and range). A paint not asked for by the video thread over the plane means other
  content changed there (the media controls, a hover): software for 1.5 s, extended while it goes on (0008's rule).
- `paintCurrentFrameInContext()` (canvas `drawImage`, snapshots): always the picture.
- `BWebPage::scroll()` calls `mediaPlayerHaikuRootViewScrolled()`: software for 0.5 s and a repaint; the plane follows
  once the video is painted twice at its new place. Not painted for 2 s (scrolled out, hidden): the plane is given
  back; a hidden BWebView (another tab) gives it back at the next picture.
- One plane per view: a BView has one overlay, so the first video of a page to claim the BWebView's plane keeps it;
  other videos on the page stay in software (`planeLock()`, the claim given back with the plane).
- Fallbacks: no plane (allocation fails, all six in use), `LockBits()` failing (overlays suspended for a mode
  change), `SetViewOverlay()` failing: software, a retry after 1 s.
- Quit: `BWebPage::ShutdownOnce()` calls `mediaPlayerHaikuShutdown()`: every player stops decoding, gives its plane back
  and closes its file; a static destructor stops the decoding for applications that do not call it (§4).
- `WEBKIT_VIDEO_OVERLAY_LOG=1`: a `WVO` line every 2 s (decoded, late, plane frames, shows/moves/hides, software
  repaints, conversions and their time, foreign paints, scrolls); `=2` also each show, move, release and scroll.

## 3. Pi results (network session `wp1a`, 2026-11-22 04:12–05:05, image-2026-11-21b, the card untouched; **measured**)

Setup: the release image's WebKit ("baseline", `haikuwebkit 1.10.0-1`) against the test library
(`artifacts/wp1/t1/libWebKitLegacy.so.1.10.0`, loaded through `LIBRARY_PATH` by `tools/pi-tests/wp1-video.sh`; the same
binary with `WEBKIT_VIDEO_OVERLAY=0` is "RGB"). `tools/pi-tests/wp1-run.sh` drives each run from the host and takes the
HDMI frames; the key census is `tools/pi-tests/key-census.py` (a window baseline is 47–80 key-like pixels: decorations and
the toolbar). Page: the clip muted, looped, filling a 1600×900 WebPositive window (letterboxed: the plane at 1378×775,
scaled by the display). CPU = `teamstat` over 10 s from 20 s after the start, % of one core; "system" = of all 4 cores.

| Clip (decoder) | Baseline: WebPositive / app_server / system | **Plane**: WebPositive / app_server / system | Plane updates per 10 s |
|---|---|---|---|
| H.264 720p30 (h264_mmal) | 27.2 / 101.5 / 33.3 | **15.4 / 0.6 / 5.1** | 300–301 of 300 |
| H.264 1080p30 (h264_mmal) | 44.7 / 101.8 / 38.3 (RGB: 46.2 / 102.5 / 38.8) | **28.6 / 0.6 / 8.9** | 300–301 |
| H.264 1080p60 (CPU decoder, by rate) | 179.4 / 64.8 / 61.9 (RGB: 179.1 / 65.4 / 62.0) | **162.2 / 0.8 / 41.5** | 600–601 updates in 600 vblanks, 16–166 of them superseded: **435–585 of 600 frames shown** |
| HEVC 720p30 (rpivid) | 19.6 / 101.1 / 30.9 | **12.0 / 0.8 / 4.1** | 301 |
| HEVC 1080p30 (rpivid) | 35.3 / 101.7 / 35.0 | **24.2 / 0.5 / 6.9** | 300–301 |

- **app_server drops from a whole core to <1 %**, the system from 31–39 % to 4–9 % busy at 30 fps; WebPositive itself
  saves the swscale conversion (720p −12 points, 1080p −16). Repeat runs on intermediate builds: 14.2–15.5 % (720p), 28.6 %
  (1080p30), 162.0–164.7 % (1080p60).
- **1080p60**: not every frame is shown. The plane is updated at every vblank, but 16–166 of the ~600 updates per 10 s
  were replaced by the next one before scan-out (two frames in one vblank: 3 runs gave 16, 28 and 166), so 435–585 of 600
  frames reached the screen. The player decodes all frames (1785 in ~30 s), 63–125 of them more than 1.5 frame periods
  late (RGB path: 376). The rest of the CPU is the software H.264 decoder (by rate, KNOWN-ISSUES P2). The baseline's
  shown frames were not measured (no counter in the old library; P2 says ~1 in 3 for the RGB path); its app_server at
  65 % and 376 late decodes say it does not keep up.
- **HEVC plays only from a "faststart" MP4**: WebKit opens media through `BMediaFile(BUrl)` (a streaming reader); our
  x265 clips have the `moov` atom at the end ("moov atom not found", nothing played, baseline as well). Remuxed with
  `-movflags +faststart` (`artifacts/wp1/clips/`) they play, baseline and plane. Most web MP4s are faststart.
- **Correctness** (HDMI frames, `artifacts/wp1/runs/*.png`): no key colour above the window baseline in any run (47–76);
  the picture where the video is. Content over the video (`controls`: a translucent bar with text changing 4×/s and an
  opaque square for 12 s): drawn over the picture, no green (the bar renders opaque black in this WebKit, baseline
  too), the video in software meanwhile (`foreign` 39 paints, 454 software frames), back on the plane after. The real
  media controls never appeared, baseline included: uiinject's mouse moves do not make WebKit show them; not checked
  by hand.
- **Scrolling** (`scroll`: 640×360 video, 2 px per 50 ms for 2 s): software during the scroll (80 scroll hooks), the
  plane moved twice after each glide; key census 47–76 in still and mid-scroll frames. The first build released the
  plane at the first scroll (a stale paint time: on the plane nothing repaints) and left transparent pixels black for
  seconds: fixed (§4).
- **Full screen**: uiinject's F11 does not reach WebPositive; the window resized to the whole screen and back instead
  (the same relayout): the plane moved to 1698×955 and back, 0 key, WebPositive 36.7 % in the full-screen period
  (1080p30; app_server 2.2 %).
- **Seek while paused** (JavaScript `currentTime` to 5 s and 20 s, then play; session wp1b, burnt-in frame numbers):
  baseline and the relinked control stay on the paused frame (351/350) and **never play again** (the 26-s frame still
  shows 350): their `seekToTarget()` returns no promise. With the patch the seek completes and playback resumes, but
  both seeks land on frame 0 (resumed at 2.7 s / 3.2 s after ~3 s), with `WEBKIT_VIDEO_OVERLAY=0` exactly as on the
  plane, so it is the `seekToTarget()` fix, not the plane. The clip has key frames every ~2 s, so a backward seek should
  land at 3.7 s; the cause (probably `SeekToTime()` through the `BMediaFile(BUrl)` streaming reader) is not proven.
  Better than a frozen video, still wrong: a follow-up.
- **Quit during playback** (KNOWN-ISSUES F11): baseline **crashed at 5 of 8 quits** (`cycle`, 1080p30) and at 5 of its 9
  other quits with a video playing: `ReadFrames()` in unloaded decoder code. Intermediate test builds crashed in
  `BBitmap::LockBits()` (a plane frame after the application was gone) and, with the decoding stopped, in h264_mmal's
  own threads after the add-on was unloaded (2 of 6). Final library: **0 of 12** (8 cycle quits, 4 measure runs; 1080p60
  quits take 8 s on both libraries).
- Mixed-compiler control: the unchanged sources relinked with GCC 16.2 (`artifacts/wp1/control`) played 720p and quit
  with the baseline's crash, but at another window size (not comparable numbers). The like-for-like check of the
  relinked library is the RGB column: `WEBKIT_VIDEO_OVERLAY=0` on the test library gives 46.2 / 102.5 % at 1080p30 against
  the baseline's 44.7 / 101.8 %, 179.1 / 65.4 % against 179.4 / 64.8 % at 1080p60.
- 0 PANIC in the session.

### 3.1 Session wp1b (06:03–06:13, same image, 0 PANIC): two videos, a hidden tab, a mode change, the package

- **Two videos in one page** (H.264 720p and HEVC 720p, 760×428 each): the first test library had nothing to stop both
  players from configuring the BWebView's one overlay: **325 134 key pixels** on HDMI (`TW1b`; the plane jumped between
  the two rectangles, the other one green). Fixed: a player claims its view's plane (`planeLock()`), the others stay in
  software (`other 20` retries in the log): `TW2b` **79** key pixels (window baseline), the HEVC video on the plane, the
  H.264 one drawn by app_server (75 % of a core: the old cost, for the second video only).
- **Hidden tab** (`window.open()` in front for 12 s): the plane was given back at the next picture (the display driver's
  plane statistics stop), no video and no key on the other tab, the plane back when the tab closed; 0 debugger entries.
- **Mode change** (1280×720 and back while playing 1080p30): one `LockBits()` failure while the overlays were suspended,
  software for a second, then the plane again in both modes; key 26–61, 0 debugger entries.
- **The test package installed with pkgman** (`haikuwebkit-1.10.0-2`, its requirements met: `gcc_syslibs` provides
  `lib:libgcc_s`): WebPositive 26.0 %, app_server 0.6 %, system 8.1 % at 1080p30 (300–301 plane updates per 10 s); 6 of 6
  quits clean.
- **The translucent bar** (`rgba(0,0,0,0.5)`) renders neutral opaque black in this WebKit on both libraries (pixels (0,0,0)
  inside it, `OVB` baseline and `OV720`): not green-tinted, but this page does not show what a truly translucent pixel
  over the key would do; the software fallback while the content changes is what covers that case.
- The image's `/boot/system/non-packaged/lib/libmedia.so` (seen in the crash traces) is byte-identical to the packaged
  `/boot/system/lib/libmedia.so` (same MD5): the baseline is the release as published.

Not run: a canvas `drawImage()` of a video, the real media controls (they never appear for injected mouse events).

### 3.2 WP2: the published package (full GCC 16.2 build; session wp2b 07:29–07:53, image-2026-11-21b, 0 PANIC, card untouched)

- Build: `scripts/build-webkit.sh` from a fresh tree with both patches (the patched files identical to WP1's), against
  a private sysroot (`artifacts/sysroot-webkit`: the shared one plus the published dependencies staged as the library
  steps leave them; the CMake cache's library, include, `ENABLE_*` and `USE_*` entries identical to October's). ninja
  06:23–07:27 (64 min, 8 jobs), 1552 warnings: 1328 of them GCC 16's new `-Wsfinae-incomplete`, the other classes as
  October's (WP1's `seekToTarget()` `-Wreturn-type` gone). `.comment` of libWebKitLegacy, libJavaScriptCore and jsc:
  GCC 16.2.0 only.
- `package-diff.sh` against 1.10.0-1: runtime `+requires lib:libgcc_s` (from `gcc_syslibs`, as the test package), same 9
  files; `_devel` the same 24 files, its requirement moved to `haikuwebkit == 1.10.0-2`.
- Installed with `pkgman install` (the two files), MD5 of `/boot/system/lib/libWebKitLegacy.so.1` = the package's, and
  `listimage` of a running WebPositive maps it from `/boot/system/lib` (no `LIBRARY_PATH`). Runs `artifacts/wp1/runs/W*`:

| Clip | WebPositive / app_server / system | Plane |
|---|---|---|
| H.264 720p30 | 14.6 / 0.7 / 4.9 % | 301 of 300 updates per 10 s |
| H.264 1080p30 | 26.1 / 0.7 / 8.2 % | 300 |
| H.264 1080p60 (3 runs) | 158.7–164.9 / 0.7–0.8 / 40.5–42.3 % | 600–601 updates in 600 vblanks, 7 / 87 / 231 superseded: **370–594 of 600 shown** (WP1: 435–585) |
| HEVC 1080p30 faststart | 24.3 / 0.5 / 6.9 % | 300 |
| HEVC 720p30 faststart | 12.3 / 0.5 / 3.9 % | 300–301 |

- CPU within WP1's spread on every clip (§3: 15.4 / 28.6 / 162.2 / 24.2 / 12.0 % for WebPositive). 1080p60's shown frames
  swing widely within each build (the worst run here 370 of 600 against WP1's lowest 435; late decodes 73–334 against WP1's
  63–125): three runs per build cannot tell noise from a build effect. Key census of the 20 HDMI
  frames with the window at 1920×1080: 47–91 key-like pixels (window baseline and the test pattern's green bars; no key
  area; the 1280×720 frame 20, two frames taken after the quit 7); scroll (80 scroll hooks,
  plane moved twice), controls (40 foreign paints, back on the plane; the real media controls still never appear: uiinject's mouse
  moves reach the window's focus view, not the page), two videos (H.264 + HEVC 720p: the first on the
  plane, the other in software, `other 20`; key 60), hidden tab (the frame with the other tab in front: no video, no key; the plane given back and shown again by the
  counters, `hides 1 shows 2` — the frame meant for after the tab closed was taken after the quit), mode change
  1280×720 and back (one suspended-overlay fallback, plane again): as in §3/§3.1.
- **Quits during playback: 32, 0 crashes** — 20 in `cycle` runs (8 × H.264 1080p30, 8 × 720p30, 4 × HEVC 1080p30), 12 at the
  end of the other runs; 0 debugger entries in the whole session's syslog. 1080p60 quits take 8 s, as before.
- Browsing (`tools/pi-tests/wp2-browse.sh`, `wp2-run.sh`): en.wikipedia.org, www.haiku-os.org, github.com/haiku/haiku and
  DuckDuckGo's HTML search render (page titles right; Wikipedia's frame matches the 1.10.0-1 baseline's except the
  Deskbar); typing into a page's text field (`typed: Hello Haiku 2026` in the title) and an address typed into the URL field
  + Return (example.com loaded) work. `jsc` loop: 3.5 s with the JIT, 68.7 s with `JSC_useJIT=false`.

## 4. Defects found on the bench and fixed in the patch

0. Two videos in one page fought over the view's one overlay (§3.1): a claim per view, the others in software.
1. `ClearViewOverlay()` on the BWebView after it left its window (quit) → `debugger("View method requires owner")`:
   a view without a window is treated as gone.
2. Software after a scroll released the plane at once (the last paint was ~10 s old: nothing repaints on the plane), and
   the key pixels app_server had made transparent stayed black: the release now counts from the start of the software
   period and repaints after it.
3. Quit (F11, also in the baseline): the video thread decoded on while the application and the decoder add-ons were torn
   down. `BWebPage::ShutdownOnce()` (WebPositive calls it in `QuitRequested()`) now stops every player, frees its plane and
   closes its file (that stops h264_mmal's threads); this library's destructors do the decoding part for other apps.

## 5. Build, package, merge recommendation

- `scripts/webkit-relink.sh OUT WebCore/platform/graphics/haiku/MediaPlayerPrivateHaiku.cpp WebKitLegacy/haiku/API/WebPage.cpp`
  (≈80 s): the two files compiled by GCC 16.2 with ninja's command lines, the dependencies' headers and libraries from
  their packages, `libWebKitLegacy.so` relinked from the October objects (GCC 13.3). It adds a `libgcc_s` NEEDED entry.
- Test package: `artifacts/packages-test/wp1/haikuwebkit-1.10.0-2-arm64.hpkg` (the -1 package with this library,
  stripped, and `lib:libgcc_s`; library from `artifacts/wp1/t2`); installed with pkgman in session wp1b (§3.1); **not
  published**.
- **Done (WP2, §3.2): merged and published as haikuwebkit 1.10.0-2.** The recommendation was: merge the patch, publish only after a clean build. The gain is large and measured on every clip
  (app_server −1 core at 30 fps; quits no longer crash), the change is contained (one WebCore file, two hooks in
  WebPage.cpp; `WEBKIT_VIDEO_OVERLAY=0` restores the old path), and the fallbacks were exercised. Before a release:
  a full `scripts/build-webkit.sh` with GCC 16.2 (the patch applies to a fresh tree: `patch --dry-run` checked; ~hours,
  heavy-build lock), then the `wp1-run.sh` set again on the installed package (measure, scroll, controls, two, tab, mode,
  cycle), and the image's repository bump (AGENTS.md's three parts). KNOWN-ISSUES F11 would lose the quit crash, P2's
  WebPositive line ("RGB output … 1 frame in 3") would change to the plane numbers above.
- Follow-ups: rpivid's SAND pictures imported without the CPU copy (MediaPlayer's path, hw-video-decode §9); a
  `BPositionIO` (file) reader for `file://` media so non-faststart MP4s play and seeks are exact; a NEON or table
  converter for the software frames (9 ms at 720p, 23 ms at 1080p in C).

Outputs: `artifacts/wp1/runs/` (per run `.out`, HDMI `.png`), UART `artifacts/uart/20261122-041231-session-wp1a.log`,
`20261122-051151-session-wp1b.log`. Libraries: `artifacts/wp1/t2` (final), `t1` (before the plane claim), `control`.

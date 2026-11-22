# WebPositive `<video>` on the YUV overlay plane (WP1)

Status: **test build, not merged, not published** (2026-11-22). A change to HaikuWebKit's media player
(`patches/haikuwebkit/haikuwebkit-1.10.0-video-overlay.patch`) and a test library (`artifacts/packages-test/`). Numbers are
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
   the video is. One file in WebCore (+~600 lines) and a 10-line hook in WebKitLegacy. The stop rule did not apply.
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
- KNOWN-ISSUES P2: WebPositive takes the RGB32 path, which at 1080p60 shows ~1 frame in 3 (CPU-bound conversion);
  F11's crash at quit (`memcpy` in `ReadFrames` from the video thread) is not touched by this change.

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
- Fallbacks: no plane (allocation fails, all six in use), `LockBits()` failing (overlays suspended for a mode
  change), `SetViewOverlay()` failing: software, a retry after 1 s.
- `WEBKIT_VIDEO_OVERLAY_LOG=1`: a `WVO` line every 2 s (decoded, late, plane frames, shows/moves/hides, software
  repaints, conversions and their time, foreign paints, scrolls).

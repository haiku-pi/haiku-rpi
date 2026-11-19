# Firefox `<video>` on the YUV overlay plane (KNOWN-ISSUES G2)

Status: **A1 and A1b implemented and Pi-tested (2026-11-19), unpublished test packages**:
- Step 0 (§9.1): the video *is* a promoted compositor surface, and its software composite costs ≈1.1 cores.
- GCC 16.2 baseline rebuild (§9.2): it works.
- Option 0, SWGL with clang (§9.3): −14 % composite CPU at 720p, −25 % at 1080p, and 1080p drops from ~33 % to 5 %.
- **A1** (§9.4, `patches/firefox/0006`): the video on the overlay plane; `Renderer` + `SwComposite` 8.0 → 2.7 s per
  10 s at 720p, 7.9 → 4.6 s at 1080p, against option 0. Every fallback exercised.
- **A1b** (§9.5, `patches/firefox/0007`): no window drawing while only the video changes; 0.7 s (720p) and 1.9 s
  (1080p) per 10 s, app_server 0. Open: the plane copy at 1080p, and a VideoCore decoder abort at quit with two
  videos that option 0 has too.

One host-side compile probe (§1.4). Numbers are marked **measured** (with their source) or **estimated**. Builds on
[video-overlay.md](video-overlay.md) (B_YUV420 overlays, MediaPlayer), [gpu-stage6.md](gpu-stage6.md) (planes,
alpha keying), [gpu-present.md](gpu-present.md) (the GL present path), [videocore-services.md](videocore-services.md)
§1 (`h264_vc` in Firefox) and [perf-round-h20.md](perf-round-h20.md) "C6 / G2 results".

Question (owner, 11-19): can Firefox 157 on Haiku show `<video>` frames on the display's YUV overlay plane instead
of converting and drawing them in software (G2: about one CPU at 720p)?

Citation keys: **[F]** `sources/firefox/firefox-157.0.1` (Firefox 157.0.1 + HaikuPorts' patchsets + `patches/firefox`,
as `scripts/build-firefox.sh source` leaves it); **[H]** `sources/haiku` (`rpi4`); **[M]** `sources/mesa` (`rpi4`);
**[G]** `sources/libglvnd`. Paths below are inside those trees.

## 0. Answer in one screen

1. **Yes, but only with a Firefox rebuild.** No pref or environment variable switches it on. Firefox's
   software compositor converts and draws the video itself, and nothing hands a video surface to the Haiku
   widget. The pieces it needs on our side already work for MediaPlayer: B_YUV420 overlay bitmaps,
   `SetViewOverlay(..., B_OVERLAY_TRANSFER_CHANNEL)` and alpha keying.
2. **Today (§1):** Haiku gets *software WebRender* (SWGL) only. Read from the code, not yet confirmed on the Pi:
   the video is promoted to an external compositor surface, and the `SwComposite` thread converts it from YUV with
   `composite_yuv`, straight from the shared-memory planes into the window's B_RGBA32 back bitmap. Then the
   `Renderer` thread copies the dirty rectangle into a second bitmap and `DrawBitmap()`s it, and app_server copies
   it twice more. WebRender marks the video's whole rectangle dirty on every frame. **Measured** (perf-round-h20 C6):
   `Renderer` + `SwComposite` take ≈1 CPU per 720p stream. The `Renderer` half (≈0.5 core) is not explained by
   this path; step 0 splits it. **Found here:** SWGL is compiled by GCC, so its NEON paths are
   compiled out (they exist for clang only).
3. **Recommendation: option A1**, an overlay hook inside the existing software path (§2.3). When the compositor
   reaches a promoted 8-bit 4:2:0 video surface, the widget copies its planes into a B_YUV420 overlay bitmap and
   flips it, and SWGL fills the surface's rectangle with the overlay key instead of converting it. A second step
   stops a new video frame from dirtying the window. After that, a playing video on a static page costs one
   1.4 MB (720p) or 3.1 MB (1080p) copy per frame, with no SWGL and no app_server work. **Estimated:** ~700 lines (~450 C++ +
   ~250 Rust in WebRender's `SwCompositor` and `composite.rs`); 5–8 agent-days including 4–6 rebuilds.
4. **A full "native layer" backend (A2)** is the upstream shape that macOS (CoreAnimation) and Wayland
   (subsurfaces) use: every WebRender tile becomes a layer that our code composites. **Estimated:** 1.5–2.5 kLoC,
   8–15 agent-days, and the risk spreads to all page drawing. Not first.
5. **GPU WebRender (B, §3) is not the cheap middle ground here.** Five gates stand in the way:
   - `GLContextProviderBGL::CreateForCompositorWidget()` returns `nullptr` (the main blocker).
   - The platform blocks hardware compositing by default.
   - The allowlist is empty.
   - WebRender's desktop shaders need GLSL 1.50, which a default BGLView does not give.
   - A windowed GL window still costs a GPU blit plus two whole-window app_server copies per frame.

   It is worth a probe later, as a separate decision, because it would speed up all page drawing. It is not the
   video fix.
6. **Option 0, cheap and independent:** build SWGL with clang so its NEON paths are compiled in. The host probe
   shows clang 21 targets `aarch64-unknown-haiku` with our sysroot and gets `USE_NEON`. Gain unknown until measured.
7. **Main blocker for every option: the next Firefox build.** The objdir is gone (`artifacts/firefox/obj`
   does not exist). The cross compiler is now GCC 16.2, and Firefox has only been built with 13.3. The sysroot
   lacks the `deps` step's fontconfig and libevent. The first step is a baseline rebuild: about 1–1.5 h of
   compiling (**measured** 10-20 at -j11) plus whatever GCC 16.2 breaks (**unknown**).

## 1. How Firefox draws on Haiku today (Q1)

### 1.1 Which compositor Haiku gets

| Fact | Where |
|---|---|
| Toolkit `cairo-haiku`. The widget is `nsWindow` + `HaikuView` (a `BView`, view colour `B_TRANSPARENT_COLOR`) + `HaikuWindowBuffer` | [F] `widget/haiku/`, `HaikuView.cpp:178-182` |
| `gfxPlatformHaiku`: software vsync, no GPU process (`layers.gpu-process.enabled` is false outside Windows/Android/macOS) | [F] `gfx/thebes/gfxPlatformHaiku.cpp`, `modules/libpref/init/StaticPrefList.yaml:10423-10431` |
| Hardware compositing blocked by default: `AccelerateLayersByDefault()` is true only with `MOZ_GL_PROVIDER` or UIKit | [F] `gfx/thebes/gfxPlatform.cpp:3582-3588`, `:2525-2563` |
| Hardware WebRender is then force-disabled (`FEATURE_FAILURE_WEBRENDER_NEED_HWCOMP`), so `UseSoftwareWebRender` is set | [F] `gfx/config/gfxConfigManager.cpp:195-200`, `gfxPlatform.cpp` `InitWebRenderConfig` (`SetUseSoftwareWebRender(!hasHardware)`) |
| Software path: macOS and Wayland take `RenderCompositorNativeSWGL`; everyone else tries `RenderCompositorLayersSWGL`, which is `RenderCompositorOGLSWGL` off Windows and returns `nullptr` unless `AllowSoftwareWebRenderOGL()` (an Android/GTK-only pref). **Haiku ends in `RenderCompositorSWGL`** | [F] `gfx/webrender_bindings/RenderCompositor.cpp:201-230`, `RenderCompositorOGLSWGL.cpp:47-51`, `StaticPrefList.yaml:8768-8777` |
| WebRender wraps every software compositor in its Rust `SwCompositor` (`CompositorConfig::Native`). Without a native layer compositor it runs its own `SwComposite` thread, which composites picture-cache tiles and compositor surfaces into the window framebuffer | [F] `gfx/webrender_bindings/src/bindings.rs:2224-2231`, `gfx/wr/webrender/src/compositor/sw_compositor.rs:1196-1213` |
| `gfx.webrender.compositor` defaults to false on Haiku (true on Windows/macOS/GTK) | [F] `StaticPrefList.yaml:8439-8446` |

So the framebuffer SWGL draws into is the widget's own bitmap. `RenderCompositorSWGL::AllocateMappedBuffer()` calls
`StartRemoteDrawingInRegion()` and locks the returned Skia draw target's bits ([F] `RenderCompositorSWGL.cpp:72-140`).
`HaikuWindowBuffer` creates that draw target on the bits of a B_RGBA32 `BBitmap` (`HaikuWindowBuffer.cpp:33-93`), so
the lock succeeds and there is no temporary surface.

### 1.2 Path of a video frame (720p H.264 in a 1280×720 `<video>`)

| # | Step | Who, where | Data per frame |
|---|---|---|---|
| 1 | VideoCore decode, mmaldec copy, then Firefox's copy into a shared-memory YCbCr image | RDD process, `h264_vc` (videocore-services §1.2, §1.5) | 1.4 MB + 1.4 MB |
| 2 | ImageBridge → parent: `BufferTextureHost` (YCbCr) → `RenderBufferTextureHost` | parent | 0 (shmem) |
| 3 | The async image pipeline pushes the video with `PREFER_COMPOSITOR_SURFACE`, plus `SUPPORTS_EXTERNAL_BUFFER_TEXTURES` because `RenderCompositorSWGL::SupportsExternalBufferTextures()` is true; this arrives as `PushYCbCrPlanarImage(..., supportsExternalCompositing=true)` | [F] `gfx/layers/wr/AsyncImagePipelineManager.cpp:489-506`, `gfx/layers/composite/TextureHost.cpp:615-648`, `RenderCompositorSWGL.h:55` | — |
| 4 | WebRender tries to promote the YUV image, as an Overlay first and then as an Underlay (2D scale/translate only, root tile cache, mask/backdrop rules). The external image id rides along, so the surface is an **external** compositor surface | [F] `gfx/wr/webrender/src/tile_cache/mod.rs:2491-2494`, `:1560-1690`, `:1895-1902`, `:1994-2050` | — |
| 5 | `SwCompositor` locks the surface: `RenderBufferTextureHost::MapPlane()` hands SWGL the shmem planes **without a copy** | `sw_compositor.rs:1501-1535`, [F] `gfx/webrender_bindings/RenderBufferTextureHost.cpp:218-` | 0 |
| 6 | **YUV→RGB + scale**: `composite_yuv` on the `SwComposite` thread, straight into the window's back bitmap | `sw_compositor.rs:556-625` | reads 1.4 MB, writes 3.7 MB |
| 7 | `EndRemoteDrawingInRegion`: `memcpy` of the dirty bounding box back→front bitmap, then window lock, `DrawBitmap(front)`, `Sync()` (on the `Renderer` thread) | [F] `widget/haiku/HaikuWindowBuffer.cpp:96-170` | 3.7 MB |
| 8 | app_server: bitmap → back buffer, then back buffer → frame buffer (keyed write while an overlay is shown) | gpu-present.md §1 steps 9–10 | 2 × 3.7 MB |

Steps 4–6 are read from the code and not yet confirmed on the Pi (§1.3). That is four rectangle-sized passes per
frame for the video alone (steps 6, 7, 8 ×2: 3.7 MB each at 720p, 8.3 MB at 1080p full screen), one of them with
colour maths.

**The video's rectangle is dirty on every composite**, whatever changed. `push_compositor_surface()` adds each
compositor surface as a composite tile whose dirty rectangle is the whole surface ([F]
`gfx/wr/webrender/src/composite.rs:882-992`, "the entire area of external surfaces are treated as dirty", `:1157-1159`).
For a native-kind compositor (which `SwCompositor` is) the renderer unions every tile's dirty rectangle into **one**
rectangle (`gfx/wr/webrender/src/renderer/composite.rs:1317-1395`, `max_partial_present_rects` 1), and that rectangle
is what `RenderCompositorSWGL` asks the widget for (`RenderCompositorSWGL.cpp:163-198`). The *picture* is not drawn by the CPU as RGB anywhere else: the decode
side already saves what it can (videocore-services §1.5).

### 1.3 Where the CPU goes (measured) and what is not known yet

- **Measured** (perf-round-h20 "C6 / G2 results", 11-05): per 10 s of 720p the parent's `Renderer` thread takes
  4.6–6.1 s and `SwComposite` 3.6–5.1 s, ≈1 CPU together. At 1080p: `Renderer` 4.4 s + `SwComposite` 3.9 s of 8 s
  (perf-round-h20 §3, W44 10-29 18:45). The busiest Firefox thread showed 13.2 s of `memcpy` in a 46-s profile
  (perf-round-h20 table, run 4; "likely its compositor, unverified").
- **Measured** (videocore-services §1.5, 11-19): with the VideoCore decoding, the main process still takes about 2
  cores at 720p and 1080p, and 1080p drops ~40 % of its frames either way. The decoder is not the bottleneck; the
  drawing is.
- **Not known:** whether the video is promoted at all on Haiku (step 4). If it is not, SWGL converts the YUV with
  the `brush_yuv_image` shader on `Renderer` instead, which would explain `Renderer`'s half-core; then `SwComposite`
  only copies tiles. If it is promoted, `Renderer`'s ≈0.5 core is *not* explained by the path above. Step 7's
  3.7 MB `memcpy` is ~1–2 ms (**estimated**), and the rest would be WebRender frame work or the `DrawBitmap` +
  `Sync()` round trip. Plan step 0 settles both without a rebuild (§6).

### 1.4 SWGL is compiled without its NEON paths (found here)

SWGL's hand-written SIMD paths (`USE_NEON`: saturating adds, texture fetch and blend helpers) are defined **only
under clang** ([F] `gfx/wr/swgl/src/vector_type.h:5-14`). `-ffast-math` is likewise clang-only (`gfx/wr/swgl/build.rs:238-245`).
HaikuPorts builds Firefox with clang; `build-firefox.sh` uses the Haiku cross GCC (see `build-spidermonkey.sh` for
why), so on our build SWGL runs its generic `vector_size` code.

Host probe (2026-11-19), `probe.cc`:

```cpp
#include <cstdint>
#include <cstring>
#include <algorithm>
#define SI static inline
#include "vector_type.h"      // gfx/wr/swgl/src
#ifndef USE_NEON
#error "no NEON"
#endif
using namespace glsl;
int16x8_t sat(int16x8_t a, int16x8_t b) { return vqaddq_s16(a, b); }
```

`-std=c++17 -O2 -c`, `-I gfx/wr/swgl/src`; clang also gets `-isystem` for the sysroot's `develop/headers/c++` and
`c++/aarch64-unknown-haiku`:
- `clang++` 21.1.8 `--target=aarch64-unknown-haiku --sysroot=artifacts/sysroot-arm64` with the sysroot's libstdc++
  headers compiles it.
- `aarch64-unknown-haiku-g++` (GCC 16.2.0) stops at the `#error`.

So **option 0** is to compile SWGL alone with clang. Firefox already uses that clang for bindgen, and SWGL is a static
C++ library inside `gkrust`. That is a small `build.rs` change. Gain: **unknown**; a guess is 10–40 % of the SWGL
time (**estimated**, wide).

## 2. A separate video layer (Q2)

### 2.1 What other platforms do

All of them use WebRender's compositor-surface promotion (§1.2 step 4). They differ in who composites:

- **macOS** (`NativeLayerCA`, [F] `gfx/layers/NativeLayerCA.mm`, 2.1 kLoC) and **Wayland** (`NativeLayerWayland.cpp`,
  1.7 kLoC + `SurfacePoolWayland.cpp` 0.35 kLoC): `RenderCompositorNative{SWGL,OGL}` turns every tile and every
  external surface into an OS layer. The OS compositor stacks them, and the video's buffer is attached directly
  (IOSurface, dmabuf). The code is selected by `#if defined(XP_DARWIN) || defined(MOZ_WAYLAND)` in
  `RenderCompositor.cpp:204-216`, `RenderCompositorNative.cpp:38-43` and `RenderThread.cpp:1558-1567`.
- **Windows**: DirectComposition (`DCLayerTree`) with video-processor overlays.
- `SwCompositor` forwards surfaces to such a native compositor only when `use_native_compositor` is set; then it
  creates no `SwComposite` thread (`sw_compositor.rs:1625-1760`, `:1866-1890`).

### 2.2 What Haiku already has

- Overlay bitmaps (`B_BITMAP_WILL_OVERLAY`, B_YUV420 = planar I420 with the whole picture's `bytes_per_row`,
  video-overlay.md §0.2), up to six firmware planes, and `SetViewOverlay(bitmap, src, dst, &key, ..., B_OVERLAY_TRANSFER_CHANNEL)`
  flips. MediaPlayer's use is the model ([H] `src/apps/mediaplayer/VideoView.cpp:183-215`: first call, then
  `FillRect(videoFrame)` with the returned key, then transfers).
- **Keying by alpha** (gpu-stage6 §0.2, §3.3). The desktop is plane 0 (ARGB8888) *above* the overlay planes. Inside an
  overlay's rectangle, app_server writes a pixel whose RGB equals the key `{0, 80, 0}` as transparent, and every
  other pixel as opaque. So other windows, menus and any non-key pixel drawn over the video cover it.
- Measured cost of that path in MediaPlayer (video-overlay §3): 720p30 H.264 13.5 %, 1080p30 25.8 % of one CPU,
  including the copy of each frame into the overlay bitmap.

### 2.3 Two shapes for Firefox

**A1: an overlay hook in the software path (recommended).** WebRender's Haiku path stays as it is: `RenderCompositorSWGL`
and `SwComposite`. One promoted surface per window goes to the plane:

1. WebRender ([F] `gfx/wr/webrender/src/compositor/sw_compositor.rs`, `composite.rs`): `MappableCompositor` gets one
   new method, e.g. `present_on_plane(external_image, surface_rect, clip_rect) -> bool`, which `SwCompositor` calls
   for an external YUV surface before queuing its composite. On `true`, the surface's job becomes a **key fill**
   of its clipped rectangle, a solid fill with no colour maths, instead of `composite_yuv`. Tiles above it still
   composite over the key as before. Every other platform's `MappableCompositor` returns `false`. **Estimated**
   ~100–150 lines of Rust plus the FFI line in `gfx/webrender_bindings/src/bindings.rs`.
2. `RenderCompositorSWGL` (C++): the method gets the `RenderTextureHost` (`RenderThread::GetRenderTexture`).
   - It accepts only a `RenderBufferTextureHost` with 3 planes, `ColorDepth::COLOR_8`, a 4:2:0 layout, and a colour
     space the accelerant will use (see 2.4).
   - It asks the widget for a free overlay bitmap of that size and copies the planes into it via `MapPlane`. The
     copy happens while `SwCompositor` holds the surface lock, so the shmem cannot be recycled under it.
   - It queues `(bitmap, src, dst)` for `EndFrame`.
   - Fallbacks return `false`: no plane, a second video, `LockBits()` failing during a mode change.

   **Estimated** ~150 lines.
3. Widget ([F] `widget/haiku/`): a new `HaikuVideoOverlay` owned by `nsWindow`. It keeps 3 B_YUV420 overlay
   bitmaps (on screen / flipped / being filled; the first with `B_BITMAP_RESERVE_OVERLAY_CHANNEL`) and does the
   `SetViewOverlay` first call and transfers on `HaikuView`. That happens under the same `LockWithTimeout` the
   window buffer already takes on the `Renderer` thread (`HaikuWindowBuffer.cpp:152`). It also handles
   `ClearViewOverlay` when the video leaves, and reaches the compositor through `InProcessCompositorWidget::RealWidget()`.
   **Estimated** ~300 lines.
4. **Step A1b, no window work while only the video changes.** WebRender marks the surface's whole rectangle dirty
   on *every* frame (§1.2). With the plane hosting the surface and its rectangle, clip and key unchanged since the
   last frame, nothing in the window framebuffer changes. A1b stops `push_compositor_surface()` from marking such a
   surface dirty (`composite.rs:882-992`), keyed on "hosted on the plane last frame" as the compositor reported it.
   Then a frame where only the video changed has an empty dirty rectangle: `RenderCompositorSWGL` already installs a
   2×2 dummy framebuffer and never calls the widget (`RenderCompositorSWGL.cpp:187-197`). So `SwComposite`,
   step 7's `memcpy` and `DrawBitmap`, and app_server's two copies all go away for a static page.
   - **It cannot be done in C++ alone.** The renderer hands the compositor a single union rectangle, so
     `RenderCompositorSWGL` cannot tell "the video changed" from "a control over the video changed".
   - A move or shrink of the surface already invalidates the dirty rects (`update_dirty_rect_validity`,
     `composite.rs:1143-1169`).
   - A frame the compositor declines after being treated as clean shows the plane's previous picture for one frame,
     and is marked dirty again on the next one.

   **Estimated** ~100–150 lines of Rust in `composite.rs` / `sw_compositor.rs`.

Copies per 720p frame:
- Today: 4 rectangle-sized passes (§1.2), one with colour maths.
- A1: still 4 passes (a key fill instead of `composite_yuv`, then memcpy and app_server ×2), now without the colour
  maths, plus 1.4 MB into the overlay. A1 removes maths, not passes.
- **A1b: 1.4 MB into the overlay only.** Expected parent CPU for the video with A1b: close to MediaPlayer's consumer copy, **estimated** 0.1–0.2 core at 720p, against ≈1 measured today.

**A2: a native layer backend (`NativeLayerRootHaiku`).**
- New code: `gfx/layers/NativeLayerHaiku.{h,cpp}` (tile layers in CPU buffers, external layers on overlay
  bitmaps) and a `SurfacePoolHaiku`.
- Glue: `MOZ_WIDGET_HAIKU` branches in the three files above and in two `moz.build` files,
  `gfx.webrender.compositor` true for Haiku, and `nsWindow::GetNativeLayerRoot()`.
- With `use_native_compositor` on, `SwComposite` goes away and our `CommitToScreen()` composites the tiles into the
  window bitmap (clips, rounded clips, scale-only transforms; z-order is the layer order). The "nothing to do when
  only the video changes" property comes by design.
- Cost: **estimated** 1.5–2.5 kLoC (the Wayland analogue is 2.1 kLoC with its pool), 8–15 agent-days. All page
  drawing moves into our code (correctness risk for every page), and we lose `SwComposite`'s threaded,
  dependency-ordered compositing unless we rebuild it.
- Keep in reserve: if A1's WebRender patch grows beyond a hook, A2 is the cleaner form.

### 2.4 Keying and the cases decided

| Case | Decision |
|---|---|
| **Translucent content over a playing video** (the controls bar's gradient, captions with a translucent background): app_server keys on exact RGB, so such pixels blend with the key green, not the video | A1: accept and document for the first version. Firefox hides its controls during playback, so the effect shows only while the pointer is over the video. A1b: while any tile above the video rectangle changed in the last ~0.5 s, composite the video in software (today's path) and move it back to the plane once the content over it is static. Considered and rejected for now: passing the window's own alpha to the front buffer inside the overlay rectangle (exact, but it changes app_server's front-buffer rule for every window that overlaps the rectangle; a Haiku change, own risk) |
| Scrolling / moving video | The hole and the plane would be one frame apart (the key goes out with the window drawing, the plane moves at the next vblank). While the surface's rectangle changes, composite in software; go to the plane when the rectangle is unchanged for 2 frames |
| Partly clipped video (scrolled half out, clipped by a container) | Software. The plane is used only when the whole rectangle is visible in the window (no source crop; chroma-aligned cropping is a later refinement) |
| Several videos | One plane per window (one overlay per `BView`); the largest qualifying one gets it, the rest stay in software |
| No free plane (six in use, low memory below 1 GiB), mode change (`Bits()` NULL / `LockBits()` fails while suspended, video-overlay §3.1) | `false` → software for that frame; retry on a later frame |
| 10-bit HEVC (`hevc_rpivid` yuv420p10le), 4:2:2/4:4:4, RGB video | Software (MediaPlayer converts 10-bit with swscale; Firefox gets no such step) |
| Colour space | The accelerant picks BT.709 from 720 lines, BT.601 below, limited range (video-overlay §5); Firefox knows the stream's (`GetYUVColorSpace()`, range). Use the plane only when they agree; software otherwise until a colour-space field reaches the accelerant (open in video-overlay §5) |
| Fullscreen | The plane scales; the window's bitmap is the key only. The best case |
| Screenshots | Black where the plane is (gpu-stage6 §3.4), as for MediaPlayer |

## 3. GPU compositing: WebRender on V3D (Q3)

What a hardware-WebRender Firefox needs on Haiku, found in the code:

| Gate | State | Where |
|---|---|---|
| A GL context bound to the window for WebRender's `Renderer` thread | **`GLContextProviderBGL::CreateForCompositorWidget()` returns `nullptr`** (the BGL provider makes only headless contexts, used by WebGL with patches 0002/0003). `RenderCompositor::Create()` falls through to `RenderCompositorOGL::Create()` on Haiku, which calls exactly this. **Main blocker** | [F] `gfx/gl/GLContextProviderBGL.cpp:247-251`, `gfx/webrender_bindings/RenderCompositor.cpp:274`, `RenderCompositorOGL.cpp:21-33` |
| Hardware compositing allowed | Blocked by platform default (§1.1). Overridable by `MOZ_ACCELERATED=1` or `layers.acceleration.force-enabled`; `gfx.webrender.all` alone loses to the `ForceDisable` | [F] `gfxPlatform.cpp:2525-2563`, `gfxConfigManager.cpp:195-200` |
| WebRender allowlist | Haiku's `GfxInfo` has an empty driver list and empty vendor/device ids → not allowlisted; `gfx.webrender.all` (user force-enable) passes it | [F] `widget/haiku/GfxInfo.cpp`, `widget/GfxInfoBase.cpp:1170-1215`, `gfxConfigManager.cpp:184-193` |
| GL version | WebRender needs GL/ES ≥ 3.0 (`WebRenderAPI.cpp:262-273`), and its desktop shaders are `#version 150` (`gfx/wr/webrender_build/src/shader.rs:259-262`). A default BGLView is compatibility 3.1 / GLSL 1.40 (desktop-gl.md): the provider must ask for `BGL_CONTEXT_CORE` (3.3 core) or `BGL_CONTEXT_ES` (ES 3.1, `#version 300 es`) ([G] `include/HGL/opengl/GLView.h:28-33`) | |
| EGL instead of BGL | Possible: on Haiku `EGLNativeWindowType` is a `BitmapHook*` ([M] `src/egl/drivers/haiku/egl_haiku.cpp:220-271`), and `--with-gl-provider=EGL` exists ([F] `toolkit/moz.configure:725`). But it moves WebGL off the BGL provider our patches fixed, and Firefox's EGL glue knows no Haiku display. The BGLView route is smaller (a BGLView is EGL underneath) | |
| Upstream view of V3D | `widget/gtk/GfxInfo.cpp` has no V3D/Broadcom rule (grep): Linux treats it as any Mesa driver | |

Work for a probe (**estimated**): the provider's `CreateForCompositorWidget()` makes a `BGLView` child of `HaikuView`
(`B_FOLLOW_ALL`, core or ES). It is created on the window thread and made current on the `Renderer` thread, and the
widget glue hides it when WebRender falls back to software. That is ~250–350 lines, 3–5 agent-days to a first
frame, plus 2–3 rebuilds.

Why it is not the cheap middle ground for *video in a window*:
- **Present:** each frame is a GPU blit into a bitmap plus **two whole-window app_server copies** (gpu-present.md §1
  steps 5, 9, 10: **estimated** 2.5–3.5 + 3–6 ms at 1080p), because a BGLView presents its whole surface.
  Stage 6 puts a GL surface on a plane only when it covers the screen (`HAIKU_EGL_OVERLAY=full`), so fullscreen
  video would get 0 copies, and windowed only with `HAIKU_EGL_OVERLAY=1`.
- **Upload:** the YUV planes are uploaded as textures each frame, and Mesa's v3d tiles uploads on the CPU
  ([M] `src/gallium/drivers/v3d/v3d_resource.c:148, 423`; **estimated** 2–4 ms per 1080p frame).
- **Unknowns, each able to sink it:** WebRender on V3D under Haiku has never run. Its ~100 shader programs compile
  at start (program binary cache and Mesa disk cache on Haiku untested). A GL fault or GPU hang takes down the parent
  process (no GPU process). BGLView `LockGL` from the `Renderer` thread interacts with WebGL's BGL contexts, and the
  Blender work found two-thread locking issues (blender.md §3.2).
- **What it would buy:** all page drawing on the GPU (scrolling, CSS, canvas). That is a browser-wide project with
  its own measurements, not G2's fix.

A middle variant: SWGL rasterising tiles and GL compositing them (`RenderCompositorOGLSWGL`, Android/GTK only). It
needs the same window context, so it shares the main blocker.

## 4. Options compared

| | What | Gain for a 720p video (**estimated** unless noted) | Effort (**estimated**) | Risk |
|---|---|---|---|---|
| 0 | SWGL compiled with clang (NEON paths in) | 10–40 % of SWGL's time; all pages, not only video | ~20 lines in `gfx/wr/swgl/build.rs` (clang for `aarch64-unknown-haiku`), 0.5–1 day, 1 build | Mixed compilers in `gkrust` (same Itanium ABI and libstdc++; check step must still pass: no `tpidr_el0` reads, no TLSDESC) |
| A1 | Overlay hook, key fill instead of `composite_yuv` | Removes the YUV maths, not the passes (if promoted: most of `SwComposite`'s ≈0.4 core; measured total ≈1 core) | ~600 lines (~150 Rust), 3–5 days, 3–5 builds | Low–medium: falls back to today's path in every unusual case (§2.4) |
| A1b | + no window dirtying while only the video changes | Removes the remaining window copies: ≈0.1–0.2 core left | +~100–150 lines Rust (`composite.rs`; not possible in C++ alone, §2.3), 2–3 days, 1–2 builds | Medium: dirty-rect logic in WebRender; stale-pixel bugs if wrong |
| A2 | Native layer backend | Like A1b, by design | 1.5–2.5 kLoC, 8–15 days | High: all page compositing becomes ours |
| B | Hardware WebRender on V3D | Video maths on the GPU; window present costs GPU blit + 2 app_server copies; all pages faster if it works | 3–5 days to a first frame, then open-ended (1–3 weeks) | High: untested driver/WebRender pairing, parent-process crashes, shader start-up |

## 5. Rebuilding Firefox (Q4)

- `scripts/build-firefox.sh`: steps `source` (download, HaikuPorts patchsets, `patches/firefox/*.patch` once,
  stamped in the tree), `deps` (freetype, fontconfig, libevent via `cross-port.sh`), `hosttools` (cbindgen), `config`,
  `build` (`./mach build` under `heavy-build.sh -j 12 --mem-per-job 2`), `check`, `stage`, `package`.
- **Measured** 2026-10-20 (script header): ~1 h of compiling at -j11 on the 16-thread / 29 GB host. MemAvailable
  goes down to ~4 GB at the peak; objdir 3.4 GB; libxul 237 MB (179 MB stripped). BUILD.md "Disk space, memory and time": ~22 GB and
  ~1.5 h with the Rust toolchain. 74 GB free on 11-19.
- **State on 11-19:** `artifacts/firefox/obj` is gone (videocore-services §1.1: "the build tree was deleted"). The
  sysroot was recreated on 11-03, and `non-packaged/` now has `freetype2.pc` but no fontconfig/libevent → `deps` must
  run again. The cross gcc is **16.2.0**; `gcc16.md` step 4 lists `build-firefox.sh` among the 16.2 package rebuilds and names
  Firefox as a likely place for GCC 16 source breakage; Firefox 157.0.1-6 (released) was built with 13.3. The `relink` step cannot help: its link line is from the 13.3 objdir.
- Turnaround after the baseline (**estimated**): a change in `widget/haiku` or `gfx/webrender_bindings/*.cpp` is a
  unified-file recompile + libxul link, 5–15 min. A change in `gfx/wr` (Rust) also rebuilds the `webrender`/`swgl`
  crates and `gkrust` (no LTO: `--disable-lto`), 15–30 min. Then `stage`/`package` and an image or a copy to the
  Pi of `lib/libxul.so` alone (the app directory is `apps/Firefox/lib/`).
- New Firefox patches go to `patches/firefox/0005-…` onward. The `source` step applies them once (stamp
  `.haiku-rpi-firefox-patches`); the tree under `sources/firefox/` is shared with `build-spidermonkey.sh`.

## 6. Plan

Every step ends with a log entry with the numbers. A Pi step uses the shared bench under the turn protocol. Clips:
`play-720p30.mp4`, `play-1080p30.mp4` (`tools/media-tests/gen-h264-clips.sh`). Harness:
`tools/pi-tests/firefox-video.sh` / `vc-services.sh firefox` (teamstat per thread + `getVideoPlaybackQuality()`).

| Step | What | Pass criteria |
|---|---|---|
| 0 | **Measure, no rebuild** (release image, ~1 session). Per-thread CPU of the parent (`Renderer`, `SwComposite`, main) at 720p/1080p in a 1280×720 element and fullscreen. WebRender's profiler HUD (`gfx.webrender.debug.profiler` true and `gfx.webrender.debug.profiler-ui` naming the "Compositor surface underlays/overlays/blits" counters; prefs in [F] `modules/libpref/init/all.js:406, 421`, counters in `gfx/wr/webrender/src/profiler.rs:106, 548`) shows whether the video is promoted, on an HDMI capture. `about:support` confirms "WebRender (Software)" | Recorded: promotion yes/no and which kind; the `Renderer`/`SwComposite` split; app_server's CPU. If **not promoted**, find which `SurfacePromotionFailure` before A1. `gfx.webrender.debug.surface-promotion-logging` (`StaticPrefList.yaml:8367`) turns on the `warn!` in `tile_cache/mod.rs:2180-2192`; the release build keeps `info` and above (`toolkit/library/rust/shared/Cargo.toml:41`); where Gecko routes the Rust log on Haiku (stderr / `MOZ_LOG`) is to be confirmed in the session |
| 1 | **Baseline rebuild** with GCC 16.2: `build-firefox.sh deps`, then `config`…`package` unchanged | `check` passes; Firefox starts on the Pi, plays both clips; dropped frames and per-thread CPU within the noise of step 0; 0 debugger entries over 5 runs |
| 2 | **Option 0**: SWGL with clang (`patches/firefox/0005`) | Same functional checks; `SwComposite` CPU at 720p measured against step 1 (any gain kept, none = revert) |
| 3 | **A1** (`patches/firefox/0006`, WebRender hook + `RenderCompositorSWGL` + `HaikuVideoOverlay`) | HDMI capture: the video on the plane (colour bars right, the key never visible on an unhovered video, controls drawn over it). The driver's plane statistics count one flip per video frame. `SwComposite` CPU at 720p down by ≥ 0.25 core against step 2. Fallbacks each exercised once: scroll, half-visible, two videos, 10-bit HEVC, six planes taken (`overlaytest` ×6), a mode change during playback. No regression on a page without video |
| 4 | **A1b** (dirty-rect exclusion + "content over video changed" fallback) | Static page + playing 720p video: **no `DrawBitmap` per frame** (counter in `HaikuWindowBuffer`, debug build or `MOZ_LOG`); parent CPU for the video ≤ 0.3 core at 720p and ≤ 0.5 at 1080p; 1080p30 dropped frames < 5 % after the 30-s warm-up (G2's start-up drops are a separate cause); hovering shows correct controls (software while they change) |
| 5 | Release: package revision 7, KNOWN-ISSUES G2 updated, this doc's status | Release gate as for every Firefox package |
| later | **B probe** (hardware WebRender) as its own decision, after step 4's numbers | — |

## 7. Risks

- **GCC 16.2 and Firefox 157**: never built together here; new errors or miscompiles are possible. That is
  step 1, and it gates everything.
- **WebRender internals**: A1 adds a method to `MappableCompositor` (shared with macOS/Wayland in the same crate). Keep
  it default-`false` so other compositors need no change. A1b touches dirty-rect logic: a mistake shows stale pixels,
  not a crash. Test with scrolling and with content changing over the video.
- **Planes are shared** with MediaPlayer and full-screen GL (six in all, low memory below 1 GiB). A1 must release its
  overlay when the video stops, the tab is hidden or the window is minimised, or later users get none.
- **Timing**: the overlay flip lands at the next vblank and Firefox's software vsync is unsynchronised with it; MediaPlayer
  shows that one transfer per frame works (video-overlay §3). Compare A/V sync on a clip with audio.
- **Colour** differences between the plane and software (BT.601/709 guess): limited by the "use the plane only when they
  agree" rule.

## 8. Files an implementation would touch

| Option | Files |
|---|---|
| 0 | [F] `gfx/wr/swgl/build.rs` |
| A1/A1b | [F] `gfx/wr/webrender/src/composite.rs` (trait), `gfx/wr/webrender/src/compositor/sw_compositor.rs`, `gfx/wr/webrender/src/renderer/mod.rs` (A1b), `gfx/webrender_bindings/src/bindings.rs` (FFI), `gfx/webrender_bindings/RenderCompositor.{h,cpp}`, `RenderCompositorSWGL.{h,cpp}`, `widget/haiku/HaikuVideoOverlay.{h,cpp}` (new), `nsWindow.{h,cpp}`, `HaikuWindowBuffer.cpp`, `widget/haiku/moz.build` |
| A2 | [F] `gfx/layers/NativeLayerHaiku.{h,cpp}`, `SurfacePoolHaiku.{h,cpp}` (new), `gfx/layers/moz.build`, `gfx/webrender_bindings/{RenderCompositor,RenderCompositorNative,RenderThread}.cpp`, `gfx/webrender_bindings/moz.build`, `modules/libpref/init/StaticPrefList.yaml`, `widget/haiku/nsWindow.{h,cpp}` |
| B | [F] `gfx/gl/GLContextProviderBGL.cpp`, `widget/haiku/nsWindow.cpp`, `HaikuView.cpp`, `gfx/thebes/gfxPlatform.cpp` (`AccelerateLayersByDefault`), `widget/haiku/GfxInfo.cpp` (allowlist) |

## 9. De-risking results

### 9.1 Step 0 on the Pi (2026-11-19 17:36–17:47, session `ffv0`, image-2026-11-19b, network boot; **measured**)

`tools/pi-tests/ffv0.sh CLIP LABEL [hud]`: the released Firefox 157.0.1-6 plays CLIP looped and muted in a 1280×720
`<video>` (the `vc-services.sh firefox` page and prefs). After `WAIT` s (45 here; 30 for `m720a`) it takes every thread's CPU time in the
system twice, 10 s apart, with `profile -a -k` in between (`PERTHREAD=1`: per thread). The
`hud` mode adds WebRender's profiler HUD and `gfx.webrender.debug.surface-promotion-logging` with `RUST_LOG=webrender=warn`.
Raw output in `artifacts/ffv0/` (not in git). The decoder is `h264_vc` → VideoCore for both clips. 0 debugger entries in all runs.

**Promoted: yes.** The HUD (HDMI capture `artifacts/ffv0/h720-hud.png`, 720p, ~53 s after the start) shows:
- Compositor surface **overlays 1**, underlays 0, blits 0.
- Picture cache slices 4, **rendered picture tiles 0**.
- No promotion-failure line in Firefox's stderr.

So the video is an Overlay-kind external compositor surface (§1.2 steps 3–6 confirmed), and WebRender rasterises
nothing per video frame.

| CPU over 10 s (ms; 4 CPUs = 40 000) | 720p30 clip (`m720b`) | 1080p30 clip, downscaled (`m1080`) |
|---|---|---|
| Firefox `Renderer` | 6 429 | 7 003 |
| Firefox `SwComposite` | 5 115 | 5 607 |
| **`Renderer` + `SwComposite`** | **11 544 (1.15 cores)** | **12 610 (1.26 cores)** |
| of it `memcpy` on `Renderer` (profile) | 994 of 6 122 samples | 1 069 of 6 090 |
| app_server window thread (`w:…:ffv0`) | 1 548 (95.7 % `memcpy`) | 1 847 (95.7 % `memcpy`) |
| Firefox main thread / a DOM worker | 2 162 / 2 228 | 2 063 / 2 009 |
| decoder thread (`MediaPDecoder`) + `VCHIQ completion` (kernel) | ~1 000 + 1 061 | 2 570 + 2 329 |
| Firefox teams in all (`m720a`, from 30 s) | 24 136 (2.4 cores), idle 8 213 of 40 000 | — |
| frames 40→50 s: presented / dropped | 287 / 15 (5 %) | 201 / 100 (33 %) |

Where the compositor's core goes:
- `Renderer`'s time is not WebRender frame building, since no tiles are rendered.
- `SwCompositor` splits each composite into bands, and the `Renderer` thread steals composite jobs while it waits
  for `SwComposite` (`sw_compositor.rs:1120-1127`, `take_job`). So **both threads run the video's `composite_yuv`**:
  ≈1.0–1.1 cores, about 35 ms of CPU per 720p frame.
- The rest of `Renderer` is the `HaikuWindowBuffer` back→front `memcpy`: ~0.1 core.
- The libxul samples cannot be resolved further, because the shipped libxul is stripped and the objdir is gone; the
  baseline rebuild keeps symbols in its objdir.
- app_server's two copies of the video rectangle take 0.15–0.19 core.

Consequences for the plan:
- **A1 is worth more than estimated.** The key fill replaces about 1 core of YUV composite, not ≈0.4.
- **A1b removes the remaining ~0.25–0.3 core** (Firefox's `memcpy` and app_server's copies).
- **Option 0 targets exactly the code that costs the core** (`composite_yuv` without NEON).
- Nothing measured blocks A1. The surface is the Overlay kind (a sub-slice above it holds any content over the
  video), as §2.3 assumed.

### 9.2 Baseline rebuild with GCC 16.2 (2026-11-19 17:49–18:47, host; Pi session `ffv7` 19:43–19:59)

`scripts/build-firefox.sh deps` onward, unchanged sources, cross gcc 16.2.0, as a systemd user unit
(`HEAVY_BUILD_LOCK` of the job). Package `firefox-157.0.1-7` (revision 7 only to tell it apart) into
`artifacts/packages-test/firefox/` (unpublished).

What GCC 16.2 needed:
1. **libevent** (`deps`): GCC 14+ makes `-Wint-conversion` an error. `kqueue.c` stores an `intptr_t` in
   Haiku's `void *udata`, so the build now passes `-Wno-error=int-conversion` (same width; only a diagnostic).
2. **Memory**: at 2 GB per job (heavy-build: 11 jobs) the 22 GB scope was OOM-killed after 12 min, in `dom/`.
   GCC 16.2's jobs are bigger than 13.3's. Now 3 GB per job (`FIREFOX_MEM_PER_JOB`, ~7 jobs); the build resumed
   and finished.
3. Found on the way: `build-spidermonkey.sh source|hosttools` ran the rest of its chain, which built the js shell
   each time (7 min, 5.2 GB objdir). It now has `--only`, which `build-firefox.sh` uses.

Cost (**measured**): mach build 12 min (OOM) + 32 min resumed. The whole chain took 17:49→18:47, including deps,
cbindgen and the unwanted js shell. objdir 3.7 GB (kept for A1, with symbols); libxul 169 MB stripped; hpkg 101 MB.
The check step passes (DT_RELR, no TLSDESC/COPY/`tpidr_el0`). 3 527 warning lines; none was looked at. Deleted
afterwards: the js-shell objdir (5.2 GB) and the three deps ports' build/source trees.

**Smoke on the Pi** (image-2026-11-19b, `pkgman install` of the test package, `tools/pi-tests/ffv-smoke.sh`):
- haiku-os.org renders (HDMI `artifacts/ffv0/smoke7-haiku-os.png`).
- `hey Firefox quit` ends all 10 Firefox teams in 5 s; 0 debugger entries over the whole session.
- Clips (`ffv0.sh`, as §9.1; CPU over 10 s at 45 s):

| Clip | `Renderer` + `SwComposite` | dropped in ~10–12 s |
|---|---|---|
| 720p30 | 5 757 + 4 787 = 10 544 ms | 5 of 301 |
| 1080p30 (downscaled) | 6 802 + 5 132 = 11 934 ms | 125 of 362 |

That is the same as the released 13.3 build (§9.1: 11 544 / 12 610 ms; 5 % / 33 % dropped).

### 9.3 Option 0: SWGL compiled by clang (same session `ffv7`)

`patches/firefox/0005-haiku-swgl-clang.patch` (`gfx/wr/swgl/build.rs`: with `SWGL_CXX` set, SWGL alone uses that
compiler) and `FIREFOX_SWGL_CLANG=1` in `build-firefox.sh` (host clang 21.1.8, `--target=aarch64-unknown-haiku`,
the sysroot and its libstdc++ headers). The SWGL object's `.comment` shows clang 21.1.8.
- Incremental build 2 min; check passes; libxul +1.4 MB.
- Package in `artifacts/packages-test/firefox-swglclang/`.
- Without the variable the patch changes nothing.

Measured on the Pi, both builds extracted to `/boot/home` and run from there (`FFX=`), alternating, 2 runs each:

| | `Renderer` + `SwComposite` (ms / 10 s) | frames dropped | CPU per presented frame |
|---|---|---|---|
| 720p, GCC SWGL | 11 682, 10 626 (mean 11 154) | 9 / 361, 4 / 300 | ~38 ms |
| 720p, **clang SWGL** | 9 681, 9 574 (mean 9 628, **−14 %**) | 0 / 361, 3 / 361 | ~32 ms |
| 1080p, GCC SWGL | 10 515, 11 119 (mean 10 817) | 108 / 302, 90 / 301 (~33 %) | ~56 ms |
| 1080p, **clang SWGL** | 7 936, 8 377 (mean 8 157, **−25 %**) | 19 / 361, 18 / 362 (**5 %**) | ~28 ms |

- At 1080p the downscaling composite gains most: per presented frame it halves, and the drops fall from a third
  to the 720p level. app_server's share is unchanged (it composites nothing).
- Rendering checked on HDMI: `artifacts/ffv0/smoke7c-haiku-os.png` (haiku-os.org, the same as GCC's) and
  `o720v-video.png` (the video's colours as before). Quit clean, 0 debugger entries.
- Not measured: page drawing other than video (SWGL draws every page; scrolling would gain too) and a long soak.

**Nothing found blocks A1.** The rebuilt objdir has symbols (for profiles), an incremental build takes ~2 min,
and the bench test path works (`ffv0.sh`, `ffv-smoke.sh`, extracted packages). The objdir is now in the
option-0 state (SWGL by clang). A1 replaces the composite whose cost option 0 reduced, so the two do not add up.
Option 0 is worth shipping on its own regardless.

### 9.4 A1: the video on the overlay plane (2026-11-19 20:10–22:08; Pi sessions `ffa1`, `ffa2`; **measured**)

`patches/firefox/0006-haiku-video-overlay.patch` (on top of option 0; ~660 added lines: ~140 Rust, ~520 C++, the estimate was ~600):

- **WebRender** (`composite.rs`, `sw_compositor.rs`): `MappableCompositor::present_on_plane()`, `false` by
  default. At the start of compositing, before the dirty rect and occlusion shrink the clip rects, `SwCompositor`
  offers the largest external 3-plane YUV surface. It also tells whether the surface is wholly visible, unflipped
  and has no rounded clip. On `true` the surface's composite job takes a one-row texture of key pixels as its source
  (opaque, nearest): `Composite()`'s same-width path, one row copy per line, instead of `composite_yuv`.
- **Bindings**: `wr_compositor_present_on_plane` → `RenderCompositor::PresentOnPlane()` (virtual, `false`). Haiku's
  `RenderCompositorSWGL` accepts only these frames:
  - 8-bit 4:2:0 `YUV420` of an even size, the whole picture, inside the window;
  - the colour space the display assumes: BT.709 limited range from 720 lines up, BT.601 below. That is the same rule
    as Firefox's default for untagged video, so untagged clips match.

  It takes the mapped planes from the locked `RenderTextureHostSWGL`, which gets two accessors.
- **Widget**: new `widget/haiku/HaikuVideoOverlay.{h,cpp}`, owned by `nsWindow`, which hands it out through
  `GetNativeData(NS_NATIVE_HAIKU_VIDEO_OVERLAY)`. Headless and popup widgets return `nullptr`.
  - Three B_YUV420 overlay bitmaps; the first one reserves the channel.
  - The planes are copied under `LockBits()`. `SetViewOverlay()` runs under the window lock, inside the hook:
    the first call configures the plane before any key pixel reaches the window, later calls transfer the channel.
  - The plane is left with `ClearViewOverlay()`, and its bitmaps are freed, only after a software-composited frame
    has been drawn over its rectangle. Doing it earlier would show the key as green.
  - The overlay is cleared in `nsWindow::Destroy()` before the window quits.
  - `MOZ_HAIKU_VIDEO_OVERLAY=0` turns it off. `MOZ_HAIKU_VIDEO_OVERLAY_LOG=1` prints `HVO show/hide/stats` lines:
    frames on the plane, composites that drew into the window, and software frames by reason.
- **Software for that frame** (reason in the log):
  - the rectangle changed: back on the plane after 2 still frames, or after 15 within a second of leaving it, so a
    slow scroll does not flip it every few frames;
  - partly visible (`not-whole`), cropped, other formats (`format`) or colour spaces;
  - no plane or memory (`no-plane`, retried after 1 s);
  - `LockBits()` failing during a mode change (`suspended`).
- **Trap found in the build**: forward-declaring `class BBitmap;` in a Gecko header gives Be API classes Gecko's hidden
  visibility in every file that sees the declaration first. libxul then failed to link with "hidden symbol
  `BBitmap::LockBits` isn't defined". The forward declaration is wrapped in `#pragma GCC visibility push(default)`.

Build: incremental on the kept objdir, `FIREFOX_SWGL_CLANG=1`. The first build after the cbindgen header changed
recompiled ~18 min of C++; later ones took 2 min. The check step passes, and the SWGL object is still clang 21.1.8.
The test package is firefox-157.0.1-**8** in `artifacts/packages-test/firefox-a1/` (unpublished).

**How it was measured.** Harness `tools/pi-tests/ffv-a1.sh` (modes `measure`, `scroll`, `half`, `two`, `caption`,
`noplane`, `mode`). It runs from the host through `tools/pi-tests/ffv-a1-run.sh`, which takes HDMI frames on a schedule,
and `ffv-a1-sum.sh` sums the runs. Same page and window as §9.1, image-2026-11-19b, network boot. Packages were
extracted to `/boot/home/ffa/{o0,a1,a1b}` and alternated: option 0 (P), A1 (Q), A1b (R). CPU in ms per 10 s at 45 s;
4 CPUs = 40 000.

Two traps cost the first session (`ffa1`) its numbers. Neither is in the table below:
- **The screen saver.** The release image's default one hides windows, as found for the Haiku bench before. Every
  HDMI frame showed the bare desktop while the CPU numbers kept coming. `ffa2` booted with the bench's
  `ScreenSaver_settings` (`pi-session.sh --add`).
- **Background downloads.** A fresh profile downloads ~100 MB (remote settings, Safe Browsing, CRLite) in its first
  minutes, which put 1–3 s of `Socket Thread`/main-thread CPU into random runs. The harness profile now sends all
  http(s) to a refusing proxy.

| per 10 s | option 0 (P, 2 runs) | **A1** (Q, 3 runs) | A1b (R, 2 runs, §9.5) |
|---|---|---|---|
| 720p30: `Renderer` + `SwComposite` | 8 099, 7 972 (mean 8 036) | 2 512, 3 038, 2 710 (**2 753, −0.53 core**) | 537, 899 (718) |
| 720p30: app_server window thread | 1 089, 1 112 | 1 488, 1 721, 1 375 | 0, 0 |
| 720p30: all Firefox teams / idle | 15.7 s / 22.0 s | 10.5 s / 26.5 s | 5.4 s / 33.9 s |
| 720p30: dropped | 0, 0 of 300 | 0, 0, 0 | 0, 0 |
| 1080p30 (in 1280×720): `Renderer` + `SwComposite` | 8 048, 7 665 (7 857) | 5 353, 4 260, 4 232 (**4 615, −0.32 core**) | 2 315, 1 511 (1 913) |
| 1080p30: app_server window thread | 1 532, 1 986 | 2 358, 2 391, 2 161 | 0, 0 |
| 1080p30: all Firefox teams / idle | 22.3 s / 12.7 s | 20.7 s / 13.1 s | 16.6 s / 20.5 s |
| 1080p30: dropped | 1, 0 of 300 | 6, 2, 4 | 1, 0 |
| dropped from the start to 38 s (of ~1 100), 720p / 1080p | 18, 27 / 91, 90 | 9, 14, 13 / **140, 117, 75** | 9, 10 / 23, 33 |

Which builds: Q720a/b and Q1080a/b, and both A1b columns, ran on the packages before the settle rule (§ scroll
below). That rule only acts after the plane was left, so a steady video is not affected. Q720c and Q1080c ran on the
final -8. No clean `measure` run was made on the final -9.

- **On the plane:** the HVO counters show one plane frame per video frame: 299–305 per 10 s, plus 0–8 composites
  with an unchanged picture. The display driver's statistics agree: plane 1 at 289–301 updates per 600 vblanks.
- **Colours** match option 0's software path within ±3 per channel on the bars (720p and 1080p). Both use BT.709
  for these untagged HD clips (video-overlay.md §3).
- **The step-3 criterion (≥ 0.25 core less at 720p) is met: −0.53 core.** At 1080p it is −0.32 core.
- **A regression at 1080p, A1 only:** more frames dropped in the first 38 s (75–140 against 90–91), and 2–6 per 10 s
  afterwards against 0–1. `Renderer` now does the 3.1 MB plane copy on top of the window work, and its frames take
  longer. With A1b the start-up drops fall to 23–33. Not investigated further.
- **What A1 leaves (§2.3):**
  - the key fill, the back→front `memcpy` and `DrawBitmap` on `Renderer`;
  - app_server's two copies, which rise by 0.04–0.06 core because keyed front writes are a read-OR-write rather than
    a `memcpy` (gpu-stage6 §3.3);
  - the plane copy (next point).
- **The plane copy is slow at 1080p.** A profile of `Renderer` with A1b (where nothing else is left) shows 82 % in
  `memcpy`: 4.65 ms per 3.1 MB frame, ~670 MB/s, into the overlay buffer.
- **Other inputs:**
  - AV1 8-bit 640×360 (dav1d, BT.601): on the plane, 1 326 ms against 7 826 ms for the 10-bit clip;
  - H.264 854×480: on the plane, 3 704 ms;
  - AV1 10-bit 640×360: software, `format` for every frame (the fallback; Firefox here has no HEVC decoder).

**Fallbacks**, each run once with A1 (HVO log, HDMI frames `artifacts/ffa1/<run>-*.png`, not in git):

| Case | Run | Result |
|---|---|---|
| Scroll (640×360 video, 1.5 px per 50 ms for 2 s, then still for 6 s) | S1, S3 | Software while it moves, plane when still (`unstable` 279 frames in 60 s). The first version flipped 2–3 times per scroll burst; with the 15-frame settle rule (S3) it flips once per burst (9 shows in 60 s). No key visible in 5 frames taken while scrolling |
| Half above the window's top for 12 s, then moved in | H1 | `not-whole` 328 frames, then on the plane |
| Two videos (960×540 and 480×270) | T1 | The larger on the plane, the smaller in software. The second video's frames recomposite the window: 312 "same picture" offers, no copies |
| All six planes held by `overlaytest` for 25 s | N1 | `no-plane` 417 frames (retried each second), on the plane once they ended |
| Mode change to 1280×720 and back | M1 | `suspended` 1, leaves the plane; 27 frames declined in the 1-s back-off, then back on it; again after the change back. 0 debugger entries |
| 10-bit video | V10 | Software (`format`) |
| Controls and content over the video (`<video controls>`, an opaque caption, a 50 % white box; mouse moved over it by `uiinject`) | C1 | The opaque caption, the controls bar and other windows (a crash alert) cover the plane correctly. **Known limitations, both as designed (§2.4):** the translucent box blends with the key green, not the video. A Firefox tooltip window over the video has a dark green fringe: its translucent edge is blended with the key in app_server's back buffer, the same class as any window over a keyed overlay (gpu-stage6 §3.4) |
| No video: haiku-os.org | smoke (A1, A1b) | Renders (HDMI `smoke-a1b-haiku-os.png`); quit in 5–6 s, 0 debugger entries |

- **Unhovered video:** 0 key-coloured pixels in all the frames above, except the tooltip fringe.
- **Quit:** `hey Firefox quit` ended the teams in 1–2 s, and in 5–6 s for the haiku-os.org smoke runs. The `quit:` line
  does not see a team stopped in the debugger: the runs with an RDD abort also report "0 teams left".

**Debugger entries: 3 in about 55 Firefox runs, none in our code.** All three are the RDD process aborting
(`mozalloc_abort`) in `mmal_port_disable` → `mmal_port_buffer_header_callback` → libmmal_vc_client while the
VideoCore H.264 decoder shuts down at quit.
- Two came from the two-video page. Option 0 crashes there in the same way (T2: the same stack). Before the abort,
  the log has ~1 260 lines of `vc.ril.video_decode ... no event buffer left for ERRO`: with two `h264_vc` decoders
  open, the VideoCore reports errors faster than mmal hands out event buffers. **This is a decoder bug from before
  A1**, to be fixed in the mmal path (not done here).
- One came from a single 720p video with the A1 package in session `ffa1`, while the screen saver was hiding the
  window. It is **not attributed**: not reproduced with option 0, not recurred in ~25 single-video runs of A1 and A1b
  since. The same stack points to the decoder's shutdown, but A1 is not ruled out.
- **Strictly, "0 debugger entries" is not met.** Two of the three are reproduced with option 0.

### 9.5 A1b: no window drawing while only the video changes (same sessions; **measured**)

`patches/firefox/0007-haiku-video-overlay-no-redraw.patch` (on top of 0006; ~90 changed lines of Rust, the estimate was 100–150).

- `Compositor::plane_rect()` (new, default `None`) is implemented by `SwCompositor`. It returns the rect of the surface
  last offered to the plane and whether it went there.
- `calculate_dirty_rects` in `renderer/composite.rs` finds that surface's tile and leaves its dirty rect out, unless
  another tile's dirty rect intersects it. In that case it keeps the video dirty and calls
  `Compositor::plane_covered()`, and `SwCompositor` then composites the video in software until the content over it
  has been still for 0.5 s. That makes translucent content correct while it changes: the controls fading in, a
  caption.
- A frame in which only the video changed now has an empty dirty rect:
  - the renderer still returns it, so the compositor runs and flips the plane;
  - `SwCompositor` clips every surface out (before, an empty union composited the whole window into a dummy
    framebuffer; this case arises only here);
  - `RenderCompositorSWGL` never calls the widget.
- If the plane declines a frame that was left out, it keeps its previous picture for that frame. The next frame is
  dirty and goes in software, and `HaikuVideoOverlay::EndFrame` leaves the plane only once a frame has drawn over its
  rectangle.

Test package firefox-157.0.1-**9** in `artifacts/packages-test/firefox-a1b/` (unpublished; 0006 + 0007).

| Step-4 criterion (§6) | Result |
|---|---|
| Static page + playing video: no `DrawBitmap` per frame | Composites that drew into the window in the 10 s window: **0** of ~300 (HVO `window frames` vs `clean`); app_server's window thread 0 ms |
| Parent CPU for the video ≤ 0.3 core at 720p, ≤ 0.5 at 1080p | `Renderer` + `SwComposite` + app_server window: **0.07 core** (720p), **0.19 core** (1080p; the plane copy) |
| 1080p30 dropped < 5 % after the warm-up | 1 and 0 of 300 |
| Hovering shows correct controls (software while they change) | C2: plane → software when the mouse moves in (`hides` +1), the translucent controls bar and box show the video through them (HDMI `C2-hovered.png`), back on the plane after they are still |

- **The other fallbacks with A1b** (S2 scroll, H2 half, M2 mode change, haiku-os.org smoke) behave as with A1, with 0
  debugger entries. While scrolling, the composites alternate between window frames (moving) and clean frames (still).
- **Still open:**
  - The plane copy at 1080p (~4.7 ms per frame, ~0.14 core): write-combining or uncached overlay memory, copied by
    `memcpy` row by row. Candidates: wider stores, or have the decoder write into the overlay bitmap, which
    video-overlay.md §3 measured as a loss for MediaPlayer.
  - Static translucent content over a playing video stays blended with the key green, the A1 limitation. A1b only
    covers changing content.
  - The VideoCore two-decoder abort (§9.4).
- **Not tested:**
  - A realistic layout. Every page was a bare `<video>` at integer coordinates in a local file, so `cropped` and
    `colour-space` never fired. Whether the plane engages on a real page (centred or %-sized video, fractional
    offsets, rounded corners, a video site) is unknown; the HVO reasons tell, and that is the next run.
  - Plane release on a tab switch and on minimising (§7).
  - A/V sync on a clip with sound (`play-*-aac.mp4`).
  - Fullscreen, and two videos under A1b.
- **Build state left behind:**
  - `sources/firefox/firefox-157.0.1` has 0006 and 0007 applied, and they are in its patch stamp.
  - The objdir and `artifacts/firefox/non-packaged` hold the last build, which is A1 (-8): 0007's three Rust files were
    swapped out for that build and restored afterwards.
  - So the next `build` rebuilds A1b (-9); §9.3's "objdir in the option-0 state" no longer holds.
  - Back to option 0: `patch -R -p1` with 0007 and then 0006 in the tree, drop their two stamp lines, then
    `FIREFOX_SWGL_CLANG=1 build-firefox.sh build`.
  - jam's download directory and `artifacts/packages` still hold only -6.
- **Whether these patches go into a release package is the release gate's decision.** The `source` step applies every
  `patches/firefox/*.patch`, so a rebuild from scratch now includes 0006 and 0007. The option-0 candidate 157.0.1-7
  (`artifacts/packages-test/firefox-swglclang/`) was built before them and does not change.

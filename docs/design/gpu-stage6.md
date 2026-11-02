# GPU stage 6: scan-out planes for full-screen GL and video overlays (KNOWN-ISSUES F2)

Status: 2026-11-02 — design, and the host side implemented on branches `stage6` (haiku-pi/haiku,
haiku-pi/libglvnd, haiku-pi/mesa); built with the real flags, QEMU no-regression check done. **Nothing
has run on the Pi yet** (the bench was busy); §8 is the Pi test, ready to run. Numbers are marked
**measured** (with the source) or **estimated**.

Goal (`gpu-v3d.md` §3, stage 6): present tier P3 — the GPU stores a frame into a buffer the display
scans out, and a swap is a page flip of a firmware plane. Exit: a full-screen GL demo runs vsynced at
60.00 fps with 0 missed flips over 1200 frames; the same demo unsynced exceeds 60. Plus YCbCr overlays
(MediaPlayer's `B_BITMAP_WILL_OVERLAY` path) and the rpivid question (can decoded pictures be scanned
out without a copy).

Sources: `sources/haiku` (`rpi4` 46a18aecb4), `sources/mesa` (`rpi4` f64c84cae97), `sources/libglvnd`
(`rpi4` 7cc03c3); `<phoenix-rpi>` = the Phoenix-RTOS Pi 4 port (reference, read only); Linux
rpi-6.18.y `drivers/gpu/drm/vc4/` for firmware facts (GPL: facts only).

## 0. Decisions in one screen

1. **One mechanism: Haiku's overlay API.** Full-screen GL and video both become *overlay bitmaps*
   (`B_BITMAP_WILL_OVERLAY`) shown on firmware planes 1–6; a frame is presented by
   `SetViewOverlay(..., B_OVERLAY_TRANSFER_CHANNEL)` — MediaPlayer's existing, proven flip
   (`apps/mediaplayer/VideoView.cpp:209-214`). No new app_server protocol, no new public API.
2. **Colour keying by alpha.** app_server's overlay model *assumes* a colour key: it paints the key
   `{0, 80, 0, alpha 0}` into the view (`drawing/Overlay.cpp:70`, `View.cpp:1160-1181`) and lets other
   windows, menus and subtitles cover it. The HVS has no colour key but does per-pixel alpha. So the
   accelerant reports `B_OVERLAY_KEYING_USES_ALPHA` (an existing Be API flag, `video_overlay.h`), and
   app_server writes the front buffer with alpha forced to 0xff everywhere, except key pixels inside a
   visible overlay's rectangle, which become 0x00000000. While an overlay is visible, the driver scans
   the *desktop* out on plane 0 as ARGB8888 **above** the overlay planes. Occlusion, workspaces,
   subtitles, menus over a full-screen game: all exact, with no visibility tracking in app_server.
   Insurance for the first Pi contact: a driver setting `overlay_above_desktop` puts overlays above
   an opaque desktop instead (correct for an unobscured full-screen window, which is the exit test).
3. **Who qualifies for a GL plane:** a BGLView whose surface is the size of the screen (a
   `B_NO_BORDER_WINDOW_LOOK` window covering it, `BDirectWindow::SetFullScreen()`, SDL's full-screen
   window — all the same to app_server). Mesa decides (`HAIKU_EGL_OVERLAY=0|1|full`, default `full`):
   planes are 6 and low memory is scarce; windowed GL keeps the stage-5 path (P2). With keying a
   windowed GL overlay is also correct (`HAIKU_EGL_OVERLAY=1`), just not the default.
   BWindowScreen is not used by any GL program on Haiku (no BGLScreen since 2013) and is not involved.
4. **Grant/revoke = allocation.** Planes and buffers are granted when the overlay bitmaps are
   allocated (`allocate_overlay_buffer` / `allocate_overlay`, through app_server) and fail cleanly
   when none is free (Mesa and MediaPlayer then use ordinary bitmaps). Nothing is revoked while
   shown: occlusion is the key's job. A mode change suspends overlays (`Screen::SetMode` →
   `SuspendOverlays`); Mesa notices the moved buffer (`Bits()` changed or NULL) and re-imports or
   falls back.
5. **Buffers:** physically contiguous, below 1 GiB (the firmware keeps 30 address bits), allocated by
   the display driver from a pool reserved at its start (fragmentation, the W15 lesson), cleaned from
   the cache and mapped write-combining, as kernel areas with user access (`B_READ_AREA |
   B_WRITE_AREA | B_CLONEABLE_AREA`): `overlay_buffer.buffer` is handed to every client unchanged
   (`BitmapManager.cpp:133-139`, `Bitmap.cpp:567`). Mesa clones the area into its team and imports the
   clone with the existing `DRM_V3D_HAIKU_IMPORT_MEMORY` (kernel addresses fail its
   `IS_USER_ADDRESS` check). **No v3d driver change** (stage 7's `jobs.cpp` is untouched).
6. **Fence gating, both ends:** Mesa's presenter flips only after `WAIT_BO` on the frame's buffer
   (the GPU is done); a buffer replaced on screen at time T (the flip call returned) goes back to the
   render thread only after a vertical blank that somebody *began waiting for* at T + 3 ms or later.
   Why that is exact: the retrace semaphore is released by the SMI interrupt at the blank, so a wait
   begun at s returns at the first blank V > s ≥ T + 3 ms; the firmware latches plane changes at an
   update point ~1.6 ms before the blank (**measured** by Phoenix, `<phoenix-rpi>/docs/gpu-new-lane/
   E3-firmware-planes-vblank.md`:418-427), which therefore lies after T: the replacement is latched
   and the old buffer is off screen from V on. The rule needs no timestamps of the blank itself (a
   client sees it only after its wake-up latency); 1.4 ms of margin cover the interrupt's latency
   (Phoenix: 59 µs jitter). The GPU never writes a buffer that may be scanned out (on Phoenix that
   wedged ~40 % of boots, `gpu-v3d.md` §1.3). Without the SMI interrupt (the `SET_VSYNC` thread
   fallback) the margin is not proven: the driver logs which source it uses.
7. **Vsync:** swap interval 1 (EGL's default) flips right after a vblank (`BScreen::WaitForRetrace`),
   so the flip lands ~15 ms before the next update point; interval 0 flips as soon as the GPU is
   done ("last call wins" in the firmware: no tearing, frames may be skipped).
8. **rpivid: design only.** The firmware can scan SAND128 NV12 (`VC_IMAGE_YUV_UV` = 19, column
   height in `pitch`), but our rpivid driver writes luma and chroma with *different* column strides
   (chroma half), while `SET_PLANE` carries one; and pictures are not allocated below 1 GiB. §5 has the
   change and a probe to run first.

## 1. What exists (facts the design rests on)

| Fact | Where |
|---|---|
| `SET_PLANE` 0x48015, 60-byte struct, 8 planes per display (0 primary, 1–6 overlay, 7 cursor), unset = only display + plane id; layer is s8, the firmware frame buffer sits at −127 | `bcm2711_display.cpp:65-106,531-568`; Linux `vc4_firmware_kms.c:64-96,385-395` |
| Image types used: XRGB8888 44, ARGB8888 43 (cursor: per-pixel alpha works on the Pi, stage 4); for video: YUV420 planar 3, YUV422YUYV 45, YUV420SP (NV12) 52, YUV_UV (SAND) 19; `color_encoding` 1 = BT.601, 2 = BT.709, 3 = JPEG (full range) | `vc_image_types.h:18-147,151-175` (Linux) |
| Linux sends YUV420 (3 planes, one `pitch`, chroma pitch implied = pitch/2) and NV12; it never sends packed YUYV (45) — **untested by anyone on this firmware** | `vc4_firmware_kms.c:181-248,531-676` |
| Firmware timing (Phoenix, same board): SMI vblank 60.01 Hz, `SET_PLANE` p50 78–100 µs / p99 2.1 ms, never blocks, update point ~1.6 ms before vblank, last call wins; 1201 vsynced flips in 20 s with 0 missed; 12 443 flips/s unsynced; only the low 1 GiB scans out | `<phoenix-rpi>/docs/gpu-new-lane/E3-firmware-planes-vblank.md`:411-430 |
| Phoenix's compositor: target vblank = V+1 if `since_last_vblank + 2 ms < period`, else V+2 | `<phoenix-rpi>/docs/gpu-new-lane/frame-pacing.md`:70-80 |
| Our display driver: SMI interrupt → retrace semaphore at 60.00 Hz, plane 0 = scaled primary (layer 0), plane 7 = cursor (layer 127), mode buffer reserved at start | `bcm2711_display.cpp:258-376,531-614,683-749` |
| app_server overlay hooks: fetched after each `SetMode`; overlays need SUPPORTED_SPACES, GET_OVERLAY_CONSTRAINTS, ALLOCATE/RELEASE_OVERLAY_BUFFER; channels need ALLOCATE/RELEASE_OVERLAY; CONFIGURE_OVERLAY is called with no NULL check; hide = `configure(token, buffer, NULL, NULL)` | `AccelerantHWInterface.cpp:417-437,1099-1219` |
| The window rectangle arrives unclipped (negative `h_start` possible), `offset_*` always 0 | `Overlay.cpp:73-76,262-284` |
| `TakeOverToken()` leaves the old overlay's token set: deleting a bitmap the channel moved away from releases the channel still in use | `Overlay.cpp:186-195` |
| `B_OVERLAY_TRANSFER_CHANNEL` is ignored by app_server: every `SetViewOverlay` of an overlay bitmap on a view that shows one takes the token over and configures | `View.cpp:493-516`; `ServerWindow.cpp:2025-2077` |
| MediaPlayer: 4 overlay bitmaps, the first reserves the channel; it asks the decoder for the stream's YUV space, but the ffmpeg plugin always outputs B_RGB32 on this tree (`USE_SWS_FOR_COLOR_SPACE_CONVERSION` = 1) | `VideoConsumer.cpp:198-209`; `AVCodecDecoder.h:38-40`, `.cpp:487-496` |
| Haiku's planar 4:2:0 is `B_YUV420` (= `AV_PIX_FMT_YUV420P` in the media kit); `B_YCbCr422` is packed Y0 Cb Y1 Cr (= YUYV) | `GraphicsDefs.h:216-238`; `ffmpeg/gfx_util.cpp:176-209` |
| Mesa's present today (stage 5 + #73): GPU blit of the frame into an imported BBitmap, presenter thread waits `WAIT_BO`, `SetBitmap()` → `B_INVALIDATE` → app_server copies twice | `egl_haiku.cpp:366-551`; `gpu-present.md` §1 |
| arm64: a kernel area with `B_READ_AREA` gets the EL0 access bit; the A72 has no PAN | `VMSAv8TranslationMap.cpp:547-548`; `arch_cpu.h:13` |

## 2. Full-screen GL on a plane

### 2.1 Path of a frame

```
render thread                    presenter thread (Mesa)                 app_server / driver
-------------                    -----------------------                 -------------------
swap: GPU blit back buffer  -->  WAIT_BO(buffer)                         
      into overlay buffer B      [interval 1: wait for the next vblank]
      (merged into the frame's   hook->SetBitmap(B)  (BGLView, libglvnd)
      render job, A2)              SetViewOverlay(B, TRANSFER)  ------>  View::SetViewBitmap
                                                                         Overlay::Configure
                                                                         configure_overlay (accelerant)
                                                                         ioctl SET_OVERLAY -> SET_PLANE
                                 <- old bitmap A (was on screen)
                                 A retires: free at the first vblank
                                 >= flip return + 4 ms
render into A again  <--------   (free list)
```

Copies per frame: **0** (the GPU's store into the scan-out buffer replaces the blit's store into a
bitmap; app_server copies nothing — the view is a key-coloured rectangle that does not change).

### 2.2 Mesa (`egl_haiku.cpp`)

- Overlay bitmaps: `new BBitmap(bounds, B_BITMAP_WILL_OVERLAY [| B_BITMAP_RESERVE_OVERLAY_CHANNEL
  for the first], B_RGB32)` when the surface qualifies (§0.3); if the allocation fails, ordinary
  bitmaps (stage-5 path), and no new attempt until the size changes.
- Import: `area_for(Bits())` → `clone_area()` into the client team → `haiku_hw_import_memory()` on
  the clone; the clone is deleted with the import. The import is refreshed when `Bits()` changes
  (`Overlay::Resume` after a mode change re-allocates the buffer); a `LockBits()` failure
  (`B_BUSY`: suspended) drops the frame.
- No `SYNC_BO` for overlay bitmaps: nothing on the CPU caches them (write-combining everywhere).
- Only BGLView's native windows get overlay bitmaps: libglvnd's libGL exports
  `hgl_native_window_shows_overlays()` (looked up with `dlsym`, so an older libGL simply has none).
  Other `BitmapHook` implementations (glmark2's port, glfw's) would `DrawBitmap()` an overlay bitmap,
  i.e. app_server would read write-combining memory every frame.
- Presenter: `WAIT_BO`; for interval ≥ 1 it waits for the next vblank (`BScreen::WaitForRetrace()`),
  starting no earlier than 3 ms after its previous flip, then `SetBitmap()`. The returned bitmap goes
  on the render thread's *retiring* list with the time the flip returned; it is free once a blank
  was waited for from that time + 3 ms on (§0.6) — by the presenter's next vsync wait, or by the
  render thread itself when it needs a bitmap. A frame `SetBitmap()` hands back unchanged was not
  shown (BGLView could not lock its window in time): counted as dropped, free at once.
- `eglSwapInterval` is implemented (`haiku_swap_interval`, 0 or 1; >1 = 1).
- `HAIKU_EGL_FPS=1` adds a line every 5 s: flips, missed (vblanks between two flips beyond the ones
  the frame needed: it was ready, the flip came a blank late), starved (blanks the GPU's frame was
  not ready for), late (a flip that returned within 3 ms of the predicted next blank: it may latch
  a frame late), dropped.
- Buffers: 3 (on screen, pending, rendering). Vsynced: 60 fps if the GPU keeps up. Unsynced: a
  bitmap comes back at most once per vblank per flip in flight, i.e. up to ~120 frames/s shown
  attempts with 3 bitmaps (**estimated**); enough for "> 60". Recognising flips that were superseded
  before they latched (free at once, "mailbox" behaviour) is a follow-up that needs the Pi's timing
  measured first.

### 2.3 BGLView (libglvnd `src/HGL/GLView.cpp`)

- `BitmapHook::SetBitmap(bitmap)` with an overlay bitmap: `LockLooperWithTimeout(50 ms)`;
  first time `SetViewOverlay(bitmap, bounds, Bounds(), &key, B_FOLLOW_ALL, filters)` and
  `SetViewColor(key)` + `Invalidate()` (BGLView's view colour is `B_TRANSPARENT_COLOR` since
  7cc03c3, so app_server would not paint the key otherwise); later frames add
  `B_OVERLAY_TRANSFER_CHANNEL`. Returns the previous bitmap; on a lock timeout it returns the bitmap
  it was given (not shown) and keeps the old one on screen — the presenter never blocks on the window
  thread (the exit deadlock of 536f5c1).
- An ordinary bitmap after overlay mode: `ClearViewOverlay()`, view colour back to transparent,
  `B_INVALIDATE` as before.
- `Draw()` in overlay mode draws nothing (app_server fills the key).
- The `BitmapHook` ABI is unchanged: an old libGL with the new Mesa draws overlay bitmaps with
  `DrawBitmapAsync()` (correct, slow: app_server reads write-combining memory); a new libGL with an
  old Mesa never sees an overlay bitmap.

### 2.4 Why not BWindowScreen / BDirectWindow / a private protocol

- BWindowScreen hands the client the accelerant and the frame buffer (`WindowScreen.cpp:942-1004`);
  app_server keeps drawing underneath (`kWindowScreenFeel` only suppresses client redraws,
  `Window.cpp:1773`). No GL program uses it, and `B_MOVE_DISPLAY` flips need a frame buffer twice the
  screen height, which app_server would then use as its desktop size (`Screen.cpp:233`).
- BDirectWindow's `DirectConnected` protocol (`B_DIRECT_START/STOP/MODIFY`) hands out the *front
  buffer*, not a plane, and app_server's later back-to-front copies overwrite what the client drew.
  SDL's full-screen window is a BDirectWindow, but its GL output goes through a BGLView — so it
  qualifies under §0.3 anyway.
- A private "plane granted/revoked" protocol would need app_server to track occlusion (no eager
  clipping hook exists; workspace switches do not `Hide()` overlays) and to notify clients. Alpha
  keying makes occlusion the HVS's job, which is why it is the design.

## 3. Display driver and accelerant

### 3.1 Driver (`drivers/graphics/bcm2711_display`)

- **Reserve**: at `display_init` (app_server opens the device at boot, while memory is not yet
  fragmented: the W15 lesson), `overlay_reserve` (driver setting, default 3) buffers of the native
  B_RGB32 frame size (8.3 MB at 1080p, 24 MiB in all) are allocated `B_CONTIGUOUS` below 1 GiB and
  kept; a request takes the smallest free reserved buffer that fits, else gets a buffer of its own
  (which may fail late in a session). Each buffer is its own area — a kernel area with user access,
  cloneable — so `area_for()` in a client finds exactly it. Cleaned (`arm64_dcache_flush_range`)
  before it is mapped write-combining: the pages were cleared through the cacheable map (the mode
  and cursor buffers skipped this; fixed first in the series, `create_scan_out_area()`). A reused
  reserved buffer is cleared.
- ioctls (all under `sLock`):
  - `ALLOCATE_OVERLAY_BUFFER {size → area, address, physical}`, `FREE_OVERLAY_BUFFER {area}` (a
    buffer on a plane is unset first: `Screen::SetMode` suspends overlays by freeing their buffers);
  - `SET_OVERLAY {plane 1–6, image type, physical planes[3], pitch, width, height, source rect 16.16,
    destination rect in mode coordinates, colour encoding}`, `HIDE_OVERLAY {plane}`.
- `set_overlay` clips the destination to the mode (crop of the source in proportion), scales it to
  native coordinates exactly as the cursor and the scaled primary do, and calls `SET_PLANE`.
- **Keyed desktop**: with ≥ 1 overlay plane visible, the desktop is plane 0 as ARGB8888 at layer
  64 (overlays at 16 + plane), in the native mode pointing at the boot frame buffer (which must lie
  below 1 GiB — checked at start; else no overlays), with the firmware frame buffer blanked; with
  none visible, back to today (native: firmware frame buffer; scaled: plane 0 XRGB at layer 0).
  `set_mode` applies the same state.
- `overlay_above_desktop` (driver settings): overlays at layer 100, desktop stays opaque.
- Stats (the second measuring tool): per plane, updates, vblanks spanned, updates inside the last
  2 ms before the predicted vblank (`late`), vblanks without an update during a run (`gaps`),
  vblanks with more than one (`superseded`); `dprintf` when the plane is hidden and every 10 s while
  it changes: `bcm2711_display: plane 1: 600 updates in 600 vblanks, 0 late, 0 gaps, 0 superseded`.

### 3.2 Accelerant hooks (`accelerants/bcm2711_display/overlay.cpp`)

| Hook | Does |
|---|---|
| `overlay_count` | 6 |
| `overlay_supported_spaces` | `B_RGB32, B_RGBA32` (→ XRGB8888 44: alpha ignored), `B_YCbCr422` (→ 45, YUYV, experimental), `B_YUV420` (→ 3, planar I420) |
| `overlay_supported_features` | `B_OVERLAY_COLOR_KEY \| B_OVERLAY_KEYING_USES_ALPHA \| B_OVERLAY_HORIZONTAL_FILTERING \| B_OVERLAY_VERTICAL_FILTERING` (the HVS always filters when it scales) |
| `allocate_overlay_buffer` | pitch: 64-byte aligned (luma; chroma pitch = half for B_YUV420), height even for 4:2:0; size B_RGB32 `pitch × h`, YUV420 `pitch × h × 3/2`; driver ioctl; `buffer` = kernel address, `buffer_dma` = physical |
| `release_overlay_buffer` | driver ioctl (unsets a plane showing it) |
| `get_overlay_constraints` | view: 2-pixel alignment for YUV, sizes 2…buffer; window: 2…mode size; scale 1/8 … 16 (**estimated** HVS limits; Linux allows downscaling to 1/8) |
| `allocate_overlay` / `release_overlay` | token = `&gPlanes[i]`; release is reference-counted and tolerant of the `TakeOverToken` double release |
| `configure_overlay` | NULL window/view: hide; else source rect (view, buffer pixels) → 16.16, window rect (unclipped, mode coordinates) → driver; `color_encoding` BT.601 limited for SD (< 720 lines), BT.709 otherwise; only the buffer changed: the same call (the firmware has no cheaper "address only" path; p50 ~80 µs) |

### 3.3 app_server

- `HWInterface`: a list of the visible overlays' rectangles (screen coordinates, clipped) with the key
  colour; every 32-bit front-buffer write (`_CopyToFront`, the front half of `CopyToBackAndFront`)
  goes through `_WriteFrontRow()`: when keying is enabled (the accelerant reported
  `B_OVERLAY_KEYING_USES_ALPHA`), alpha is forced to 0xff, and inside an overlay rectangle a pixel
  whose RGB equals the key becomes 0. Not enabled: `memcpy` as before (every other accelerant).
- `AccelerantHWInterface`: fetches `overlay_supported_features`; `ConfigureOverlay`/`HideOverlay`
  update the list before calling the accelerant. Ordering: `SetViewOverlay` configures before it
  invalidates the view (`ServerWindow.cpp:2047-2060`), a window move configures before it blits
  (`Desktop.cpp:1542-1564`), a resize redraws the dirty region after `ResizeBy` (which updates the
  overlay) — so the key pixels written next are keyed against the new rectangle.
- `Overlay::TakeOverToken()` clears the other overlay's token (if it is not itself), so a deleted
  bitmap no longer releases the shared channel; `ConfigureOverlay`/`HideOverlay` check the hook.
- Cost: forcing alpha makes every front copy a read-OR-write instead of `memcpy` on this accelerant,
  also without overlays (switching it on with the first overlay would need a whole-screen pass under
  the drawing lock). Expected memory-bound like `memcpy` (**estimated**; `present-bench` gains a
  "RAM->WC, alpha forced" row to measure it next to `copy RAM->WC` 3.24 ms at 1080p, **measured**
  10-25).
- The kernel debugger's 32-bit palette gets alpha 0xff (`frame_buffer_console.cpp`), so KDL output
  stays visible (and opaque) over a plane.

### 3.4 Known limitations (same class as any colour-keyed overlay)

- BDirectWindow/BWindowScreen clients that write the frame buffer with X = 0 while an overlay is
  visible get transparent pixels (black, or the overlay showing through).
- Screenshots (`ReadBitmap` reads the front buffer) show black where a plane is.
- The key `{0, 80, 0}` drawn by anything inside an overlay's rectangle shows the overlay.

## 4. Video overlays (MediaPlayer)

- With the hooks above MediaPlayer gets planes for B_RGB32 today (its decoder output on this tree):
  hardware scaling (full-screen video without app_server's scaled `DrawBitmap`), no app_server copy,
  subtitles and other windows over it through the key.
- **YCbCr**: the ffmpeg plugin converts to B_RGB32 with swscale because `USE_SWS_FOR_COLOR_SPACE_
  CONVERSION` is 1 (`AVCodecDecoder.h:38-40`); MediaPlayer itself asks for the stream's space first
  (`MediaTrackVideoSupplier::_SwitchFormat`, `B_YUV420`/`B_YCbCr422`). The next step (not in this
  series): when the consumer offers `B_YUV420` and the stream is `yuv420p`, output it unconverted
  (a plane copy instead of a conversion: ~1/3 of the bytes, no colour math); the HVS converts. The
  accelerant already supports B_YUV420 (→ type 3) and B_YCbCr422 (→ 45, experimental).
- `tools/haiku-tests/overlaytest.cpp` exercises each space with a known pattern (colour bars + a
  moving square), transfer flips between two buffers, a window over the overlay and a move partly
  off-screen; HDMI snapshots grade it.

## 5. rpivid: decode straight into a plane buffer (design only)

- The HVS scans SAND for NV12 (Linux `vc4_plane.c:2716-2730`); through the firmware, Linux passes NV12
  + SAND128 as `VC_IMAGE_YUV_UV` (19) with the **column height in lines in `pitch`**
  (`vc4_firmware_kms.c:638-652`), `planes[0]` = luma, `planes[1]` = chroma; DRM's NV12_COL128 has
  *one* column height for both planes (chroma in the same column after the luma).
- Our rpivid writes luma columns of H16 × 128 bytes and chroma columns of H16/2 × 128 in a separate
  plane (`rpivid.cpp:229-262`): two strides; `SET_PLANE` has one. Phoenix changed its decoder to the
  DRM layout for the same reason (column height C = H16 × 3/2, chroma at H16 × 128 inside each
  column; `<phoenix-rpi>/docs/gpu-new-lane/M10b-video-zero-copy.md` §4.1) — but never built the plane
  path (§4.4 there).
- Pictures are contiguous but allocated anywhere in the 16 GiB DMA window (`rpivid.cpp:66-105`); a
  plane needs < 1 GiB.
- Change (when the probe passes): `RPIVID_PICTURE_SCANOUT` flag → allocate below 1 GiB and lay the
  picture out as NV12_COL128 (luma and chroma column strides both C × 128; the uAPI already reports
  both strides, so the ffmpeg-side converter needs no change); a private overlay colour space for
  SAND (the accelerant maps it to type 19 with `pitch` = C); ffmpeg's `hevc_rpivid` hands the
  picture to the consumer instead of converting (a media-kit buffer that *is* an overlay buffer).
  That is a media-kit plumbing project of its own (decoder → consumer zero copy); the 10-bit case
  (`YUV10COL` 59) is the same with P030 packing.
- **Probe first** (`tools/haiku-tests/sandprobe.cpp`, run by `gpu-stage6.sh` on image C, §8): color
  bars written in SAND128 into a driver overlay buffer and shown with `SET_PLANE` type 19 (haiku
  eb591bcde9: `BCM2711_DISPLAY_IMAGE_YUV_UV`, experimental, chroma offset and vpitch settable), in
  three layouts — L1 DRM's NV12_COL128 (Linux's), L2 our rpivid layout with vpitch = height, L3 with
  vpitch = the chroma column height — answers "does this firmware scan SAND" and "can it take our
  decoder's two strides" before anyone changes `picture_geometry()`. Image C because the probe
  bypasses app_server, so nothing keys a plane under the desktop.
- Gain (**estimated** from hw-video-decode.md §8, 720p): today 1.32 ms SAND→planar on the CPU +
  swscale to RGB32 + app_server's copies; with a SAND plane: none of them.

## 6. Effort and risks

| Part | Effort (agent-days) |
|---|---|
| driver pool + ioctls + keyed desktop + stats | 1 |
| accelerant hooks | 0.5 |
| app_server keyed front writes + fixes | 0.5 |
| libglvnd + Mesa present path | 1 |
| tests, Pi runs, fixes after first contact | 1–2 |
| YCbCr in the ffmpeg plugin | 0.5–1 |
| rpivid scan-out (after the probe) | 2–4 |

| Risk | Impact | Mitigation |
|---|---|---|
| Per-pixel alpha on a non-cursor ARGB plane over another plane misbehaves (premultiplication, blend mode) | holes not transparent, or green tint | transparent pixels are written as 0x00000000 (nothing under both alpha conventions); `overlay_above_desktop` fallback; the overlay test's first check is "desktop visible over a plane through a keyed hole" |
| HVS bandwidth with two full-screen planes at 1080p60 | underruns (flicker) | ~1 GB/s of 2 × 8.3 MB frames (**estimated**) is far below what the HVS composes on Linux (several 4K planes); watch the HDMI capture |
| EL0 access to the kernel-area overlay buffers | MediaPlayer's `memcpy` into `Bits()` faults | arm64 maps them with the EL0 bit; first Pi check; fallback = per-team clones (needs a libbe change) |
| Forcing alpha slows every front copy | desktop slower | measured by present-bench's new row; expected memory-bound |
| Wake-up latency of the retrace watcher > 2.4 ms | GPU writes a buffer still scanned out | 4 ms guard; driver stats show late flips; raise the guard |
| Window thread holds its lock long (rendering in `Draw()`) | dropped flips | counted (`drops`); BGLView programs render from their own thread |
| Low-memory pool exhausted by video + GL | allocation fails | clean fallback to ordinary bitmaps; pool size setting |
| Mode change while a GL plane is up | buffer relocated | `Bits()` compared per frame; re-import or fall back |

## 7. Implementation (branches)

| Repository, branch | Commits | What |
|---|---|---|
| haiku-pi/haiku `stage6` (from `rpi4` 46a18aecb4) | 0fe29c5355 | bcm2711_display: `create_scan_out_area()`: clean the cache before write-combining (mode buffer, cursor) |
| | 47574ab00c | bcm2711_display: overlay buffers (reserve), planes 1–6, keyed desktop on plane 0, `overlay_above_desktop`, per-plane flip statistics, 4 ioctls |
| | 3e78d06eb1 | bcm2711_display.accelerant: the nine overlay hooks (`overlay.cpp`) |
| | 9512b02d01 | app_server: `TakeOverToken()` clears the other overlay's token |
| | e2f63c3b65 | app_server: keyed front-buffer writes (`OverlayKeying.cpp`, `HWInterface::_WriteFrontRow()`), the rectangles from `ConfigureOverlay`/`HideOverlay`/`ReleaseOverlayChannel`, configure hook checked |
| | 500159a1cd | kernel debugger console: opaque 32-bit palette |
| | eb591bcde9 | bcm2711_display: SAND128 NV12 plane type for the rpivid probe (experimental) |
| haiku-pi/libglvnd `stage6` (from `rpi4` 7cc03c3) | be20124 | BGLView: overlay flips in `SetBitmap()`, leaving overlay mode, `hgl_native_window_shows_overlays()`, `SwapBuffers(vSync)` → `eglSwapInterval` |
| haiku-pi/mesa `stage6` (from `rpi4` f64c84cae97) | 3f1ab3f8289 | egl/haiku: overlay bitmaps for full-screen surfaces, area-clone import, retirement rule, vsync presenter, swap interval, statistics |
| haiku-rpi (this repo) | — | `tools/gl-tests/glflip.cpp`, `tools/haiku-tests/overlaytest.cpp`, `tools/haiku-tests/sandprobe.cpp`, `tools/haiku-tests/host-overlay-keying/` (host test of the keyed copy), `present-bench` rows "alpha forced"/"keyed", `tools/pi-tests/gpu-stage6.sh` (bootscript), `tools/pi-tests/gpu-stage6-image.sh` (images) |

The v3d driver is not touched: import (`DRM_V3D_HAIKU_IMPORT_MEMORY` of the area clone) and the fence
(`WAIT_BO`) exist. Nothing here conflicts with stage 7 (`jobs.cpp`); the one shared assumption is
that `WAIT_BO` on an imported BO returns when the last job that wrote it completed.

Build (host, separate output directories; the main `generated.arm64`, `artifacts/gl-build` and
`artifacts/gl-stack` untouched):

```sh
# Haiku: a configured output directory in the worktree, the main tree's cross tools, download/ hard-linked
cd sources/haiku-stage6 && mkdir generated.arm64 && cd generated.arm64
../configure --cross-tools-prefix /home/houp/haiku-rpi/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-
cp -al ../../haiku/generated.arm64/download download
cd /home/houp/haiku-rpi
scripts/build.sh --generated sources/haiku-stage6/generated.arm64 bcm2711_display bcm2711_display.accelerant app_server
# libglvnd, Mesa, the GL tests: meson with build-gl-stack.sh's options into artifacts/stage6/build/<name>
#   (the shared sysroot only read, nothing installed into it); Mesa: ninja ... src/egl/libEGL_mesa.so.0.0.0
tools/haiku-tests/host-overlay-keying/run.sh sources/haiku-stage6     # KEY ... PASS
tools/pi-tests/gpu-stage6-image.sh --stage                              # artifacts/gpu-stage6/
```

## 8. Pi test (not run yet)

Images from the release candidate that is `rpi4` 46a18aecb4, the branches' base (no image build):

```sh
cd /home/houp/haiku-rpi
tools/pi-tests/gpu-stage6-image.sh artifacts/images/haiku-pi4-2026-11-03.img artifacts/images/gpu-stage6-b.img b
tools/pi-tests/gpu-stage6-image.sh artifacts/images/haiku-pi4-2026-11-03.img artifacts/images/gpu-stage6-a.img a
scripts/netboot-cycle.sh --image artifacts/images/gpu-stage6-b.img --secs 420 --label gs6-b \
  --hdmi-every 5 --until 'GS6 end' --retry-wedge
scripts/netboot-cycle.sh --image artifacts/images/gpu-stage6-a.img --secs 420 --label gs6-a \
  --hdmi-every 10 --until 'GS6 end' --retry-wedge
# only if B's HDMI frames show no overlay, a tinted or garbled desktop: overlays above the desktop
tools/pi-tests/gpu-stage6-image.sh artifacts/images/haiku-pi4-2026-11-03.img artifacts/images/gpu-stage6-c.img c
scripts/netboot-cycle.sh --image artifacts/images/gpu-stage6-c.img --secs 420 --label gs6-c \
  --hdmi-every 5 --until 'GS6 end' --retry-wedge
```

Read: `grep -a -E 'GS6|bcm2711_display: (plane|overlays|vertical)' artifacts/uart/<ts>-gs6-?.log`.

| Step | Expected on B (positive markers) | On A |
|---|---|---|
| boot | `bcm2711_display: overlays: planes 1-6 under (keyed) the desktop, 3 buffers of 8100 KiB reserved`; `vertical blank: SMI interrupt`; `GS6 app_server: /boot/system/non-packaged/servers/app_server`; the desktop on HDMI as always | no `overlays:` line; packaged app_server |
| bench | `copy RAM->WC, alpha forced` within ~10 % of `copy RAM->WC` (3.24 ms at 1080p, 10-25) | the same rows (the bench does not depend on the image) |
| bitmapcheck | the same 12 `BMC` hashes on A and B | reference |
| overlay | `OVL rgb32: overlays` (and ycbcr422, yuv420); per space `bitmap 0/1: No error`, `filled ok` (user code wrote the kernel-area buffer), `SetViewOverlay: No error, key 0,80,0,0`, `240 flips ... 0 failed`, `end: PASS`. HDMI: bars in order (white, yellow, cyan, green, magenta, red, blue, black) scaled 2× in the window, the white square moving, the yellow window over the bars, the bars cut at the left edge after the move. YCbCr422 (type 45) is the one nobody ran before: wrong colours there = byte order (try `B_YCbCr422` → 47 UYVY / 46 YVYU) | `no overlays` ×3, `end: FAIL` (allocation refused) |
| flip-vsync | `GLF frames 1200 in 20.0x s = 59.9x–60.0x fps`, `0 over 1.5x the median`; every `egl_haiku: overlay: ... 0 missed, 0 starved, 0 late, 0 dropped (swap interval 1, vblank 16.6xx ms)`; driver `plane 1: N updates in N vblanks, 0 late, 0 gaps, 0 superseded` — **the stage 6 exit** | no `overlay:` lines; the rate of the window path (~74–110 fps at 1080p, unsynced: A has no vsync) |
| flip-free | `GLF ... fps` > 60 (estimated ~100–120: two flips per blank with three bitmaps); driver `superseded` > 0 possible | window path rate |
| flip-cover | as flip-vsync; HDMI: the yellow window over the triangle while it is shown (keying) | — |
| flip-window | `HAIKU_EGL_OVERLAY=0`: the stage-5 rate at 1080p, for comparison with flip-free | same |
| glview | `PASS` (a 512² window: not full screen, no overlay) | `PASS` |
| sand (image C only) | `SND L1/L2/L3 ...: shown`; HDMI per 5 s: L1 bars right = the firmware scans SAND; L2 right = our decoder's pictures as they are; L3 right = with vpitch as the chroma height | — |

Then on the bench (owner or a scripted mouse): MediaPlayer playing a clip in a window gets an RGB32
overlay (its decoder's output): moving another window over it keeps that window on top; full screen
scales on the plane. KDL (`Alt+SysRq+D` or `kdl` from a terminal) over a full-screen glflip: the
debugger's text is readable.

## 9. Status (2026-11-02, host only)

- Builds: the display driver, accelerant and app_server with jam's own flags (`-Werror`) in
  `sources/haiku-stage6/generated.arm64`; the kernel debugger console object; libGL (libglvnd) and
  `libEGL_mesa.so.0` with meson in `artifacts/stage6/build/` (no new warnings; the `-Winvalid-offsetof`
  in GLView.cpp is old); glflip, glview, present-bench, overlaytest, bitmapcheck. Staged in
  `artifacts/gpu-stage6/` (`versions.txt`).
- Host test: `tools/haiku-tests/host-overlay-keying/run.sh sources/haiku-stage6` → `KEY 15168840 pixels
  checked, 0 failures: PASS` (keyed and opaque rows, rectangles none/several/overlapping/partly
  outside, key pixels with any alpha, X = 0 pixels).
- QEMU virt (no V3D, no planes: the stage6 driver does not attach, the framebuffer accelerant has no
  overlays, so keying stays off and Mesa uses softpipe): image B (`gpu-stage6-image.sh ... b`, release
  candidate 11-03 + stage6 files) boots to the desktop with the non-packaged app_server; bitmapcheck's
  12 hashes **identical** to the packaged app_server's (same image, override removed); glview `PASS`
  with the new libGL + Mesa; glflip runs full screen on softpipe (10 fps: the 1200 frames do not
  finish in the 60 s limit there, by design of the QEMU run); overlaytest says `no overlays` and
  fails cleanly. One test-tool bug found and fixed: `BBitmap::Bits()` of an overlay bitmap whose
  allocation failed crashes (libbe dereferences the missing client data; Mesa checks `InitCheck()`
  first).
- Pi: not run (bench busy). §8 has the commands; `artifacts/images/gpu-stage6-b.img` is built.
- Open, by the Pi run: whether EL0 may write the kernel-area overlay buffers (overlaytest
  `filled ok`); per-pixel alpha of a non-cursor ARGB plane over another plane (the keyed desktop);
  packed YUYV (type 45, never sent by Linux); the real unsynced rate; the cost of the forced alpha.
- Follow-ups: mailbox-style unsynced flips (recognise flips superseded before their update point);
  YCbCr output from the ffmpeg plugin when the consumer offers overlays; the rpivid SAND probe and
  `RPIVID_PICTURE_SCANOUT` (§5); KDL hiding planes is not needed with keying (the opaque palette).

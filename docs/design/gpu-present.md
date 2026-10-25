# GL/Vulkan present on the Pi 4: where a frame's time goes, and the cheaper path

Status: 2026-10-25, task #73. Path mapped from the code, a prototype on branches `rpi4-present`
(haiku-pi/mesa and haiku-pi/haiku), not yet measured on the Pi. Numbers are marked **measured**
(with the log entry) or **estimated** (from bandwidth figures, to be replaced by the Pi test below).

Why: glmark2-es2 on V3D 4.2 (WEEK-2026-W43, 10-25 07:15) runs nearly every 1920×1080 scene at
73–75 fps (13.5 ms) and every 800×600 scene at ~270–280 fps, trivial or not — ~130–150 Mpixel/s
either way (**measured**); glview (BGLView) presents ~100 Mpixel/s at every size from 400² to 1000²
(**measured**, 10-19). 800×600 has 0.23× the pixels and gets 3.7× the rate: a per-byte cost, not a
fixed per-frame one. The GPU is not what limits trivial scenes.

Sources: `sources/mesa` (haiku-pi/mesa `rpi4` db2eac33c13), `sources/haiku` (`rpi4` 45785f05b0),
`sources/libglvnd` (`rpi4` 536f5c1). Paths below are in those trees.

## 1. The path a GL frame takes today (EGL, hardware screen, imported bitmap)

The original assumption behind #73 — a GPU→CPU readback into the BBitmap — is out of date: stage 5
(10-19) already has the GPU copy the frame into the bitmap's own pages. The copies that remain:

| # | Step | Who, where | Data at 1080p (8.29 MB) | Cost |
|---|---|---|---|---|
| 1 | Render: TLB tiles → the back buffer (UIF-tiled BO, write-combining) | GPU, the frame's render job | 8.3 MB store | part of the render job |
| 2 | `st_context_flush()` submits the render job, *then* the present runs | `egl_haiku.cpp` `haiku_swap_buffers` | — | — |
| 3 | Render thread waits for the presenter of frame N−1 (`presented_sem`) | `haiku_present_copy` | — | = GPU done with N−1's blit + step 7 |
| 4 | `SYNC_BO` of the spare bitmap: `dc civac` over every line, **holding the v3d device lock** | kernel `v3d/bo.cpp` `sync_bo` | 130 k cache-line ops | **estimated** 1–4 ms; nothing measured — the bench below answers it |
| 5 | Present blit: a **job of its own** (`v3d_tlb_blit`): TLB load of the tiled back buffer, raster store into the bitmap. The merged path (`v3d_tlb_blit_fast`) cannot apply: the render job was flushed in step 2. The TFU cannot write raster (`v3dx_tfu.c:59`) | GPU | 8.3 MB load + 8.3 MB store + a bin/render job | **estimated** 2–3 ms GPU; QuakeSpasm 1080p: "one of ~3 lists per frame, ≤ ~15 %" (**measured** 10-20/10-21) |
| 6 | Presenter thread: `WAIT_BO` on the bitmap | `haiku_presenter` | — | — |
| 7 | Presenter: `SYNC_BO` again (drop the stale lines), **device lock held** again | kernel | 130 k ops | as step 4 |
| 8 | `SetBitmap()` → `B_INVALIDATE` to the window (no wait) → `_UPDATE_` → `Draw()` → `DrawBitmap()` | libglvnd `GLView.cpp` (or glmark2's hook) | — | messaging |
| 9 | app_server copy 1: bitmap → back buffer (`Bgr32Copy`, memcpy per row), cached → cached | `Painter/bitmap_painter/DrawBitmapNoScale.h:124` | 8.3 MB read + 8.3 MB write | **estimated** 2.5–3.5 ms |
| 10 | app_server copy 2: back buffer → frame buffer (`HWInterface::_CopyToFront`, memcpy per row) at the end of every drawing op (`DrawTransaction`) | `drawing/HWInterface.cpp:656` | 8.3 MB read + 8.3 MB write-combining write | **estimated** 3–6 ms |

Facts behind the table:

- **Steps 4 and 7 stall the GPU.** `sync_bo` holds `device->lock` for the whole walk; the v3d worker
  thread takes the same lock to finish a job and kick the next one (`jobs.cpp:860` `worker_thread` →
  `process_events`). Twice per frame, for as long as the walk takes, a finished bin job cannot start
  its render and a finished job cannot start the next.
- **Step 4 is not needed after the first frame.** Nothing on the CPU writes an imported bitmap
  (app_server only reads it), so no dirty line can be written back over the GPU's frame; the clean
  lines app_server's read leaves are dropped by step 7. Vulkan's WSI already does it this way
  (flush once, invalidate per frame, `wsi_common_haiku.cpp` header).
- **Steps 9 and 10 are both always there.** app_server always draws into a malloc'ed back buffer
  when the screen is B_RGB32 (`AccelerantHWInterface.cpp:638-656`) and copies each drawing op's
  dirty region to the frame buffer right after it. The frame buffer is the firmware's, mapped
  write-combining (`bcm2711_display.cpp:474`); a mode below native is a contiguous WC buffer below
  1 GiB scaled by firmware plane 0.
- **app_server runs beside the render thread, not in its chain** for GL (`SetBitmap` does not wait),
  so steps 9–10 cap what reaches the screen (and take DRAM bandwidth from the GPU), not the swap rate.
  Vulkan's presenter does wait (`view->Sync()`, `wsi_common_haiku.cpp:203`): FIFO is paced by them.
- Two bitmaps alternate: the spare one the GPU writes in step 5 is the one shown until the presenter's
  `SetBitmap` a moment before, which app_server may still be copying.
- No hardware overlay or scanout path exists for windows: the accelerant (`bcm2711_display/hooks.cpp`)
  has no overlay hooks; the driver uses firmware `SET_PLANE` for the scaled primary (plane 0) and the
  cursor (plane 7) only. Planes 1–6 are free.

Model (estimated, to check): per frame ≈ render job + blit job + 2 × walk, serialised through the
device lock — e.g. 1.5 + 2.5 + 2 × 4 ≈ 12 ms at 1080p, ×0.23 + overheads ≈ 3.5 ms at 800×600, near
the measured 13.5 / 3.6 ms. If the walk is much cheaper than 4 ms, the gap is elsewhere (DRAM
contention with steps 9–10 is the next suspect); the bench separates them.

## 2. Options

| Option | What | Gain (estimated) | Risk / cost | Upstream |
|---|---|---|---|---|
| **A1** sync once | `SYNC_BO` before the blit only when the bitmap is first imported | −1 walk per frame from the render thread | none (Vulkan does it) | Mesa (our Haiku EGL code) |
| **A2** merged present blit | issue the present blit from `st_context_flush()`'s before-flush callback: v3d's `tlb_blit_fast` adds the raster store to the frame's own render job | −1 job, −8.3 MB GPU load per frame; ≤ ~15 % for GPU-bound scenes | low: falls back to the separate blit when the job does not cover the frame | Mesa |
| **A3** three bitmaps | the render thread hands the GPU the next frame without waiting for the presenter of the last one; the bitmap rewritten is two frames old (narrows the app_server read race) | removes the presenter from the render thread's chain | +8.3 MB memory | Mesa |
| **B1** sync without the lock | `sync_bo` takes a BO reference and walks unlocked | the GPU keeps running during walks | low | Haiku (our v3d driver) |
| A4 render straight into the bitmap | the imported bitmap as the back attachment (linear render target) | −8.3 MB tiled store as well | glReadPixels on the back buffer fails (`MMAP_BO` refuses imported BOs), raster rendering slower on V3D, the race widens to the whole render | not now |
| C1 fused app_server copy | for an opaque unscaled B_OP_COPY bitmap, one pass writes back and front buffers (no re-read of the back buffer) | −8.3 MB read per displayed frame (~25 % of steps 9–10); every BBitmap app gains (SDL, MediaPlayer, Wine) | medium: DrawingEngine/HWInterface special case | yes, plain app_server |
| C2 NEON / non-temporal copy | stores that skip the read-for-ownership | small: memcpy is optimized-routines' (ldp/stp q), the A72 detects streaming writes | low | — |
| C3 DMA / V3D for back→front | the legacy DMA engine or a V3D raster blit copies the dirty region | frees the CPU, not the bandwidth | app_server becomes a device client; async completion | partly |
| D direct to the frame buffer | the GPU blits into the window's rectangle of the frame buffer (scissored per clip rectangle) | −steps 7, 9, 10 | app_server's back buffer goes stale under the window (cursor, overlaps, moves redraw old pixels); BDirectWindow's protocol is for BDirectWindow subclasses (SDL and glmark2 use BWindow); importing a physical mapping (`lock_memory_etc` on the firmware frame buffer); tears | no |
| E scanout plane (stage 6) | full-screen or unobscured topmost GL window: the GPU stores into contiguous scan-out buffers (below 1 GiB, allocated at driver start), a flip = firmware `SET_PLANE` on plane 1–6, latched at vblank | −steps 7, 9, 10 and all cache maintenance; vsync, no tearing | app_server must decide when a window may use a plane and tell the client; the HVS has no colour key, so occlusion = fall back; firmware call per flip | the overlay hooks are accelerant-local; the policy is app_server work |

## 3. Decision

1. **Now (prototyped):** A1 + A2 + A3 in Mesa and B1 in the v3d driver. Contained, no API change,
   every GL program gains, B1 also Vulkan (`v3dv` calls the same `SYNC_BO`). Expected (estimated):
   trivial 1080p scenes from ~74 fps to well above 100, bounded by the presenter's single walk and
   by DRAM contention with app_server; GPU-bound scenes ≤ ~15 %.
2. **Next:** C1 — the cheapest cut of the copies that remain (app_server's), and the one that helps
   every bitmap-drawing program, not only GL.
3. **Later, when vsynced full-screen GL matters:** E (stage 6). It removes everything but the GPU's
   own store, but needs app_server policy; D is rejected (stale back buffer, BWindow clients).

## 4. Prototype

- **Mesa** `rpi4-present` (haiku-pi/mesa, from `rpi4` db2eac33c13), `src/egl/drivers/haiku/egl_haiku.cpp`:
  - the present is split in `haiku_present_prepare()` (take a bitmap, import it once, sync it once,
    blit) and `haiku_present_finish()` (hand to the presenter, or copy with the CPU);
  - prepare runs from `st_context_flush()`'s `before_flush_cb`, so the blit finds the unflushed render
    job (the `flush_resource` before it submits nothing for a UIF-tiled back buffer, which every
    window-sized one is: `v3d_resource.c:1102-1112`); `HAIKU_EGL_SEPARATE_BLIT=1` runs it after the
    flush, as before;
  - `HAIKU_EGL_SYNC_EACH_FRAME=1` restores the per-frame pre-blit sync;
  - up to three bitmaps (`kMaxBitmaps`), a free list owned by the render thread; the presenter hands
    back the bitmap the view returned, published by `presented_sem`;
  - `HAIKU_EGL_FPS=1` also prints the render thread's waits per frame for the GPU (throttle fence) and
    for the presenter.
- **Haiku** `rpi4-present` (haiku-pi/haiku, from `rpi4` 45785f05b0), `drivers/graphics/v3d`: `sync_bo`
  walks without the device lock (a BO reference keeps it), and the `v3d_stats` report gains
  "N cache syncs of imported memory, K KiB and T us each" — the walk's cost measured in place.
- **tools/gl-tests/present-bench.cpp**: on the Pi, per frame size: memcpy RAM→RAM, RAM→WC (a v3d BO's
  write-combining mapping, as the frame buffer), one fused RAM→RAM+WC pass (option C1's cost),
  WC→RAM (why a CPU readback is slow), `SYNC_BO` of an imported B_RGB32 bitmap (lines absent / clean /
  dirty), and app_server's `DrawBitmap()+Sync()` of a frame-sized bitmap.
- Verified on the host: everything compiles with the real flags (Mesa: `libEGL_mesa.so.0` from a
  separate build directory; the v3d driver with jam's own compile and link lines, `-Werror`);
  QEMU virt (softpipe: the hardware present code does not run there, `haiku_create_hw_screen`
  returns NULL) — see the status line below. Not verified: anything on V3D.

Host results (2026-10-25): QEMU virt, image-2026-10-25c + the prototype files: glview `PASS` (pixel
checks ok) and glmark2-es2 build/texture `exit 0` with the packaged Mesa and with the prototype (its new
`HAIKU_EGL_FPS` line proves it was the one loaded; its version string still says `git-db2eac33c1`, the
commit it was built on before the change was committed); present-bench's RAM→RAM and DrawBitmap steps
run (QEMU's times mean nothing). The BlockedEntries setting hides the packaged `v3d` (only
`virtio_gpu` left in `/boot/system/add-ons/kernel/drivers/graphics`) and the non-packaged copy is in
place: image B's mechanism works. Whether the driver then loads it on the Pi is for the Pi run
(positive marker: `v3d: stats: N cache syncs` lines exist only with the new driver).

## 5. Pi test

Two images from the newest release image (no rebuild; `scripts/image-add.sh` creates directories):
A = packaged v3d driver, B = A + the prototype driver (the packaged one hidden by a packagefs
BlockedEntries setting, so the module search finds the non-packaged copy). In each boot the bootscript
runs the four Mesa variants (base = packaged Mesa, proto, proto-sepblit, proto-legacy) by
`__EGL_VENDOR_LIBRARY_FILENAMES`.

The files in `artifacts/gpu-present/` (built 2026-10-25, see §4): `libEGL_mesa.so.0` (Mesa
`rpi4-present` 3e13703ac0a, meson with build-gl-stack.sh's options in a separate build directory,
stripped), `50_mesa.json` (its vendor file, `library_path` = `/boot/home/present/egl/libEGL_mesa.so.0`),
`v3d` (haiku `rpi4-present` f11194cd1b, jam's compile and link lines), `present-bench`. To rebuild them
from the branches instead: `meson setup B sources/mesa` (on `rpi4-present`) with the options of
`scripts/build-gl-stack.sh`, `ninja -C B src/egl/libEGL_mesa.so.0.0.0`; `scripts/build.sh v3d` on a
`rpi4-present` checkout; `tools/gl-tests` with the gl-tests step of build-gl-stack.sh.

```sh
g=artifacts/gpu-present
printf 'load_symbols true\nv3d_stats true\n' > $g/kernel
printf 'Package haiku {\n\tBlockedEntries {\n\t\tadd-ons/kernel/drivers/graphics/v3d\n\t}\n}\n' > $g/packages
files=(
  $g/present-bench:/boot/home/present/present-bench
  artifacts/gl-stack/non-packaged/bin/glview:/boot/home/present/glview
  $g/libEGL_mesa.so.0:/boot/home/present/egl/libEGL_mesa.so.0
  $g/50_mesa.json:/boot/home/present/egl/50_mesa.json
  artifacts/packages/glmark2-2023.01-1-arm64.hpkg:/boot/home/present/glmark2.hpkg
  $g/kernel:/boot/home/config/settings/kernel/drivers/kernel
  tools/pi-tests/gpu-present.sh:/boot/home/config/settings/boot/UserBootscript
)
scripts/image-add.sh artifacts/images/haiku-pi4-2026-10-25c.img artifacts/images/gpu-present-a.img "${files[@]}"
scripts/image-add.sh artifacts/images/gpu-present-a.img artifacts/images/gpu-present-b.img \
  $g/v3d:/boot/system/non-packaged/add-ons/kernel/drivers/graphics/v3d \
  $g/packages:/boot/system/settings/packages

# two network boots (~9 min of tests each after the desktop)
scripts/netboot-cycle.sh --image artifacts/images/gpu-present-a.img --secs 780 --label gpu-present-a \
  --until 'GPP end' --retry-wedge
scripts/netboot-cycle.sh --image artifacts/images/gpu-present-b.img --secs 780 --label gpu-present-b \
  --until 'GPP end' --retry-wedge
```

Read (`grep -a -E 'GPP|v3d: stats' artifacts/uart/<ts>-gpu-present-?.log`):

- `GPP PRB ...`: the per-step costs at 1920×1080 and 800×600 — fill in the "estimated" cells of §1.
  `SYNC_BO, lines not cached` is the walk of steps 4/7.
- `GPP <variant> gm2-full: ... FPS:` per scene and `egl_haiku: N frames/s; per frame X ms waiting for
  the GPU, Y ms for the presenter`: base vs proto is the whole prototype; proto-sepblit isolates A2;
  proto-legacy (≈ base + A3) isolates A1+A2. Image B vs A isolates B1.
- **A2 engaged**: in the `v3d: stats` lines, the CL jobs per 5 s per frame drawn halve from
  proto-sepblit (render + blit list per frame) to proto (one list) at the same scene. If they do not,
  the before-flush blit fell back to the separate job.
- `v3d: stats: N cache syncs ..., T us each` (image B only): the walk measured in the driver;
  `GPU busy %` per 5 s.
- `glview` lines `check ... ok` and `PASS`: the merged path keeps the frame correct (glview reads the
  back buffer back).
- Positive markers: four `variant` blocks, each with `exit 0` thrice; `GPP end`.

Pass: proto ≥ 1.3× base on build/texture at 1920×1080, no FAIL, no `cannot import`, and the HDMI
frames show the scenes.

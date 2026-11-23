# Blender on the Pi 4 (Haiku arm64): feasibility and plan

Status (2026-11-19): **M1 (SDL2 per-thread GL context) done, §7.2; M2 done: `blender` 3.6.23 links for Haiku
arm64 (cross-built, minimal option set), §7.3; M3 done: Cycles renders the default cube headless on the Pi
(1920×1080 factory scene in 1 min 37 s), §7.4; M4 mostly done: the UI runs through GHOST_SDL on the desktop —
solid viewport, edit mode, save/reload, preferences window, F12 Cycles render into the image editor — after two
GPU patches; injected keyboard and mouse input acts (Tab, middle-drag and numpad orbit, F12), §7.5–7.6; M6
done as test packages (unpublished): blender-3.6.23-1 + 15 library packages with OpenColorIO (Filmic) and
OpenSubdiv, installed with pkgman and started from the Deskbar entry; the factory scene renders as it is, §7.7;
M5 done: EEVEE Legacy renders on V3D's 4 color attachments (SSS off) — Material Preview and F12, no crash, §7.9.
B7 (11-20): blender -7 test packages — Cycles denoising with OpenImageDenoise 2.5 (render, viewport, compositor),
the `aud` module (NumPy 1.26 for Python 3.10), Alembic, the Ocean modifier, fluid simulation, and the Rendered
viewport fixed (GL context sharing), §7.14. B8: OpenVDB, GMP, QuadriFlow, Draco, translations, §7.15. B9: USD
import/export (OpenUSD 24.08 against oneTBB, Haiku port of its arch library) and a Haiku crash in Blender's
recursive delete fixed, test packages blender -9 + usd, §7.16. BW1: the viewport is not memory-bound; patch 0017 (no
anti-aliasing while navigating on V3D, +52 % fps orbiting), §7.17; published as blender -10 (11-22), §7.18.** Owner (11-18): "If we have OpenGL 3.3 … schedule an
analysis for bringing up the newest possible version of Blender3D … Blender 3.6 seems to work ok on OpenGL 3.3 …
Start by analyzing if this is possible, and then plan implementation accordingly."

**Verdict.** **Blender 3.6.23 LTS** (the last 3.6 LTS release; nothing newer has an OpenGL 3.3 path) is
feasible on our desktop OpenGL 3.3 core (Mesa `v5-gl`, [docs/design/desktop-gl.md](desktop-gl.md)). The UI goes
through Blender's own **GHOST_SDL** backend on our SDL2, but only after three things none of the existing ports
have:
1. **SDL2: a per-thread current GL context in the Haiku backend.** Without it, every job-thread context switch
   (F12 render, material preview, shader compiles) unlocks another thread's BGLView. HaikuPorts' x86-64
   `blender3` crashes there; on our HGL it is a less predictable lock/context drift (§3.2).
2. **GHOST_SDL asks for the core profile.** Stock GHOST asks for profile 0 and would get our compatibility 3.1,
   which Blender rejects.
3. **EEVEE Legacy patched for 4 colour attachments.** V3D 4.2 has 4 and EEVEE's opaque surface shader writes 6,
   so every lit EEVEE material fails to link.

Workbench (the solid viewport), editing and Cycles CPU rendering need none of the Blender-side GPU patches; Cycles
in background mode needs no GPU at all. Blender 4.x/5.x on OpenGL is out (4.3 required). **Blender 5.3 on Vulkan
(V3DV 1.3) is a separate research track B:** its explicit requirement list passes on V3DV's source, but per-stage
storage-buffer limits, SDL3 and a new dependency wave make it weeks of work with an uncertain end.

Citation keys: **[B36]** Blender v3.6.23 source (`artifacts/downloads/blender/blender-3.6.23`, kept),
**[B40] [B41] [B42] [B45] [B53]** sparse checkouts of tags v4.0.2, v4.1.1, v4.2.23, v4.5.16, v5.3.0 (GPU, GHOST,
build files; only 5.3 kept), **[M]** `sources/mesa` branch `v5-gl` (1986798cb22), **[G]** `sources/libglvnd`
`v5-gl`, **[S]** SDL 2.32.10 as we build it (`artifacts/cross-ports/libsdl2-2.32.10/src` + `patches/libsdl2`),
**[HP]** `sources/haikuports` (`media-gfx/blender/blender3-3.3.21.recipe`).
Numbers are marked *measured* (with how) or *estimated*. Nothing in this document ran on the Pi.

## 1. Which Blender version

| Release | GL support level check | GL path without compute/SSBO? | Vulkan required list vs V3DV | Python pin | GHOST_SDL |
|---|---|---|---|---|---|
| **3.6.23 LTS** | `epoxy_gl_version() >= 33` [B36 `gl_backend.cc:124`] | **yes**: compute only with `ARB_compute_shader && >= 43`, SSBO optional, every user has a fallback (§2.3) | no Vulkan backend for users | 3.10.13 | yes (SDL2) |
| 4.0.2 | `>= 43` [B40 `gl_backend.cc:135`] → "Platform Unsupported … The program will now close" | no | backend without a capability list (not evaluated) | 3.10.13 | yes (SDL2) |
| 4.1.1 | `>= 43` | no: SSBO limits queried unconditionally, no SSBO fallback left [B41 `gl_backend.cc:554-561`] | not evaluated | 3.11.7 | yes |
| 4.2.23 LTS | `>= 43` + driver blacklists | no | no capability list yet [B42 `vk_backend.cc`] | 3.11.7 | yes (GL only) |
| 4.5.16 LTS | `>= 43` | no | **fails**: requires `multiDrawIndirect`, `multiViewport` (V3DV: false) [B45 `vk_backend.cc:141-195`] | 3.11.15 | yes (GL only) |
| 5.3.0 | `>= 43` + ≥ 12 SSBO bindings + `ARB_shader_draw_parameters` + `ARB_clip_control` + `ARB_get_texture_sub_image` [B53 `gl_backend.cc:315-335`] | no | **passes the list** (§1.1) | 3.13.13 | yes, **SDL3**, GL *and* Vulkan [B53 `GHOST_WindowSDL.cc:111`] |

- The 4.x/5.x OpenGL path is out on V3D 4.2, permanently. Besides the version check, the draw manager needs
  compute shaders and SSBOs, which Mesa only exposes with `ARB_shader_image_load_store`. v3d sets
  `image_store_formatted = false`, so `ARB_compute_shader` is off in desktop GL [M `st_extensions.c:569,1717`].
  `ARB_clip_control` needs `clip_halfz`, which is V3D 7.1 only [M `v3d_screen.c:379`]. OpenGL 4.0 also needs
  tessellation and fp64, which V3D 4.2 lacks ([desktop-gl.md](desktop-gl.md) §6.1).
- Even with a version override, 4.x would run into the draw manager's compute/SSBO paths, not just a label.
  (HaikuPorts' x86-64 wrapper sets `MESA_GL_VERSION_OVERRIDE=4.6` because llvmpipe really has 4.5.)
- So the newest Blender with a GL 3.3 path is **3.6.23**. It is end-of-life (the LTS ended 2025), so it is a
  stable target with no moving upstream.

### 1.1 Blender 5.3 on V3DV (track B, not the main line)

5.3's `missing_capabilities_get()` [B53 `vk_backend.cc:143-198`] requires:
- the extensions swapchain, dynamic_rendering, timeline_semaphore, buffer_device_address and
  separate_depth_stencil_layouts;
- the features geometryShader, fragmentStoresAndAtomics, dualSrcBlend, imageCubeArray and
  drawIndirectFirstInstance.

Our V3DV reports Vulkan **1.3** [M `v3dv_device.c:114`] and sets every one of these [M `v3dv_device.c:204-610`].
`multiDrawIndirect` and `multiViewport` are false there, but 5.3 has fallbacks for both [B53
`vk_backend.cc:510-528,887`]. *Source reading, not measured; `blender-vkprobe` checks it (step 0).*

What the list does not check, and is likely to bite:
- **Storage buffers per stage: V3DV `MAX_STORAGE_BUFFERS` = 8** [M `v3dv_limits.h:57`]. The 5.x draw manager binds
  per-object data at SSBO slots 8–11 in vertex shaders [B53 `draw_defines.hh:27-30`]. Blender's GL path refuses
  fewer than 12 bindings. EEVEE (Next) shaders add their own on top. Raising V3DV's limit is probably a descriptor
  bookkeeping change, since v3d GL exposes 32 per fragment/compute stage. *Estimated, unverified.*
- **4 colour attachments** (§2.2), `maxComputeWorkGroupInvocations` 256, no `shaderStorageImageWriteWithoutFormat`.
- **The surrounding stack:**
  - SDL3 instead of SDL2: our Haiku GL-core and Vulkan-surface patches are SDL2 patches; HaikuPorts has
    `libsdl3-3.4.16`.
  - Python 3.13 (we ship 3.14).
  - shaderc at run time.
  - A whole newer dependency set: OIIO 3.1, OCIO 2.5, OpenEXR 3.4, oneTBB 2022.
- **Speed and memory:** EEVEE (Next) is a compute-heavy deferred renderer. On a 4 GB Pi 4 it would be at best a
  curiosity; Workbench might be usable.

Track B is therefore: run the probe, then, only if it is clean, write a separate design note. It is not part of
the milestones below.

## 2. What our OpenGL 3.3 has against Blender 3.6's needs

*Source-derived* (Mesa caps → `st_extensions.c` → what Blender 3.6 reads in `GLBackend::capabilities_init()` /
`detect_workarounds()` / `gl_shader.cc`); step 0 measures it.

### 2.1 Context and version
- Blender 3.6 needs `epoxy_gl_version() >= 33` and nothing else to be "supported". The renderer string "V3D 4.2"
  matches no vendor, so Blender only prints "Could not find a matching GPU name" and treats it as a generic device
  [B36 `gl_backend.cc:117`].
- GLSL is generated as `#version 330` (`#version 430` only for GL ≥ 4.3) [B36 `gl_shader.cc:817-821`].
- Our core profile gives exactly **3.3 / GLSL 3.30** (Pi-measured in desktop-gl.md §6.1, session v5gl2).

### 2.2 The one hard gap: 4 colour attachments
- V3D 4.x has **4 render targets** (`V3D_MAX_RENDER_TARGETS(ver) = ver < 71 ? 4 : 8` [M `v3d_limits.h:44`]), so
  `GL_MAX_DRAW_BUFFERS = GL_MAX_COLOR_ATTACHMENTS = 4` [M `st_extensions.c:154`].
- OpenGL 3.0 and later require 8. This is a **fourth deviation** of our 3.3 that
  [desktop-gl.md](desktop-gl.md) §5 does not list yet. It is also the reason Igalia gave (2020) for V3D stopping at
  desktop GL 2.1 on Linux.
- EEVEE Legacy's `eevee_legacy_material_surface_frag_opaque` declares outputs at `layout(location = 0..5)`: radiance,
  SSR normal, SSR data, SSS irradiance, SSS radius, SSS albedo [B36 `eevee_legacy_material_info.hh:193-200`].
  It is used for **every opaque lit material** [B36 `eevee_shaders.cc:1297`], although the SSR/SSS framebuffer
  slots are only attached when those effects are on [B36 `eevee_engine.c:66`, `eevee_effects.c:181`].
- Mesa refuses to link it: `invalid explicit location 4` once the location reaches `MaxDrawBuffers`
  [M `gl_nir_link_varyings.c:1137-1140`]. The result is the pink "shader error" material in Material Preview and
  Rendered mode, and no EEVEE render.
- This matches the Linux reports for Pi 4 with `MESA_GL_VERSION_OVERRIDE=3.3` ("works damn slow and the lighting
  is broken").
- **Nothing else in 3.6 writes location ≥ 4** (grep of every `fragment_out(4..7` and `layout(location = 4..7) out`
  outside eevee_next: only those two lines). Workbench uses ≤ 3 targets, and so do the overlay and grease pencil.
- **Fix (Blender patch, ~60–100 lines, estimated):**
  - When `GL_MAX_DRAW_BUFFERS < 6`, use an opaque variant that declares only locations 0–2 (radiance + SSR), with
    the SSS writes under a define in `surface_frag.glsl`.
  - Turn Subsurface Scattering off (`EFFECT_SSS`) with a one-time warning; SSS materials render as diffuse.
  - The hardware cannot do more than 4 targets, so Mesa cannot fix this.

### 2.3 Optional features: what is missing, and Blender 3.6's fallback

| Blender 3.6 reads | Our v3d core 3.3 (source) | Effect |
|---|---|---|
| `ARB_compute_shader` && GL ≥ 4.3 | no | GPU subdivision off (CPU subdivision, as on any GL 3.3 GPU) [B36 `subdiv_modifier.cc:104`]; the real-time compositor (3.5+) off; curves/hair via transform feedback [B36 `draw_curves.cc:40-45`] |
| `ARB_shader_storage_buffer_object` | advertised (fragment/compute: 32 blocks when the kernel reports cache flush), but VS/GS have **0** [M `v3d_screen.c:172`, `st_extensions.c:552`] | Blender takes min(VS, FS, CS blocks) and turns SSBOs off below 8 [B36 `gl_backend.cc:563-572`], so: off. Only the draw-debug and EEVEE Next paths use it; both are guarded [B36 `draw_debug.cc`, `eevee_next/eevee_engine.cc:37`] |
| `ARB_shader_image_load_store` | no (`image_store_formatted = false`) | none for Legacy/Workbench |
| `ARB_shader_draw_parameters` | no (no `draw_parameters` cap) | uniform `gpu_BaseInstance` workaround [B36 `gl_shader.cc:863`] |
| `ARB_base_instance` | yes, but Blender ignores it below GL 4.0 | — |
| `ARB_texture_gather` | yes (`max_texture_gather_components = 4`) | — |
| `ARB_texture_cube_map_array` | yes | — |
| `ARB_clear_texture` | no (no cap) | framebuffer-clear fallback |
| `ARB_copy_image`, `ARB_direct_state_access`, `ARB_multi_bind`, `ARB_multi_draw_indirect`, `ARB_vertex_attrib_binding`, `ARB_ES3_compatibility`, `KHR_debug`, `EXT_texture_filter_anisotropic` | yes (Mesa core 3.1+ / v3d caps) | — |
| `AMD_vertex_shader_layer` | no | layered rendering via the geometry shader (V3D has GS) |
| `ARB_gpu_shader5`, explicit binding layouts (4.3) | no | `layout(binding)` emulated by uniform setup |
| geometry shaders | yes (256 vertices, 1024 components) | wide lines and polylines draw through them |
| transform feedback | yes (4 buffers) | hair/curves evaluation |
| max texture size | 4096 | images larger than 4096 are scaled for display (Blender does that itself) |
| max array layers / 3D | 2048 / 4096 | — |
| fragment samplers | 24 (`V3D_MAX_TEXTURE_SAMPLERS`) | ≥ the 16 that 3.6-era GL 3.3 hardware had |
| varying components | 64 (16 vec4) | ≥ GL 3.3's minimum of 60 |
| UBO size | 64 KiB | — |
| buffer-texture texels | **65536** (gallium default; v3d sets no cap) | a limit for big hair systems; possible Mesa change |
| float render targets | RGBA16F, RGBA32F, R11F_G11F_B10F renderable | blending on 32F unverified → step 0 checks it |
| depth clamp, seamless cube maps | emulated / always on (desktop-gl.md §5) | Blender 3.6 never enables GL_DEPTH_CLAMP (grep of source/blender: only dynamic paint's own `depth_clamp` field) and does not rely on non-seamless filtering |

### 2.4 Reference: Pi 4 on Linux
- Raspberry Pi OS ships Blender 3.4.1. It starts only with `MESA_GL_VERSION_OVERRIDE=3.3`, because Linux v3d stops
  at 3.1, and one user got a bus error with it.
- Background rendering works: on a Pi 400 it was about 2× the time of a laptop, at 200–230 % CPU.
- With 1 GB of RAM it crawls.
- Nobody reports a working EEVEE viewport, which fits §2.2.

## 3. Windowing

### 3.1 What exists
- **GHOST_SDL is in 3.6** (`WITH_GHOST_SDL`, needs `WITH_SDL`), about 1600 lines [B36 `intern/ghost/intern/GHOST_*SDL*`].
  It is limited: ASCII-only text input (`TODO … support full unicode` [B36 `GHOST_SystemSDL.cc:605`]), no tablet
  pressure, no IME, no drag-and-drop. Clipboard, cursors, multiple windows and offscreen contexts all work.
- **3.6 already knows Haiku**: `if(HAIKU)` in `platform_unix.cmake`, X11/Wayland skipped [B36
  `CMakeLists.txt:265`], and `__HAIKU__` in blenlib.
- **HaikuPorts** has one recipe, `blender3-3.3.21` [HP], built for **x86_64 only**:
  - `WITH_GHOST_SDL=ON`, Python 3.10, `WITH_TBB=OFF`. TBB off disables Cycles, OpenVDB, USD and fluids [B36
    `CMakeLists.txt:905-908`], so the HaikuPorts Blender has no Cycles.
  - Its launcher sets `MESA_GL_VERSION_OVERRIDE=4.6` and windowed mode (`-p 50 50 1024 768`) as a "WORKAROUND". Do
    not copy the override: at ≥ 43 Blender switches to `#version 430` and compute paths that v3d does not have.
  - Its patchset holds 7 small portability patches (wcwidth, `BLI_threads`, `clock_gettime` UUIDs, `-lnetwork
    -liconv -licu*`, an OpenEXR 3 find module, an OCIO API change, the audaspace CMake minimum). The first also
    `#ifndef __HAIKU__`s out the platform-support dialog.
- **Its known crashes** ([Haiku forum "Blender port"](https://discuss.haiku-os.org/t/blender-port/15541), 2024):
  - F12 render crashes with the render job thread stopped in `GHOST_ContextSDL::activateDrawingContext` →
    `SDL_GL_MakeCurrent` → `HAIKU_GL_MakeCurrent` → `BGLView::UnlockGL` → `_kern_debugger`.
  - The Shading workspace (material preview) crashes too.
- A forum user also built **4.2.3 on x86-64 Haiku** (llvmpipe gives GL 4.5 there). That does not apply to V3D.

### 3.2 Why it crashes: one process-wide current context
- SDL2's Haiku backend keeps the current context in the application object, `SDL_BApp::_current_context` [S
  `src/main/haiku/SDL_BApp.h:233-240`]. `HAIKU_GL_MakeCurrent()` unlocks *that* view and locks the new one.
- `BGLView::LockGL()` takes `fDisplayLock`, a BLocker owned by the locking thread [G `src/HGL/GLView.cpp:492-518`].
  On **our** stack, `UnlockGL()` from another thread only prints "UnlockGL is called from wrong thread". It then
  calls `eglMakeCurrent(NO_CONTEXT)` on the *calling* thread and unlocks the BLocker anyway, and
  `BLocker::Unlock()` from a non-owner also only prints "Unlocking BLocker … from wrong thread" ("the Be Book
  explicitly allows any thread … to unlock" [`sources/haiku` `src/kits/support/Locker.cpp:114-125`]). The
  HaikuPorts x86-64 trace stopped in `_kern_debugger` on a different HGL.
- Blender makes contexts current on other threads all the time:
  - the shader-compilation job [B36 `draw_manager_shader.c:82-88`];
  - render (F12) via `DRW_render_context_enable` [B36 `draw_manager.c:3131-3150`];
  - light baking, and preview renders.
- So the first worker-thread `SDL_GL_MakeCurrent` unlocks the main thread's view from the worker, and the
  worker's release unlocks the main thread's again. That is the HaikuPorts trace. On our stack it may not crash
  at once: each thread unbinds its own EGL context and releases the other's lock, so lock counts and "which context
  is current where" drift until something deadlocks, draws into nothing or (with debug checks) stops. The
  bug is the same, the symptom is less predictable, and a probe that only checks rendered results can pass with
  the bug present. Hence the step-0 grading on the "wrong thread" lines.
- Mesa/EGL themselves are per-thread: `eglMakeCurrent` binds to the calling thread, and the HGL view already
  passes `BGL_SHARE_CONTEXT` to `eglCreateContext` with the caller's current context [G `GLView.cpp:298-300`].
  `blender-glprobe -e` checks that the driver side works with two threads.

**Fix: an SDL2 patch, `libsdl2-2.32.10-haiku-gl-thread-context.patch` (estimated 30–60 lines).**
- Make `_current_context` thread-local (`static thread_local BGLView *`, or a TLS slot keyed per thread).
- `HAIKU_GL_MakeCurrent(NULL)` then unlocks only the calling thread's view, and making a context current locks it
  on the calling thread.
- Programs that use one thread do not change (STK, Quake II, the games).
- Done (M1, §7.2): SDL's TLS (`SDL_TLSCreate`, as `SDL_video.c` keeps `SDL_GL_GetCurrentContext()`), not
  `thread_local`: GCC's aarch64 default TLS dialect is descriptors, and Haiku's arm64 runtime loader has no
  `R_AARCH64_TLSDESC` relocation.

Blender's alternative, `GPU_use_main_context_workaround()`, is not enough: with it the job threads still activate
the main context from their own thread, under a lock [B36 `draw_manager_shader.c:83-88`].

### 3.3 Core profile
- GHOST_SDL asks for profile mask **0**, version 3.3, both for windows [B36 `GHOST_WindowSDL.cc:67-73`] and for
  offscreen contexts [B36 `GHOST_SystemSDL.cc:130-136`].
- Our SDL2 patch only goes core on `SDL_GL_CONTEXT_PROFILE_CORE` ([desktop-gl.md](desktop-gl.md) §4). A
  profile-0 request gets compatibility **3.1**, which fails `>= 33` and makes Blender quit with "Platform
  Unsupported".
- The fix is a two-line Blender patch: `SDL_GL_CONTEXT_PROFILE_CORE` in both places.
- This needs the **desktop-GL merge** (mesa + libglvnd `v5-gl`, SDL2 glview-core patch); Blender cannot start on the
  release stack (2.1).

### 3.4 libepoxy
- 3.6 replaced GLEW with **libepoxy** (`find_package_wrapper(Epoxy REQUIRED)` [B36 `platform_unix.cmake:110`]).
  HaikuPorts' 3.3.21 still used GLEW, so epoxy + Blender on Haiku is new.
- *Measured (host):* HaikuPorts' `libepoxy-1.5.8` recipe cross-builds with `scripts/cross-port.sh … meson
  -Degl=yes -Dglx=no -Dx11=false -Dtests=false` in **13 s, 340 MB peak**.
- It dlopens `libGL.so.1`, `libEGL.so.1` and `libOpenGL.so.0` (from `strings`). Those are exactly our libglvnd
  sonames.

### 3.5 Native GHOST_SystemHaiku instead?
- About 2.5–4 k lines (estimated), against GHOST_SystemX11 + WindowX11 at 4416 lines and Cocoa at 3246 [B36]: a
  BApplication/BWindow/BGLView system, input, cursors, clipboard, drag-and-drop, tablet, full Unicode.
- It would remove the SDL limits, but it is not needed for a first working Blender, and it would have to solve the
  same per-thread BGLView problem.
- **Decision: SDL first**; a native GHOST is a later polish milestone, only if the SDL limits hurt.

## 4. Dependencies

3.6's hard requirements [B36 `platform_unix.cmake:106-158,446,552`]:
- JPEG, PNG, ZLIB, Zstd, Epoxy, Freetype, Threads;
- **OpenImageIO (REQUIRED, unconditional)**, which needs OpenEXR + Imath, TIFF and, for 2.4, Boost (*recalled*,
  not checked against OIIO's CMake; HaikuPorts' OIIO 2.5 recipe still lists `boost_thread`);
- Python (technically optional, but the UI is written in Python).

TBB gates Cycles. Everything else can be switched off.

| Library | Needed by | 3.6 pin | Min build | Full build | HaikuPorts recipe | Ours today | Effort (est.) |
|---|---|---|---|---|---|---|---|
| zlib, libpng16, libjpeg_turbo, freetype, zstd, libwebp | core / imbuf | — | yes | yes | yes | **packaged** (`artifacts/packages`) | 0 |
| libepoxy | GPU module | — | yes | yes | 1.5.8 (all) | **cross-builds, measured** | 0.1 d |
| SDL2 | GHOST + audio | 2.0.20 | yes | yes | 2.32.10 | **packaged** (+ thread patch, §3.2) | 0.5 d |
| Python | UI, add-ons | **3.10.13** | yes | yes | python3.10-3.10.22 (all) | 3.14 only | 0.5–1 d (§4.1) |
| Boost (filesystem, regex, thread, date_time, system; +locale for i18n) | OIIO 2.4; i18n, OpenVDB, USD, OSL, Quadriflow | 1.80 | headers + 5 libs | + locale, iostreams | boost1.83 … 1.91 | no | 0.5 d (b2 has no cross-port mode: a `script` build with a user-config.jam) |
| Imath + OpenEXR | OIIO, EXR I/O | 3.1.7 | yes | yes | openexr3.2-3.2.4 (+ libdeflate) | no | 0.3 d |
| libtiff | OIIO | 4.5.1 | yes | yes | yes | no | 0.1 d |
| OpenImageIO | **required** | 2.4.15 | yes (only EXR/TIFF/PNG/JPEG/WebP plugins; no OCIO, raw, heif, gif) | + OpenJPEG | openimageio2.3/2.5 | no | 1 d (cross configure, its `build_missing_deps` for fmt/robin-map) |
| oneTBB | Cycles, threading | 2020U3 (3.6 also takes oneTBB: `TBB_INTERFACE_VERSION_MAJOR >= 12` [B36 `task_pool.cc:112`]) | yes | yes | tbb-2022.3.0 — **its patchset is needed**: stock headers stop with `#error "Unknown platform/compiler"` (*measured*) | no | 0.3 d |
| sse2neon | Cycles SIMD on arm64 | header | yes | yes | — | no | 0 (one header) |
| OpenColorIO (+ yaml-cpp, pystring, expat, minizip-ng) | colour management | 2.2.0 | off (sRGB fallback) | yes | opencolorio2.3-2.3.2 | no | 0.5–1 d |
| numpy | add-ons, audaspace/mantaflow | 1.23.5 | off | 1.26.4 (meson build, like our 2.5.4) | numpy_python310-2.2.6 | 2.5.4 for 3.14 | 0.5 d |
| fftw3 | ocean, smoke, audio FX | 3.3.10 | off | yes | yes (all) | no | 0.2 d |
| OpenSubdiv | GPU/CPU subdivision | 3.5.0 | off (Blender's own subsurf) | yes (CPU) | 3.5/3.7 | no | 0.3 d |
| FFmpeg | video I/O, VSE | 6.0 | off | ffmpeg6 | ffmpeg6 | **packaged** 6.1.6 | 0 |
| OpenAL / libsndfile / audaspace | audio | — | off | SDL audio + sndfile | yes | no | 0.3 d |
| Embree | Cycles BVH | 4.1.0 | off (Cycles' own BVH2) | 4.x (arm64 via its NEON path); HaikuPorts has only **3.12.2**, too old for arm64 (*recalled*: arm64 arrived in Embree 3.13; check at M6) | 3.12.2 | no | 1 d |
| OpenVDB (+ blosc, Boost iostreams) | volumes | 10.0 | off | maybe | openvdb-13 / openvdb7 | no | 1 d (heavy C++) |
| Alembic, USD, MaterialX, OpenCOLLADA | interchange | — | off | Alembic, COLLADA maybe; USD later (very heavy) | alembic 1.8.3, opencollada | no | 0.5 d each, USD 2+ d |
| OSL (+ LLVM), OpenImageDenoise (+ ISPC), OpenPGL, OpenXR, GMP, potrace, libharu, jemalloc | Cycles OSL, denoise, path guiding, VR, exact booleans, grease-pencil export | — | off | GMP, potrace, haru cheap; OSL/OIDN/OpenPGL no (LLVM / ISPC cross builds) | partly | no | — |

**Minimal first build (M2):**
```
-DWITH_GHOST_SDL=ON -DWITH_SDL=ON -DWITH_PYTHON=ON -DPYTHON_VERSION=3.10 -DWITH_PYTHON_INSTALL=OFF
-DWITH_PYTHON_NUMPY=OFF -DWITH_TBB=ON -DWITH_CYCLES=ON -DWITH_CYCLES_EMBREE=OFF -DWITH_CYCLES_OSL=OFF
-DWITH_CYCLES_PATH_GUIDING=OFF -DWITH_CYCLES_DEVICE_{CUDA,OPTIX,HIP,METAL,ONEAPI}=OFF -DWITH_OPENIMAGEDENOISE=OFF
-DWITH_OPENCOLORIO=OFF -DWITH_OPENSUBDIV=OFF -DWITH_OPENVDB=OFF -DWITH_NANOVDB=OFF -DWITH_USD=OFF -DWITH_ALEMBIC=OFF
-DWITH_MATERIALX=OFF -DWITH_OPENCOLLADA=OFF -DWITH_MOD_FLUID=OFF -DWITH_CODEC_FFMPEG=OFF -DWITH_AUDASPACE=OFF
-DWITH_OPENAL=OFF -DWITH_JACK=OFF -DWITH_PULSEAUDIO=OFF -DWITH_CODEC_SNDFILE=OFF -DWITH_FFTW3=OFF -DWITH_GMP=OFF
-DWITH_POTRACE=OFF -DWITH_HARU=OFF -DWITH_XR_OPENXR=OFF -DWITH_INPUT_NDOF=OFF -DWITH_INPUT_IME=OFF
-DWITH_MEM_JEMALLOC=OFF -DWITH_IMAGE_OPENJPEG=OFF -DWITH_DRACO=OFF -DWITH_GTESTS=OFF -DWITH_BUILDINFO=OFF
-DWITH_INTERNATIONAL=OFF -DWITH_QUADRIFLOW=OFF -DWITH_LIBMV=ON -DWITH_BULLET=ON
```
That needs 9 new ports: epoxy, Boost (5 libs), Imath, OpenEXR, libtiff, OIIO, oneTBB, sse2neon and Python 3.10.

**Fuller build (M6):** add OCIO, numpy 1.26, OpenSubdiv, FFmpeg, audaspace (SDL audio + sndfile), fftw, GMP,
potrace, libharu, Alembic, OpenCOLLADA, Embree 4, i18n (Boost locale), mantaflow. Then evaluate OpenVDB and USD on
their own.

### 4.1 Python: a private 3.10, not our 3.14
- Blender 3.6 uses CPython private API in about **180 places** (*measured*, grep of `_Py*` in source/ and intern/):
  - `_PyArg_Parser` and `_PyArg_ParseTupleAndKeywordsFast` ×69;
  - `_Py_IDENTIFIER` / `_PyObject_GetAttrId`, whose public forms 3.12 removed;
  - `_PyLong_AsInt`, `_PyObject_LookupAttr`, `_PySet_NextEntry` and `_PyThreadState_UncheckedGet`, which 3.13
    removed.
  - (The counts are measured. Which CPython release removed each name is *recalled*, not checked against
    CPython's headers.)
- 4.x/5.x carry a compatibility layer for these; 3.6 does not. Porting 3.6 to 3.14 means backporting it (2–4 d,
  estimated), with every add-on then running on a Python it was never tested with.
- **Decision: build CPython 3.10.22** from HaikuPorts' `python3.10` recipe, generalising `scripts/build-python.sh`
  (today hard-wired to 3.14.8) to take the version. Package it as `python3.10` (+ `_devel`), as HaikuPorts did for
  x86-64 `blender3`.
- Add `numpy_python310` 1.26.4 in the fuller build (Blender's pin is 1.23.5; 1.26 builds with meson like our 2.5.4).
- It coexists with python3.14; Blender links `libpython3.10.so.1.0`.

### 4.2 Build-time generators: Blender does not cross-compile by itself

Blender builds tools and then runs them during its own build:
- `makesdna` → `dna.c`, `dna_type_offsets.h`, `dna_verify.c` [B36 `makesdna/intern/CMakeLists.txt:78-99`];
- `makesrna` → the `rna_*_gen.c` files [B36 `makesrna/intern/CMakeLists.txt:387-406`];
- `datatoc` / `datatoc_icon` for GLSL sources, fonts and icons [B36 `build_files/cmake/macros.cmake:960-1025`];
- `msgfmt` for translations (off in the minimal build).

There is no `CMAKE_CROSSCOMPILING` handling anywhere in 3.6 (grep: none). With `tools/cmake/haiku-arm64.cmake`
these become arm64 Haiku executables the Linux host cannot run, and HaikuPorts never met this because it builds
natively.

Plan:
1. Configure the same 3.6.23 tree for the **host** (Linux, system compiler) with the same `WITH_*` options. RNA
   output depends on them through `#ifdef`s, and the host configure needs host development packages or stub find
   modules for its REQUIRED libraries.
2. Build only `makesdna makesrna datatoc datatoc_icon`.
3. In the cross configure, a small CMake patch: `if(CMAKE_CROSSCOMPILING)` → `add_executable(<tool> IMPORTED)`
   with `IMPORTED_LOCATION` from `-DBLENDER_HOST_TOOLS=DIR` instead of building the tool.

The struct layout is safe to share: the host (x86-64) and the target (arm64) are both LP64 little-endian, and
`dna_verify.c`, compiled for the target, asserts every DNA struct size against what `makesdna` computed, so any
difference fails the build instead of corrupting .blend files.

`PYTHON_EXECUTABLE` is used at build time only by audaspace's Python module (off in the minimal build) [B36
`extern/audaspace/CMakeLists.txt:1133-1143`]; that would need the host Python, not the target's 3.10.

Fallback: build the generators natively on the Pi with our native GCC package and copy them back. That is slow
and needs the bench, so it is not preferred.

## 5. Engines and performance

- **Cycles (CPU only).** On arm64, Cycles uses NEON through sse2neon. Without it, `util/simd.h` falls back to
  scalar.
  - *Measured (host):* the Cycles CPU kernel TU (`intern/cycles/kernel/device/cpu/kernel.cpp`, the heaviest TU of
    the build) compiles with our GCC 16.2 cross compiler at `-O2` for Haiku arm64, without NEON/sse2neon, with no
    errors: **26.5 s, 620 MB peak RSS**.
  - Run time on 4× A72 at 1.5–1.8 GHz, *estimated* from the Pi 400 "about 2× a laptop" report and A72 IPC: the
    default cube at 960×540 with 128 samples takes about 1–3 min; classroom/BMW-class scenes take hours.
  - Background mode needs no GPU at all, so M3 is independent of every GL question.
- **Workbench + overlays (the solid viewport, edit mode, the UI):**
  - Everything is GL 3.3 + geometry shaders + transform feedback, with ≤ 3 colour targets. *Expected to work.*
  - Speed is unknown. *Estimated* 10–30 fps for the default scene at 1280×720, from SuperTuxKart's shader path at
    13–19 fps and Quake II GL3 at 67–72 fps at 720p (desktop-gl.md §7).
  - Shader compiles on the A72 add first-use stalls: about 100–300 ms each, dozens at start-up, *estimated*.
- **EEVEE Legacy:**
  - Blocked by §2.2 until patched.
  - After the patch it works without SSS.
  - Soft shadows, SSR, AO and bloom will be slow: low single-digit fps in Rendered view, *estimated*.
  - Material shaders take seconds each to compile on the A72 (*estimated*). This is EEVEE's own compile-time
    problem, made worse on V3D.
- **Memory (Pi 4, 4 GB):**
  - *Estimated* 250–400 MB RSS for the default scene with Python. V3D buffers come out of the same RAM.
  - Workable for small scenes; heavy scenes and Cycles with large textures will hit the 4 GB.
  - Background renders on the 1 GB Pi 4 crawl (Linux report).
- **Build cost on the host** (16 cores, 29 GB, shared):
  - *Measured* `-O2` cross compiles: 40 blenlib TUs at 0.20 s mean, 174 MB peak; 22 TUs of the GL backend +
    GHOST_SDL at 0.72 s mean, 227 MB peak; the Cycles kernel at 26.5 s / 620 MB.
  - *Measured syntax check* (`-fsyntax-only`, our GCC 16.2, the Haiku sysroot): **154 of 160 TUs** of blenlib, the
    GL backend and GHOST_SDL pass. All 6 failures are include paths missing from the probe (zstd, Eigen C API,
    json, a Windows file), not GCC 16 or Haiku problems.
  - Blender 3.6 has about 4,440 C/C++ TUs (3219 source/, 461 intern/, 758 extern/; *measured* by count).
  - *Estimated* full build: 2–4 CPU-hours, so about 20–40 min at `-j8` under `scripts/heavy-build.sh -j 8
    --mem-per-job 2` (≤ 16 GB). The heavy TUs (mantaflow, Cycles, some nodes) are 1–3 GB each.
  - *Estimated* link of the `blender` binary without debug info: 3–5 GB with ld.bfd.
  - Dependencies take another 1–2 h in total, *estimated*.
  - Disk: build tree 6–10 GB, install about 500 MB, *estimated*.

## 6. Risks and blockers, each with a cheap way to find out

| # | Risk | Cheap check |
|---|---|---|
| R1 | **The SDL thread bug** (§3.2): cross-thread BGLView unlocks. HaikuPorts' x86-64 render/preview crash; on our HGL a quieter lock/context drift. Certain on stock SDL2. | `blender-probe.sh` step 0: the `sdlthread` line counts "wrong thread" messages (FAIL when > 0) beside the probe's own render checks. After the patch: 0 lines and all `-t` checks PASS. |
| R2 | **The EEVEE Legacy 6-output shader** (§2.2). Certain from source. | `blender-glprobe` `mrt6` INFO line (step 0); M5 patch + Material Preview. |
| R3 | The desktop-GL stack is not merged yet (Blender needs core 3.3: mesa/libglvnd `v5-gl` + SDL2 glview-core). | Done when desktop-gl.md §8 is merged; until then the -91 test packages (step 0). |
| R4 | Mesa/EGL with shared contexts on two threads, on Haiku (never exercised: our GL programs use one thread). | `blender-glprobe -e` (step 0). |
| R5 | Float RT blending (RGBA32F), buffer-texture formats, transform feedback, textureGather on v3d. | `blender-glprobe` float/tbo/xfb/gather checks (step 0). |
| R6 | Cross-building the C++ dependency stack (Boost b2, OIIO's own dependency fetching) for Haiku arm64. Recipes exist for x86-64 Haiku only in practice. | Imath + OpenEXR + libtiff first (0.5 d): if those three go through `cross-port.sh` clean, OIIO is the only real unknown. |
| R7 | GCC 16 / Haiku arm64 compile failures in Blender itself. | Partly measured: 154/154 reachable TUs pass, plus the Cycles kernel. The rest shows at M2's first `ninja -k 0`. |
| R8 | Blender's Python/numpy/add-on start-up on a freshly cross-built 3.10. | M3: `blender -b --factory-startup --python-expr "import bpy; print(bpy.app.version_string)"` |
| R9 | Performance too low to be "usable": viewport fps, shader-compile stalls, 4 GB. | M4/M5 measurements; fallback: Workbench-only + Cycles is still a full modelling/rendering suite. |
| R10 | GHOST_SDL limits (no Unicode text input, no tablet, windowed-mode quirks HaikuPorts worked around with `-p`). | M4 hands-on list; a native GHOST is the known remedy (§3.5). |
| R11 | Track B (5.3/Vulkan): SSBO-per-stage limit and attachments; SDL3; deps. | `blender-vkprobe` (step 0); everything else waits for it. |
| R12 | **Build-time generators** (§4.2): Blender runs `makesdna`, `makesrna`, `datatoc`, `datatoc_icon` (+ `msgfmt` with i18n) that it builds itself; a cross build makes them Haiku binaries the host cannot run, and 3.6 has no `CMAKE_CROSSCOMPILING` path. | M2 step 1: a host-native configure that builds only those targets, with the same `WITH_*` options; then the cross configure imports them. The DNA layout check (`dna_verify.c`, compiled for the target) catches any host/target struct-layout difference at compile time. |

## 7. Plan

Effort is in agent-days (one autonomous working day including builds), *estimated*.

### Step 0 — the Pi probe (one bench session, about 20 min; needs the bench)

Prerequisites, all on the host already:
- `artifacts/desktop-gl/mesa-26.2.7-91-arm64.hpkg` (mesa `v5-gl` test package);
- `artifacts/desktop-gl/libSDL2-2.0.so.0` (SDL2 with the glview-core patch);
- `artifacts/gl-build/gl-tests/glinfo`;
- the two probes, built below.
Image: the newest regular image, `artifacts/images/haiku-pi4-2026-11-19.img`. No games are needed. If its Mesa is
already the merged desktop-GL Mesa (26.2.7 newer than -3 with core 3.3), skip the `pkgman install` line.

```
# host: build the probes (both warning-free with exactly these commands, checked 2026-11-19)
CC=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
S=artifacts/sysroot-arm64
mkdir -p artifacts/blender-probe
$CC --sysroot=$S -std=gnu11 -O2 -Wall -Wextra -I$S/boot/system/develop/headers -Isources/mesa/include \
    tools/gl-tests/blender-glprobe.c -o artifacts/blender-probe/blender-glprobe \
    -L$S/boot/system/develop/lib -lSDL2 -lEGL
$CC --sysroot=$S -std=gnu11 -O2 -Wall -Wextra -Isources/mesa/include tools/gl-tests/blender-vkprobe.c \
    -o artifacts/blender-probe/blender-vkprobe $S/boot/system/lib/libvulkan.so.1
cp artifacts/gl-build/gl-tests/glinfo artifacts/desktop-gl/libSDL2-2.0.so.0 artifacts/blender-probe/

# Pi: one session
scripts/pi-session.sh start --image artifacts/images/haiku-pi4-2026-11-19.img --minutes 60 --label blprobe
scripts/pi-ssh.sh put artifacts/blender-probe artifacts/desktop-gl/mesa-26.2.7-91-arm64.hpkg \
    tools/pi-tests/blender-probe.sh /boot/home/
scripts/pi-ssh.sh pkgman install -y /boot/home/mesa-26.2.7-91-arm64.hpkg
scripts/pi-ssh.sh sh /boot/home/blender-probe.sh /boot/home/blender-probe blprobe > artifacts/blender-probe/blprobe.txt
scripts/pi-session.sh stop
```

Read the result:
- **Expected PASS:**
  - `ghost-core … 3.3`; `mrt4`; float RGBA16F, RGBA32F and R11F_G11F_B10F blend; the five tbo formats; xfb;
    gather;
  - `egl threads`.
- **Expected INFO:**
  - `ghost-stock` gets 3.1 (the GHOST patch is needed);
  - `mrt6 link: fails … invalid explicit location 4`;
  - `limit MAX_DRAW_BUFFERS 4`;
  - `limit MAX_TEXTURE_BUFFER_SIZE 65536`.
- **Expected FAIL (R1 reproduced):** `BPR blprobe sdlthread: FAIL N cross-thread BGLView unlocks`, with stock
  SDL2. The probe's own `sdl thread:` render checks may still PASS on our HGL (§3.2). A `crash:` line from
  `debug_server` is the HaikuPorts form of the same bug.
- **Vulkan:** `BVK Blender 4.5 list: 2 missing; Blender 5.3 list: 0 missing`, plus the
  `maxPerStageDescriptorStorageBuffers 8` line.
- **What changes the plan:**
  - any FAIL in float/tbo/xfb/gather adds a Mesa item;
  - an `egl threads` FAIL becomes a Mesa/HGL item ahead of M1;
  - a 5.3 list with anything missing closes track B.

### Milestones

| M | What | Pass criterion | Effort |
|---|---|---|---|
| **M1** | SDL2 `haiku-gl-thread-context` patch (§3.2); libsdl2 revision with glview-core + thread patches | `blender-probe.sh`: `sdlthread: PASS no cross-thread BGLView unlocks` and the three `sdl thread:` checks PASS; STK, Quake II GL3 and the `desktop-gl.sh` regression list unchanged | 0.5–1 d |
| **M2** | Host-native generator build (§4.2: `makesdna`, `makesrna`, `datatoc`, `datatoc_icon`, imported into the cross build by a small CMake patch, ~1–1.5 d). Dependency stack for the minimal build (§4): epoxy, Imath, OpenEXR, libtiff, Boost subset, oneTBB (HaikuPorts patchset), OIIO 2.4.15, sse2neon, Python 3.10.22 (`build-python.sh --version`); a `scripts/build-blender.sh` that configures Blender 3.6.23 with `tools/cmake/haiku-arm64.cmake` and the §4 minimal options + HaikuPorts' 7 patches + ours (GHOST core profile), all under `heavy-build.sh` | `blender` links for Haiku arm64; each dependency packaged with `package-port.py` | 4–6.5 d |
| **M3** | Headless: `blender -b --factory-startup -E CYCLES -o /boot/home/cube_#### -f 1` on the default scene (and `--python-expr` for bpy) | a PNG of the default cube rendered by Cycles on the Pi, render time logged; 0 PANIC | 0.5–1 d |
| **M4** | UI through GHOST_SDL: windowed start, Workbench viewport, edit mode, save/load .blend, preferences window (second SDL window), F12 Cycles render into the image editor | hands-on checklist + HDMI screenshots; viewport fps measured on the default scene and on a 100 k-triangle mesh | 1–2 d |
| **M5** | EEVEE Legacy on 4 targets: Blender patch (§2.2; SSS off, 3-output opaque variant), shader-compile timing | Material Preview and an EEVEE F12 render of a lit scene correct (compare with an x86-64 reference render of the same .blend); SSS-off warning shown once | 1–2 d |
| **M6** | Fuller build (§4) + packaging: `blender` hpkg (+ `python3.10`, deps) in our repo, Deskbar entry, launcher without any GL override, docs (README, KNOWN-ISSUES, USER-GUIDE, HAIKU-RPI4-CHANGES) per RELEASING.md | `pkgman install blender` on a release image starts it; mega-smoke unaffected | 2–4 d |
| M7 (later) | native GHOST_SystemHaiku (§3.5) if the SDL limits (Unicode input, tablet, window quirks) matter in use | — | 4–8 d |
| Track B | Blender 5.3 on V3DV: only if step 0's 5.3 list is clean — then a separate design note (SSBO limit in V3DV, SDL3 port of our Haiku patches, Python 3.13/3.14, the 5.x dependency set) | — | weeks |

Total to a usable, packaged Blender 3.6 (M1–M6): **9–16.5 agent-days**, *estimated*. The first visible result,
Cycles rendering on the Pi (M3), comes after about 6–8.5 of those.

### Mesa / v3d work this may need
- **None for M1–M4**, if step 0 passes.
- Optional:
  - raise `max_texel_buffer_elements` above the 65536 default, for big hair systems (V3D's TMU can address more);
  - document the 4-draw-buffer deviation in desktop-gl.md §5 / KNOWN-ISSUES.
- Track B only: raise V3DV `MAX_STORAGE_BUFFERS` from 8 to ≥ 12.

### 7.1 Step 0 result (2026-11-19, release image-2026-11-19 in a network session; artifacts/blender-probe/bp3.txt)

Run on the release image itself (its mesa 26.2.7-3 + libsdl2 2.32.10-7 are the desktop-GL stack; no -91 package).
The first two runs (gate sessions A and B) gave "status 3" for every program: `blender-probe.sh` set
`LIBRARY_PATH=$dir:` in a shell without LIBRARY_PATH, so the runtime loader found no libEGL/libvulkan — fixed (the
default search path is kept). Third run — every prediction of §2/§3 held:
- `ghost-stock` (profile 0, 3.3) → **3.1** compatibility (GLSL 1.40): the GHOST patch is needed; `ghost-core` →
  **3.3 core**, GLSL 3.30: PASS.
- PASS: mrt4 link + framebuffer; RGBA16F / RGBA32F / R11F_G11F_B10F blending; texture buffers R32F, RG32F, RGBA32F,
  RGBA8, R32UI; transform feedback; textureGather; EGL shared context current on a second thread.
- INFO as expected: **mrt6 does not link** ("invalid explicit location 4") — EEVEE Legacy's opaque shader needs the
  M5 patch; MAX_DRAW_BUFFERS = MAX_COLOR_ATTACHMENTS = 4; MAX_TEXTURE_BUFFER_SIZE 65536; MAX_TEXTURE_SIZE 4096;
  GL_ARB_shader_draw_parameters, GL_ARB_gpu_shader5, GL_ARB_shader_image_load_store: no.
- SDL thread check: the probe's own checks PASS, but **2 "Unlocking BLocker … from wrong thread"** lines: SDL2's
  one process-wide current context, as predicted — M1 (per-thread current context) is required.
- Vulkan (V3DV 1.3, conformance 1.3.8.3): maxPerStageDescriptorStorageBuffers **8** (Blender 5.x binds 12),
  multiDrawIndirect and multiViewport **no** — track B stays blocked on V3DV limits.
- 0 debugger entries.

So M1 can start as planned; no Mesa work is needed for M1–M4.

### 7.2 M1 result (2026-11-19, session sdlm1 on the mega image; artifacts/blender-probe/m1/)

`patches/libsdl2/libsdl2-2.32.10-haiku-gl-thread-context.patch` (SDL_BApp.h, +15/−8 lines): `SDL_BHandler` keeps
the current BGLView in an SDL TLS slot instead of one member, so `SetCurrentContext()` unlocks only the view the
calling thread locked. libsdl2 **2.32.10-8** = the six earlier patches + this one
(`artifacts/packages-test/libsdl2-8/`, not published).
- `blender-probe.sh` with -8 in the probe directory: **`sdlthread: PASS no cross-thread BGLView unlocks`**, the
  three `sdl thread:` checks PASS (only the sdlthread part of that run was kept).
- Same session, `blender-glprobe -t` per library: -7 → 2 "wrong thread" lines, 3 PASS; -8 → 0, 3 PASS; a traced
  -8 build shows the job thread locking and unlocking only its own view (`t-diag.txt`).
- Unchanged, -7 vs -8 (each loaded through LIBRARY_PATH; single runs): SuperTuxKart
  `force_legacy_device="false"` **3.3 core, shader renderer, race completes**, 16.1 vs 16.8;
  Quake II GL3 "got version 3.3", 58.5 vs 58.6 fps (timedemo, 1280×720); GL1 60.0 vs 60.0; `desktop-gl.sh`
  (its programs do not link SDL2) 0 failures. SuperTuxKart legacy (the default) with -8: 3.1, 42.1 egl frames/s
  (the image's own SDL2 copy, desktop-gl.md §7.1: 37.7; the gate's range 35–50).
- Not covered: deleting a context that is current on *another* thread (that thread's slot then points at a
  deleted view; a program error on every platform), and making one view current on two threads at once (the
  second `LockGL()` now waits for the first thread to release it, where EGL returns `EGL_BAD_ACCESS`).

### 7.3 M2 result (2026-11-19, host only; `scripts/build-blender.sh`, commits e7af9d7, 3360d6a + the clean-run follow-up)

**`blender` links**: `artifacts/cross-ports/blender-3.6.23/build/bin/blender`, AArch64, 75 MB (57 MB stripped),
4537 build steps, 150 compiler warnings (Cycles `-Warray-bounds`/`-Wclass-memaccess` and the like), no
TLSDESC relocations (GCC's Haiku spec forces `-mtls-dialect=trad`), no run path. It needs 27 libraries; all
**1381 undefined dynamic symbols resolve** against those libraries in the sysroot (checked with `nm -D`).
Python 3.10, TBB (Cycles), SDL2 (GHOST_SDL), OIIO, OpenEXR, WebP, pugixml, epoxy are linked.
- **Dependencies** (each `cross-port.sh` + `package-port.py --out artifacts/packages-test/blender`, not
  published): libdeflate 1.18, Imath 3.1.12 (our recipe, `tools/recipes`), OpenEXR 3.2.4 (HaikuPorts recipe +
  patchset, against that Imath), libtiff 4.7.0 (zlib + JPEG only, no libtiffxx: libtool's C++ link names a
  libstdc++.a path that does not exist), libepoxy 1.5.8, Boost 1.83 (thread, chrono, atomic, date_time,
  system, filesystem; b2 with a `gcc-haiku` toolset in a user-config.jam; Blender itself runs `WITH_BOOST=OFF`,
  only OIIO links Boost), oneTBB 2022.3.0 (recipe patchset), **OpenImageIO 2.4.15.0** (our recipe;
  HaikuPorts' 2.5.12 patchset applies unchanged; fmt 9.1.0 + robin-map 0.6.2 pinned, not git-cloned;
  every optional reader the sysroot could offer — FFmpeg, FreeType, GL, OCIO, … — off explicitly, and the
  script checks its NEEDED list), **pugixml 1.15** (new: Blender 3.6 looks for OIIO's internal copy as
  `OpenImageIO/pugixml.hpp`, OIIO 2.4 keeps it in `detail/pugixml/` and its own namespace, so Cycles'
  XML reader failed with `pugixml.hpp: No such file`; `WITH_PUGIXML=ON` now), sse2neon 1.6.0 (header only,
  `sse2neon_devel`), FreeType 2.14.3 with Brotli (static, Blender's own: the sysroot's has no Brotli).
- **Python 3.10.22**: `build-python.sh --version 3.10.22` (+ `--out`). 3.10 still builds its modules with
  setup.py: configure finds `python3.10` on PATH (no `--with-build-python`); `patches/python3.10/0001` adds
  Haiku to the cross-build host list and makes setup.py match `haiku-aarch64`. Two silent traps fixed: setup.py
  took `--with-system-libmpdec=no` for "yes" (no `_decimal`), and the bootstrap `libffi.pc` names
  `/packages/…/.self`, so `_ctypes` was linked **without libffi** (now a checked failure). `make altinstall`:
  no unversioned names. 2 min per build.
- **Host generators (R12)**: `makesdna makesrna datatoc datatoc_icon smaa_areatex` — `smaa_areatex`
  (compositor) is a fifth one §4.2 did not list — built for the host from the same tree and
  `tools/cmake/blender-minimal.cmake` (8 s). `patches/blender/0002` imports them as `IMPORTED GLOBAL`
  executables when `-DBLENDER_HOST_TOOLS=DIR` is set (msgfmt too, for i18n later). Guards: the cache
  compare of `WITH_*:BOOL` (143 equal) alone is blind — `set_and_warn_library_found` turns an option off with
  a normal variable that shadows the cache (the host's first "WebP not found, disabling WITH_IMAGE_WEBP" would
  have passed it) — so the options file sets `WITH_STRICT_BUILD_OPTIONS=ON` (a missing library is an error)
  and the script also compares the `-DWITH_*` defines makesrna's sources get on the host with those of the
  same sources in `bf_rna` for the target (10 equal; the cross build's global `WITH_SSE2NEON` aside).
  `dna_verify.c` compiled for the target without error.
- **Blender patches** (`patches/blender/`): 0001 GHOST_SDL core profile (windows and offscreen contexts), 0002
  host generators, 0003 HaikuPorts' libmv `<assert.h>`. Not taken from HaikuPorts' 3.3.21 patchset: wcwidth
  and uuid (Haiku now has `<uchar.h>` and `timespec_get`), `BLI_threads` pthread-key TLS (`__thread` works on
  arm64), the platform-support dialog (our driver reports a supported 3.3, and the check is the safety net),
  `-liconv -licu*` (Boost locale/i18n off), the OCIO and audaspace hunks (both off;
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` covers CMake 4).
- Options beyond §4's list: `WITH_OPENMP=OFF` (TBB does the threading), `WITH_CYCLES_LOGGING=OFF` (as
  HaikuPorts), `WITH_LINKER_GOLD/LLD/MOLD=OFF`, `WITH_PUGIXML=ON`.
- **Cost (measured):** the whole Blender compile 13 min at `-j6` (03:41–03:54, incl. a 2006-step rebuild after
  the pugixml fix), all dependencies ~10 min. Peak RSS of the cross compilers together **5.8 GB**, one job
  1.24 GB (sampled every 2 s); under `heavy-build.sh --max 12`. Disk: blender tree 1.1 GB (src 286 MB), OIIO
  229 MB, Python 3.10 work 213 MB + host 141 MB, Boost 186 MB after deleting its 1.8 GB source trees,
  packages 41 MB.
- **M3 prepared, not run** (no Pi use in M2): `build-blender.sh stage` makes `artifacts/blender-tests/`
  (Blender/ = `blender` stripped + `3.6/{scripts,datafiles}`, 102 MB; packages/ = 17 runtime packages incl.
  python3.10, the libraries, libsdl2 -8, libffi). `tools/pi-tests/blender-m3.sh DIR LABEL` installs them,
  then `--version`, a bpy expression (Python 3.10.22 + `bpy.app.version_string`) and a Cycles CPU render of
  the default cube (960×540, 32 samples, PNG), graded by "BM3 … PASS" lines:
  ```
  scripts/pi-session.sh start --image artifacts/images/haiku-pi4-2026-11-19.img --minutes 60 --label bm3
  scripts/pi-ssh.sh put artifacts/blender-tests tools/pi-tests/blender-m3.sh /boot/home/
  scripts/pi-ssh.sh sh /boot/home/blender-m3.sh /boot/home/blender-tests bm3 > artifacts/blender-tests/bm3.txt
  scripts/pi-session.sh stop
  ```
  Likely first failures, in order: a package conflict or missing run-time library at `pkgman` time; Python
  not finding its standard library (no bundled `3.6/python`; it should take libpython's prefix
  `/boot/system`); TBB's thread start-up on Haiku; Cycles' NEON (sse2neon) kernels — then a slow render.
  Estimated remaining to M3 then: 0.5–1 agent-day; it took one hour (§7.4).
- A clean `BLENDER_CLEAN=1 scripts/build-blender.sh libdeflate stage` passes end to end: 16 min (05:49–06:05),
  the cross compilers' peak **5.8 GB** together, one process 1.26 GB (cc1plus; the `blender` link stayed below).
- The shared sysroot now also holds these unpublished libraries (non-packaged/ and boot/system/): another port
  whose configure auto-detects one of them would depend on a package that is not in the repository.

### 7.4 M3 result (2026-11-19 07:14–07:26, sessions bl3 and bl3e, release image-2026-11-19, network boot)

`tools/pi-tests/blender-m3.sh` on `artifacts/blender-tests` (the stage step's tree + 22 packages):
- `blender --version`: 3.6.23 (1 s). bpy: `Python 3.10.22`, `bpy.app.version_string` 3.6.23, 3 objects in the
  factory scene — Python finds its standard library from the python3.10 package (no bundled `3.6/python`).
- **Cycles CPU, 4 threads** (`-b --factory-startup -t 4 -E CYCLES -f 1`):
  - 960×540, 32 samples: **8.8 s**, 109–112 MB above idle;
  - the factory scene as it is (1920×1080, up to 4096 samples, adaptive 0.01): **1 min 36.7 s**, peak
    **251 MB** above an idle 304 MB (`sysinfo -mem` used, sampled every second; Blender's own counter: 191 MB).
  - PNGs in `artifacts/blender-tests/m3/` (cube_0001.png, factory_0001.png), checked by eye: the default cube,
    correct shading. "Filmic" falls back to "Standard" (no OpenColorIO: expected, M6).
- 0 PANIC (UART logs 20261119-071410/072217), 0 debug_server entries in syslog.
- What broke, in order:
  1. `pkgman install` of all staged packages failed the whole transaction ("Failed to change the package
     activation in packagefs: Name in use"): 11 of them were already on the image in the very same file
     version. The test installs only the packages the image does not have.
  2. The factory scene has render denoising on, and without OpenImageDenoise Blender quits ("Error: Build
     without OpenImageDenoiser"). The test turns `cycles.use_denoising` off; M6 adds OIDN or patches the
     default.
  3. OIIO printed `Assertion '0 && "Need to implement Sysutil::physical_memory on this platform"'` on every
     start (and reported 0 bytes): `openimageio2.4-2.4.15.0-physical-memory.patch` (get_system_info()
     max_pages), package revision 2, `-ffile-prefix-map` for its source paths.
- Speed: the Pi 400 report (§2.4) said about 2× a laptop; 1 min 37 s for the factory cube fits that.

Next, M4 (the UI): the same tree on the desktop of a session with HDMI capture — `blender` windowed through
GHOST_SDL with SDL2 -8 (per-thread contexts), expecting a 3.3 core context (patch 0001); then the Workbench
viewport, edit mode, save/load and an F12 render into the image editor. Known gaps before it: no OCIO (no
Filmic), no OIDN, ASCII-only text input (§3.1).

### 7.5 M4 result (2026-11-19 07:28–07:56, session bl4, release image-2026-11-19, HDMI capture)

`tools/pi-tests/blender-m4.sh` starts `blender` windowed (1600×900) with `blender-m4.py`, which drives the
scenario from inside Blender (operators on timers; no input device needed) and waits at each "BM4 SNAP" until
the host has taken an HDMI frame (`scripts/pi-snap-on.sh … /tmp/bm4-ack`, new, with `scripts/hdmi-snap.sh`).
Frames: `artifacts/blender-tests/m4/{1-start,2-viewport,3-edit,4-reloaded,4b-100k,5-preferences,6-render,7-key}.png`
(run bl4d; all viewed).
- **Context:** `3.3 (Core Profile) Mesa 26.2.7`, renderer V3D 4.2.14.0, GLSL 3.30 — patch 0001 works, no
  "Platform Unsupported".
- **Works:** the main window and all editors; Workbench solid shading (studio light) of cube and sphere; edit
  mode (header, tool shelf); save (906 968 bytes) and reload of a .blend; the Preferences window (a second SDL
  window, drawn correctly); **F12**: Cycles renders progressively into the "Blender Render" image-editor
  window (16 samples, 960×540: 9.8 s) — the render job's GL context on its own thread, i.e. M1 in real use.
- **Frame rate** (`wm.redraw_timer DRAW_WIN_SWAP`: the whole 1600×900 window, every region, drawn and swapped;
  a worst case — orbiting redraws only the viewport): default scene **5.1 fps**, edit mode **5.4 fps**, a
  ~102k-triangle scene (UV sphere 320×160 + cube) **6.5 fps**. Not yet measured: the viewport region alone (the
  region-only `DRAW` type does not redraw an untagged region) and fps while orbiting with a real mouse.
- **Fixed (Blender patches, artifacts rebuilt incrementally):**
  1. **Every object drew black.** `--debug-gpu` showed, for every region, `glFramebufferTexture(invalid color
     attachment GL_COLOR_ATTACHMENT4..7)` and `glDrawBuffers(n > maximum number of draw buffers)`:
     GLFrameBuffer always handles 8 color attachments, V3D 4.2 has 4 (§2.2, now found outside EEVEE too), so
     draw buffers were never set. `0005-gpu-gl-fewer-color-attachments.patch` uses
     min(GL_MAX_COLOR_ATTACHMENTS, GL_MAX_DRAW_BUFFERS, 8). After it: no GL errors, grey studio-lit objects.
  2. `0004-gpu-classify-v3d.patch`: an unknown vendor left the device at GPU_DEVICE_ANY, which every vendor
     check matches (Intel's viewport-clear workaround, NVIDIA's texture-gather off;
     `gpu.platform.device_type_get()` said "APPLE"). V3D is now UNKNOWN/open-source. No measurable fps change
     (5.3 → 5.1, noise).
- **Not a bug (test artefact):** the Preferences and render windows first opened at (-17482, 18044), off
  screen: they open at the mouse position of the invoking event, and an operator called from a timer before
  any mouse event has none. With `window.cursor_warp()` first they open at 470,190 and 305,150.
- **Open:**
  - Input: resolved in §7.6 (the window was never activated).
  - The splash screen stays open (closing it needs a click), so it covers the viewport in frames 2–3.
  - **Subdivision Surface is disabled** in this build ("Disabled, built without OpenSubdiv"): OpenSubdiv
    (CPU) should come early in M6, it is one of the most used modifiers.
  - GHOST_SDL's `getCursorPosition` returns `y = yi + x_win` (upstream typo; harmless while x_win = 0).
- 0 PANIC, 0 debug_server entries; "<!> event has no window" lines from GHOST_SDL are harmless.

### 7.6 M4 input (2026-11-19 07:58–08:06, session bl4i)

`tools/haiku-tests/uiinject.cpp` (new): activates a window through scripting (`set Active of Window N`, so
app_server sends the real B_WINDOW_ACTIVATED) and posts mouse moves, button presses, drags and named keys to
it, as app_server/input_server deliver them. `tools/pi-tests/blender-input.py` (new) prints every 0.5 s the
active object's mode, the window count, the 3D viewport's redraw count (a POST_PIXEL draw handler) and the
view rotation. Frames: `artifacts/blender-tests/m4/input/`.
- **Root cause of the earlier "no reaction":** SDL hands key events to its keyboard-focus window, which it
  learns only from WindowActivated(); a window started over ssh is never activated, so SDL sends the keys with
  window id 0 and GHOST_SDL drops them ("<!> event has no window" in every earlier log). Not an SDL bug: a
  user's click activates the window. After `activate`: 0 such lines.
- A second condition, Blender's own: keys go to the area under the mouse pointer, and Blender has no pointer
  position before the first mouse-move event — Tab did nothing until one `move` into the viewport.
- **Acts:** Esc (closes the splash), **Tab** (mode OBJECT → EDIT → OBJECT), **middle-button drag** (view
  rotation 0.716,0.439,… → 0.576,0.362,…), **numpad 6/6/8** (rotation changes again), **F12**.
- **Viewport while orbiting** (240 drag steps at 16 ms, 1322×762 viewport, default cube): 18 redraws in
  4.2 s = **4.3 fps**; the frame is GPU/driver bound at this size (to investigate in M5/M6: viewport AA,
  overlay passes, a smaller window).
- **F12 on the default scene crashes**: its render engine is EEVEE, whose opaque material shader does not link
  on 4 color targets (`invalid explicit location 4 specified for 'sssRadius'`, §2.2), and Blender then takes a
  segment violation (debug_server; the Release build has no symbols, the reported offset is not in .text:
  unresolved). F12 with Cycles works (§7.5). → M5; until then the user docs must say "switch the render engine
  to Cycles".

Next: M6 (packaging; OpenSubdiv, OCIO, denoising off without OIDN), then M5 (EEVEE on 4 targets — patch 0005
is the frame-buffer half of it — and the F12 crash).

### 7.7 M6 result (2026-11-19 08:08–09:25; session bl6 09:16–09:25, release image-2026-11-19)

- **New dependencies** (each `cross-port.sh` + `package-port.py --out artifacts/packages-test/blender`):
  yaml-cpp 0.8.0, pystring 1.1.4, minizip-ng 4.0.7 (zlib only), **OpenColorIO 2.3.2** (HaikuPorts patchset;
  expat given by path — the bootstrap expat's CMake config names /boot/system/include; Blender 3.6 already
  handles OCIO 2.3's API), **OpenSubdiv 3.5.0** (CPU + GL backend; no TBB evaluator: 3.5 needs
  `tbb/task_scheduler_init.h`, gone in oneTBB). All built in minutes; no new blocker. Options file: OCIO and
  OpenSubdiv on (the strict-options configure would stop if either went missing).
- **Denoising:** `patches/blender/0006` — a final render whose denoiser is not available (no OIDN port)
  runs without denoising instead of stopping with "Build without OpenImageDenoiser"; the Cycles add-on then
  registers no "Noisy Image" pass. (A first version changed only sync.cpp: the factory render then came out
  **black** — "Noisy Image" and "Combined" became the same noisy pass. Caught by viewing the PNG.)
- **Packages:** `blender-3.6.23-1-arm64.hpkg` (48 MB: `apps/Blender/Blender` + `3.6/`, Deskbar entry
  `data/deskbar/menu/Applications/Blender`; requires `libsdl2 >= 2.32.10-8`, `python3.10`, every library it
  links), python3.10 **revision 2** (now requires openssl, sqlite, bzip2, expat, libedit — before, its modules'
  libraries were only in the sysroot as extracted packages and became no requires), and the 15 library
  packages; 90 MB in `artifacts/packages-test/blender/`, not published.
- **On the Pi** (`BLENDER=/boot/system/apps/Blender/Blender blender-m3.sh`): `pkgman install` of the staged
  set resolves (17 packages), version/bpy PASS, **Subdivision Surface: 98 evaluated vertices** (OpenSubdiv),
  960×540 render 9.9 s, the **factory scene as it is** (denoising on in the file) **1 min 36.9 s**, Filmic
  view transform (no "Filmic not found"), PNGs `artifacts/blender-tests/m6/factory_0001.png` and
  `cube_0001.png` (viewed). Started with no arguments, as the Deskbar entry does, the UI comes up in a window
  of nearly the full screen (`m6/gui-package.png`); the splash closes with Esc. 0 PANIC, 0 debug_server.
- **To do before publishing:** a release decision (owner); the 4 colour-target EEVEE problem and the F12
  crash with EEVEE (M5); an app icon/resources (none yet); libsdl2 -8 published first (the package requires
  it); the sysroot holds all these unpublished libraries (risk for other ports' configures, noted 11-19).

### 7.9 M5 result (2026-11-19 09:27–09:40, session bl5, release image-2026-11-19)

- **Crash root cause** (from the source; the fix removed it, no symbolized stack was needed): every lit
  EEVEE material uses `eevee_legacy_material_surface_frag_opaque`, 6 outputs, which does not link on 4 color
  attachments — and so does EEVEE's pink *error* material, which uses the same shader. `EEVEE_material_get()`
  falls back to the error material and returns it although it failed too (only a release-disabled
  `BLI_assert` checks); the draw code then made a shading group from its NULL shader → segment violation
  (debug_server's one-frame trace pointed into .rela.dyn: a call through garbage).
- **Fix, `patches/blender/0007-eevee-four-color-attachments.patch`:** `GPU_max_color_attachments()`;
  `eevee_legacy_material_surface_frag_opaque_no_sss` (radiance + 2 SSR outputs; the subsurface light is
  added to the radiance) chosen below 6 attachments; `EFFECT_SSS` off there with a one-time message
  ("EEVEE: Subsurface Scattering is not available on this GPU (4 color attachments, 6 needed); subsurface
  materials render as diffuse"); and a safety net — when not even the error material compiles,
  `EEVEE_material_get()` returns NULL and the material is not drawn (depth/shadows only) instead of
  crashing. The safety net is not exercised on the Pi now (every material links); it is reviewed code.
- **On the Pi** (`tools/pi-tests/blender-m5.sh`, `blender-m5-scene.py`; package blender **-2**):
  factory scene with EEVEE **35 s** (1920×1080), a lit 5-material scene 960×540 EEVEE **57 s** (Cycles 32
  samples: 69 s), 0 shader errors, SSS message once, 0 debugger entries, 0 PANIC. GUI: **Material Preview**
  in the viewport and **F12 with EEVEE** (16.8 s into the Render window) — the path that crashed in §7.6.
  PNGs and frames in `artifacts/blender-tests/m5/` (factory_0001, scene_0001, cycles_0001,
  material-preview, f12-eevee; viewed): reflections (SSR), soft shadows and AO match the Cycles reference;
  the transmission monkey is dark in EEVEE as everywhere without screen-space refraction enabled on the material.
- No x86-64 reference render (not cheap here); Cycles of the same scene is the comparison.

### 7.10 Viewport speed (2026-11-19 11:48–12:10, sessions blperf and blperf2, image-2026-11-19b)

`tools/pi-tests/blender-perf.py` measures the solid viewport: "window" = every region drawn and swapped
(`redraw_timer DRAW_WIN_SWAP`), "orbit" = a 2° `view_orbit` + the viewport region drawn and swapped, per frame
(interactive navigation). Profiles: Haiku's `profile -k -f -S` with an unstripped `blender` and the unstripped
`libEGL_mesa` of the same Mesa build (loaded through `__EGL_VENDOR_LIBRARY_FILENAMES`); GPU time: the v3d
driver's `v3d_stats` (kernel setting, read at boot: `pi-session.sh --add`).

- **Before:** orbit 241 ms/frame (4.1 fps), window 192 ms (5.2 fps) at 1600×900 (viewport 1322×762); the cube
  and a ~102k-triangle scene the same — not geometry. **62% of all CPU samples** were in Workbench's
  anti-aliasing pass: `GLTexture::copy_to` → `glCopyImageSubData` → Mesa's `util_resource_copy_region`,
  which v3d does on the CPU (`v3d_resource_transfer_map`, `v3d_move_pixels_general_percpp`, memcpy; the
  kernel's page faults/zeroing/unmapping were its transfer buffers). The depth buffer is copied that way
  every frame.
- **`patches/blender/0008`:** `copy_image_support = false` on V3D, so `copy_to` uses its framebuffer-blit
  fallback (GPU). Orbit **198 ms (5.0 fps, +22%)**, window 155 ms (6.5 fps); CPU samples for the same 120
  frames 17089 → 6171. In blender **-4** (artifacts/packages-test/blender, with the -3 icon).
- **What is left is the GPU:** `v3d_stats` during orbiting: GPU busy **99%**, ~36 control-list (render) jobs per
  frame at ~5.4 ms each (bin ~0.19 ms). Each framebuffer switch is a full tile pass that loads and stores
  every attachment (RGBA16F + depth at 1322×762), so the frame costs passes × bandwidth: frame time scales
  with the pixel count (1024×600 window, 845×485 viewport: 81 ms, 12.3 fps). The present is cheap (one
  5.6 MB cache sync, ~0.65 ms, per frame); Python and the draw manager's CPU time are small once the copy is
  gone.
- **Settings** (orbit, 1322×762): Smooth Wires off (Preferences ▸ Viewport) 167 ms (6.0 fps); viewport AA
  off: −6 ms after 0008; overlays off: 147 ms (6.8 fps). Best cheap combination: a 1024×600 window with
  AA and Smooth Wires off, **68 ms (14.6 fps)**.
- **Next (not cheap):** fewer loads per pass — Mesa v3d skips a tile load when the buffer was cleared or
  invalidated, Blender never invalidates; or fewer passes (overlay sub-passes, region framebuffers). Both
  are real work in Mesa or the draw manager; the user doc gets the settings tip.

### 7.11 Framebuffer load/store actions on V3D: measured, not worth it (2026-11-19 12:45–12:52, session blfb)

Question: Blender 3.6's GL backend ignores the GPU module's load/store actions
(`GLFrameBuffer::attachment_set_loadstore_op` is empty; only Metal/Vulkan use them) and no draw-manager or
overlay framebuffer declares any, while v3d skips a tile load for cleared or invalidated buffers and a store for
invalidated ones (`v3d_invalidate_resource`, reached by `glInvalidateFramebuffer`). Would a
`patches/blender/0009` (invalidate on `LOADACTION_DONT_CARE` / `STOREACTION_DONT_CARE`) + declarations give
≥ 10%?
- **Trace of one orbit frame** (temporary diagnostic in gl_framebuffer.cc, removed): ~35 framebuffer binds —
  clears of `default`/`in_front`/`id_clear` (several run as clear-only jobs), Workbench `opaque_fb` (3 colors +
  depth), anti-aliasing/SMAA, then the overlay engine ping-ponging between its line and color framebuffers
  (`overlay_line`/`overlay_color` 3×, outlines, in-front), and the window composite (12 region blits into the
  back buffer). Most passes start with a clear already (no load).
- **Upper bounds** (diagnostic modes, images wrong on purpose; orbit at 1322×762, v3d_stats):
  - every attachment's color discarded on bind (no color loads): 203 ms (baseline 198) — nothing;
  - color + depth discarded on bind (no loads at all): **190 ms, −4%**;
  - everything discarded when leaving a framebuffer (no stores at all): **177 ms, −11%**, render 5.2 ms/job.
- A correct, conservative subset can only drop the loads and stores that are truly unused (clear-only jobs,
  depth after the overlays) — a fraction of those bounds, well under the 10% acceptance. Even with neither
  loads nor stores a pass costs ~5.2 ms: the cost is the tile processing per pass (RGBA16F at 1322×762, ~1000
  tiles), so the lever is **fewer passes** (the overlay engine's line/color ping-pong, separate clear-only
  jobs), i.e. draw-manager work, or a smaller viewport. **0009 not written** (dropped per the acceptance rule);
  blender -4 stays as it is.
- One debug_server entry in the session: the first trace build dereferenced the context before `init()`
  (diagnostic code only, fixed and removed).

### 7.12 blender -5: video, audio, Unicode text input (2026-11-19 12:53–13:09, session blav, image-2026-11-19b)

- **Video:** `WITH_CODEC_FFMPEG` against the ffmpeg6 6.1.6-5 package (Blender 3.6 pins FFmpeg 6.0; 6.1 builds
  and works). Our FFmpeg has no software H.264 encoder (only `h264_mmal`), so the test writes **MPEG-4 Part 2
  in MP4** (libavcodec `mpeg4`): `tools/pi-tests/blender-av.py -- render` — a turning cube, 24 frames at
  640×360, Workbench, **7.5 s**; on the host ffprobe: `mpeg4 640x360 24/1 nb_frames=24`. The **Video Sequencer**
  loads the MP4 (24 frames, 640×360) and a WAV (48 kHz), and renders its frame 12 from the decoded movie
  (`artifacts/blender-tests/av/vse_0012.png`: the cube at 45°). Playback in the GUI: frame advancing,
  fps 6.2 (`av/vse-play.png`). Also usable: MJPEG, FFV1, FLAC/PCM/Vorbis audio. (H.264/AAC: wrongly
  reported missing here — see §7.13.)
- **Audio:** `WITH_AUDASPACE` on SDL2 (OpenAL/JACK/PulseAudio off; audaspace reads audio through FFmpeg).
  Preferences ▸ System ▸ Sound device: **SDL**; the team gets SDL's BSoundPlayer thread ("SDL Audio control",
  media priority 110, running); playback synced to the audio clock (`AUDIO_SYNC`) advances (frame 1 → 13–16 in
  1.6 s). Not heard (no listener at the bench). The `aud` Python module is not there: Blender builds it only
  with NumPy (WITH_PYTHON_NUMPY, a NumPy port for 3.10 — a big new dependency, left out).
- **Unicode text input:** `patches/blender/0009-ghost-sdl-unicode-text-input.patch` — GHOST_SDL starts SDL
  text input and takes a key's text from the SDL_TEXTINPUT event that follows its SDL_KEYDOWN (UTF-8 from the
  keymap), with the old ASCII conversion as the fallback; text without a key event of its own becomes one key
  press per character. Test: `uiinject … key f2 … text "zażółć" key return` (new `text` command: one key
  event per UTF-8 character) → the observer prints **`name=zażółć`**; the outliner, header and properties
  show it (`av/unicode-name.png`).
- **App flags fixed:** HaikuPorts' rdef had `B_SINGLE_LAUNCH`, so with -4 a second Blender window (or a GUI
  instance next to a running one) exited at once; now `B_MULTIPLE_LAUNCH | B_ARGV_ONLY` (ARGV_ONLY kept:
  Tracker passes a .blend as an argument; it also hides the app from scripting, so input tests use the same
  build without resources). Two instances checked (`av/two-instances.png`; Deskbar shows the icon).
- **Package:** blender **-5** (49 MB) in artifacts/packages-test/blender, unpublished. Requires vs -4: + the seven
  FFmpeg libraries (libavcodec/-device/-filter/-format/-util, libswresample, libswscale; the published ffmpeg6
  package, which images already carry) — nothing else. 0 PANIC, 0 debugger entries.

### 7.13 blender -6: H.264 + AAC output (2026-11-19 14:15–14:36, sessions blh264 and blmp, image-2026-11-19b)

- **§7.12 was wrong about H.264/AAC:** -5 already wrote both. Blender's writer looks encoders up by id
  (`avcodec_find_encoder(AV_CODEC_ID_H264 / AV_CODEC_ID_AAC)`); without libx264 that returns our VideoCore
  encoder `h264_mmal`, and AAC gets FFmpeg's native `aac`. No fallback was needed.
- **What did not work: the quality setting.** Blender's Output Quality presets are CRF values: it sets
  `bit_rate = 0` and passes the option `crf`, which `h264_mmal` does not have — so every preset gave the
  encoder's 4 Mbit/s default. `patches/blender/0010-ffmpeg-bitrate-from-crf-for-encoders-without-crf.patch`:
  when the encoder has no `crf` option, a bit rate from CRF, frame size and fps
  (0.1 bit/pixel at CRF 23, doubling every 6 steps down, clamped to 0.25–50 Mbit/s; Medium at 720p24 →
  2.2 Mbit/s, the encoder logs "1280x720 at 24/1 fps, 2211840 bit/s"). Constant Bitrate mode is unchanged.
  The VideoCore honours the rate on detailed content (testsrc2 720p: 1 Mbit/s → 252 kB, 8 Mbit/s → 1.26 MB
  per 10 s); flat content is quality-capped, so Medium and Low give the same small file.
- **ffmpeg6 -6** (`patches/ffmpeg6/files/libavcodec/mmalenc.c`): the VideoCore's own first quantiser made a
  flat 720p key frame of 981 bytes, visibly banded, with many frames to recover; new option `initial_qp`
  (default 25, `MMAL_PARAMETER_VIDEO_ENCODE_INITIAL_QUANT`) → 1921 bytes, clean (`h264/frames-qp.png`
  vs `h264/frames.png`). Also pts in microseconds as MMAL defines them (API correctness; no measured effect —
  an earlier "3.1 MB vs 59 kB" comparison was the ffmpeg CLI duplicating frames, not this). Provides/requires
  identical to -5.
- **Test:** `tools/pi-tests/blender-av.py -- h264 OUTDIR` — a cube turning 0→120°, 48 frames, 1280×720,
  24 fps, Workbench, a 2 s 440 Hz stereo WAV as a sequencer strip; MPEG-4 container, H.264 Medium, AAC 192k.
  **32.7 s** for 48 frames (0.64 s per frame, 0.19 s of it saving). Host ffprobe: `h264 High 1280x720
  nb_frames=48 duration=2.000000`, `aac LC 48000 Hz stereo duration=2.005`, file 117 kB
  (`artifacts/blender-tests/h264/h264_0001-0048.mp4`).
- **MediaPlayer** plays it with ffmpeg6 -6 (`h264/mediaplayer.png`; its log: h264_mmal decode to the end of
  the stream); with -5 as on the image its log shows the same (no screenshot). A "General system error" seen
  first, after uninstalling and reinstalling ffmpeg6 inside the running session, was not reproduced in a
  fresh session (cause not established). `pkgman uninstall ffmpeg6` also removes blender. The audio track
  carries the WAV (volumedetect: mean −11.8 dB). The testsrc2 bit-rate runs above predate `initial_qp`.
- **Packages** (unpublished, artifacts/packages-test): blender **-6** (49 MB; requires identical to -5) and
  ffmpeg6 **-6** (`scripts/build-ffmpeg.sh --out DIR`). 0 PANIC, 0 debugger entries.

### 7.14 blender -7: denoising, `aud`, Alembic, Ocean, fluids, and the Rendered viewport (2026-11-20 06:58–08:55; session bb7 07:44–08:51, image-2026-11-19b)

Task B7: close the biggest F12 limits. Everything below is in `scripts/build-blender.sh` (steps `oidn numpy alembic
fftw`, then the Blender steps) and `artifacts/packages-test/blender-7/` (not published).

**OpenImageDenoise 2.5.1 for Haiku arm64** (`tools/recipes/media-libs/oidn/`, step `oidn`):
- Version: Blender 3.6 pins OIDN 1.4, which is x86-only (oneDNN). OIDN 2.x has a CPU device on ARM64 whose kernels
  are ISPC programs (`neon-i32x8`; BNNS is used only on macOS), so 2.5.1, the newest release, was taken.
- **ISPC on the host:** the official ISPC 1.32.0 Linux x86-64 build (pinned download, sha256 checked) compiles them
  with `--arch=aarch64`. Its default target-os is linux, which gives plain ELF64 AArch64 relocatable objects; those
  link into Haiku libraries unchanged. Checks in the step (they fail the build):
  - ≥ 13 ISPC objects;
  - every object AArch64;
  - **no FP16 arithmetic**: the Cortex-A72 is Armv8.0, and the ARM64 `*_f16` kernels use only the base
    `fcvtl`/`fcvtn` conversions (objdump);
  - the CPU device links TBB;
  - no run path.

  The only atomics are libgcc's outline ones (LSE behind a runtime check). Every undefined symbol is in
  libroot/libstdc++/libgcc_s/TBB.
- **One Haiku patch** (`oidn-2.5.1.patchset`): `ThreadAffinity` exists only for Windows, Linux and macOS; a no-op
  fallback makes the engine run unpinned, as when detection fails on Linux. The device module is found from
  `dladdr()`'s absolute path ("Loaded module: 'libOpenImageDenoise_device_cpu.so.2.5.1'").
- Build: about 1 min, 0 warnings. Only the RT filter's weights are included (no RTLightmap). The package ships
  `oidnDenoise` and `oidnBenchmark` (not `oidnTest`).
- **Blender:** its use of the API (newDevice, setImage with strides, `hdr`/`srgb`/`cleanAux`, the progress monitor)
  compiles against 2.x unchanged.
  - `patches/blender/0011-oidn-on-arm64.patch` (**replaces 0006**): Cycles' `openimagedenoise_supported()` and
    both compositor Denoise checks treat ARM64 like macOS. Before, they required SSE4.1.
  - `0012-oidn-balanced-quality.patch`: see the timings below.
- **Timings on the Pi** (4 threads; `tools/pi-tests/blender-b7.sh`, `artifacts/blender-tests/b7/`):
  - `oidnBenchmark` RT hdr+alb+nrm at 1920×1080: **17.0 s per frame**, 1.33 GB peak.
  - OIDN 2's default quality, *High*, uses its **large** networks for clean auxiliary passes and for the albedo and
    normal prefilters. Clean albedo + normal at 1080p: High 43.3 s, Balanced 18.7 s.
  - Blender's default prefilter, *Accurate*, runs three such filters. The factory cube at 1080p, 8 samples:
    no denoising 10.4 s, Accurate at High **2 min 19 s** (1.75 GB peak).
  - Blender 3.6 has no quality setting, so **0012 sets Balanced** (the base networks) in Cycles and in the
    compositor. Accurate then takes **1 min 4 s** (1.45 GB). Fast prefilter: 31 s.
- **Results with -7** (run `final`):

  | Render | -6 (no denoising) | -7 (denoised) | Peak memory |
  |---|---|---|---|
  | Factory scene as it is (1920×1080, adaptive) | 1 min 37 s | **3 min 30 s** (6 min 5 s before 0012) | 1.5 GB (1.8 GB before 0012) |
  | `blender-m5-scene.py`, 960×540, 16 samples | 35.0 s noisy | 48.7 s | 467 MB |

  The compositor's Denoise node renders. PNGs are in `b7/renders/`, checked by eye: glass, metal and the shadows
  are clean where the 16-sample render is grainy.
- **Viewport:** the Rendered (Cycles) viewport drew **Blender's icon sheet** instead of the render (frame
  `b7/view/view-denoised.png`). This is not a denoiser problem:
  - **Measured with the published -6 as well** (session bb7c, `b7/view-6/view-noisy.png`: the icon sheet).
  - **Cause:** GHOST_SDL creates contexts with `SDL_GL_SHARE_WITH_CURRENT_CONTEXT`, and SDL 2 shares only with the
    context *current* on the calling thread. Cycles' display context is created right after the draw manager
    releases its own, with nothing current (a diagnostic print confirmed it). So the new context had its own object
    namespace, and its texture name meant the icon atlas in the window's context.
  - **Fix:** `0013-ghost-sdl-share-with-first-context.patch` makes the first context current for the creation when
    none is. GHOST's other backends name it explicitly.
  - **After the fix:** the viewport shows the render (`b7/view2`), and with viewport denoising on, a clean image
    (`b7/view5/view-denoised.png`; OIDN verbose: "Quality: balanced", 140×80 first, then the full size).
  - **Open:** switching viewport denoising on *from a script* in a viewport that is already rendering did not
    restart the render with it. Started with it on, it works. The UI checkbox was not tested: the packaged app
    has B_ARGV_ONLY, so uiinject cannot drive it.

**`aud` (step `numpy`):** Blender builds audaspace's Python module only with NumPy, and `PyInit_aud` imports NumPy
at run time (`import_array`), so this needs a NumPy package for Python 3.10, not only headers.
- **NumPy 1.26.4**, not 2.x:
  - Blender 3.6 pins 1.23.5;
  - it finds the C headers in `numpy/core/include`, which 2.x moved;
  - its add-ons were written against 1.x.
- **`scripts/build-numpy.sh --python 3.10 --out DIR`** (new options) builds it with a separate venv
  (`meson-python < 0.16`, `Cython < 3.1`, the sdist's pins). Two fixes were needed:
  - its vendored meson 1.2.99 predates `@DIRNAME@`, so the script resolves our cross file;
  - Cython 3.0 writes the absolute `.pyx` path into `numpy/random/bit_generator`, which the packager's host-path
    check refused. `package-python-wheel.py --replace-dir` (new) pads `/boot/system/lib/python3.10/vendor-packages`
    with slashes to the same length.
- `package-python-wheel.py` now takes the target version from the Python running it and has `--out`.
  A non-default version gets no unsuffixed `f2py`.
- **numpy_python3.10** 1.26.4-1, 9.1 MB:
  - 19 extension modules, every undefined symbol resolved;
  - baseline NEON/ASIMD;
  - 487 warning lines, NumPy's own (as in the native 2.5.4 build).
- On the Pi:
  - `aud.Sound.sine(440).limit(0, 1).data()` returns `ndarray (48000, 1) float32`;
  - `aud.Sound.buffer()` takes the array;
  - in a GUI Blender, `aud.Device()` plays it, and `handle.position` is **0.6 after 0.6 s**.
- `aud.Device('SDL')` fails ("The audio device couldn't be opened with SDL"); `aud.Device()` works, headless too.
  A 2×2 on a fresh boot (session bb7c, before any other sound) settled it: `-b` + `Device()` played, `-b` +
  `Device('SDL')` failed twice, GUI + `Device('SDL')` failed, GUI + `Device()` played. Blender has already opened
  its SDL sound device (also with `-b`), and `Device()` returns that one. Opening a second SDL device in the
  same team fails: a limit of SDL's Haiku audio backend, not of the port. (A first reading of session bb7 had
  blamed `-b`; the two failing runs there used `'SDL'`.)
- blender -7 **requires numpy_python3.10**, because no NEEDED entry shows that requirement.

**Cheap F12 items done:**
- **Alembic 1.8.3** (Blender's pin; HaikuPorts recipe + patchset; Ogawa only, the library only; 33 s): export and
  re-import of the factory scene PASS.
- **FFTW 3.3.10**: the double-precision library + its threads library, autotools, 1 min. The recipe also builds
  float/long/quad; this package is named `fftw` but has only `libfftw3`/`libfftw3_threads`. It enables the
  **Ocean modifier**: 2500 vertices, displaced.
- **Fluid simulation** (Mantaflow, bundled in Blender): a smoke domain baked for 6 frames, 36 cache files (UNI
  format; OpenVDB is off).
  - The check first failed **4 of 14 runs** (`'NoneType' object has no attribute 'getDataPointer'`), and **10 of
    10 with `-t 1`**.
  - The official x86-64 Blender 3.6.23 failed the same script the same way, so it is the test, not the port: the
    domain was made before its flow object.
  - With the flow made first: 10/10 on the Pi (`-t 1` and `-t 4`) and 6/6 on x86-64.
- **M3/M5 probes, -7 installed** (`b7/m3-m5.txt`): every check PASSes.
  - M3: version, bpy (Python 3.10.22), subsurf (98 vertices), 960×540 cube 9.7 s, factory 3 min 30 s (1.5 GB),
    Filmic.
  - M5: EEVEE factory 34.9 s and scene 56.4 s (-2: 35 s and 57 s), the SSS message once; Cycles scene 82.7 s
    (-2: 69 s; its factory settings denoise now).
  - Session: 0 debugger entries, 0 PANIC (UART `20261120-074416-session-bb7.log`).
- **GUI coverage of the final package** (session bb7c 09:27–09:49, `b7/session2.txt`, 0 debugger entries, 0 PANIC):
  - M4 on the staged tree (the same binary): 3.3 core context; fps default 6.4, edit mode 6.8, 100k triangles
    6.4 (as -4); edit mode; save and reload; Preferences window; F12 Cycles render 9.9 s; keyinject. Frames
    match the earlier M4 run. **0 "wrong thread" lines.**
  - `blender-b7-view.sh` on the package: Cycles Rendered noisy and denoised, Material Preview (EEVEE) and an EEVEE
    F12 into the render window, all drawn correctly (`b7/view-final/`), 0 "wrong thread" lines.
  - Started with no arguments, as the Deskbar entry does: the UI, nearly full screen (`b7/noargs.png`).
  - `blender-probe.sh`: `sdlthread: PASS`, every program status 0.
  - Extras ×3: Alembic, Ocean, smoke and **liquid** bakes all PASS (liquid: 24 cache files).

**Packages** (`artifacts/packages-test/blender-7/`):

| Package | Size |
|---|---|
| blender-3.6.23-7 | 51.0 MB (-6: 49.1) |
| oidn-2.5.1-1 | 43.8 MB |
| oidn_devel | 10 kB |
| numpy_python3.10-1.26.4-1 | 9.1 MB |
| alembic-1.8.3-1 | 770 kB |
| alembic_devel | 129 kB |
| fftw-3.3.10-1 | 381 kB |
| fftw_devel | 12 kB |

**blender -7 against -6** (`scripts/package-diff.sh`, new):
- requires gains `lib:libalembic`, `lib:libfftw3`, `lib:libopenimagedenoise` and `numpy_python3.10`;
- the 2333 file paths are identical;
- the rest is in the binary.

Clean Blender build: 15 min (07:19–07:34, `-j6`), 826 warning lines. The pre-existing pipefail trap in the script's
`readelf | grep -q` checks (grep exits at the first match, the writer gets SIGPIPE, the check fails or, negated,
passes) was fixed: the checks read all input now. The patched tree was checked equal to a fresh 3.6.23 tree plus
`patches/blender/*.patch`.

**Sysroot:** it now also holds oidn, alembic and fftw (`non-packaged/`) and numpy_python3.10. The packager now
removes the `.PackageInfo` that extraction left in `boot/system/`.

**Misses and gaps:** QuadriFlow's result differs slightly from x86-64 (cause not investigated); the Boolean
difference case does not separate Exact from Fast (the coplanar union does); only German of the 38 languages was
looked at; Mesh to Volume and the geometry-nodes volume nodes were not probed; the update path from an installed
-7 is untested; M4's frames 6-render and 7-key were not taken (as in -7's run).

**Not done, with effort** (*estimated*):
- **OpenVDB 10.0** (Blender's pin), 0.5–1 day. It needs c-blosc 1.21 (HaikuPorts has 1.18), Boost iostreams in
  the boost step, and oneTBB (10.0 supports it). Its compile jobs are 2–3 GB each. It would bring voxel remesh,
  `.vdb` import, Volume/Mesh conversion nodes, NanoVDB volumes in Cycles and the OpenVDB fluid cache. It is the
  next one worth doing.
- **USD**, 2–4 days, high risk. Blender 3.6 pins USD 23.05, which uses the TBB 2020 API (*recalled*: oneTBB
  support came with USD 24.x), so it needs either an old TBB beside ours or a newer USD against Blender 3.6's
  io/usd code. Boost too, and a build of an hour or more.
- **Not a dependency question:**
  - GPU subdivision: V3D's desktop GL has no compute shaders.
  - EEVEE SSS: 4 colour attachments.
  - Tablet pressure: needs a native GHOST, M7.
- **Cheap, outside F12:**
  - GMP: without it the Boolean modifier's Exact solver silently falls back to Fast.
  - Quadriflow and Draco: bundled, only options.
  - potrace and libharu.
  - i18n: Boost locale + host msgfmt.

**Proposed KNOWN-ISSUES F12 text for the publish:**
- **Gone:** "No denoiser", "Built without Alembic", "fluid simulation" and "`aud` module is missing".
- **Stays:** EEVEE SSS, GPU subdivision, tablet pressure and the slow viewport.
- **New:**
  - "Denoising (OpenImageDenoise) runs on the CPU: about 20 s per denoised 1920×1080 frame with the default
    prefilter's three passes taking ~1 min, and ~1.5 GB of memory; set Prefilter to Fast for a third of that."
  - "No OpenVDB/USD import (volumes, voxel remesh)."
  - (`aud`: none needed; use `aud.Device()`, Blender's own device.)

### 7.15 blender -8: OpenVDB, GMP, Quadriflow, Draco, translations, potrace, libharu (2026-11-20 09:56–11:25; sessions b8 10:44–10:57 and 11:21–11:25, image-2026-11-19b)

Task B8: the next features after -7. Everything is in `scripts/build-blender.sh` and
`artifacts/packages-test/blender-8/` (not published). Every Pi number is checked against the **official x86-64
Blender 3.6.23** running the same script (`tools/pi-tests/blender-b8.py`) on the host; its results are in
`artifacts/blender-tests/ref/b8ref.txt`.

**Results on the Pi** (`tools/pi-tests/blender-b8.sh`, `artifacts/blender-tests/b8/b8.txt`):

| Check | Pi, blender -8 | x86-64 official 3.6.23 |
|---|---|---|
| Build options | openvdb, potrace, haru, international all 1 | the same |
| Voxel remesh, Remesh modifier (Suzanne, voxel 0.05) | 507/500 → **6710/6708** vertices/faces, 0.9 s | 6710/6708 |
| Voxel Remesh operator (UV sphere, 0.1) | 482/512 → **2000/1998** | 2000/1998 |
| QuadriFlow Remesh (Suzanne, 1000 faces) | 924 vertices, **918 quads**, 3.1 s | 929/922 |
| Boolean union of two boxes with coplanar faces: **Exact** | **16/14** | 16/14 |
| … the same with Fast | 32/11 | 26/6 |
| Boolean difference, cube − sphere, Exact with self-intersection | 197/184 (Fast: the same) | 197/184 |
| Smoke bake, OpenVDB cache, Blosc | 12 `.vdb` files, **794 750 bytes** | 12, 794 750 bytes |
| x86-64's `.vdb` (Blosc) imported, Cycles 320×240, 32 samples | 5 grids; render 2.4 s, peak 176 MB; **max pixel difference 1/255** to x86-64's render | — |
| The Pi's own `.vdb`, rendered the same way | max pixel difference 1/255 to x86-64's | — |
| Volume to Mesh (density, threshold 0.1) | **548/544** | 548/544 |
| glTF export, Suzanne subdivided twice | 69 684 bytes plain, **14 232 bytes with Draco** (`KHR_draco_mesh_compression`), re-import 1966 vertices | the same bytes |
| Translations | `de_DE`: Delete → "Löschen", Add → "Hinzufügen"; 38 languages | the same |
| Trace Image (potrace), a 128×128 disc | 1 Grease Pencil object, **45 points** | 45 |
| Grease Pencil PDF export (libharu), Stroke monkey | **72 593-byte PDF 1.4**, 1 page; the monkey drawn (viewed on the host, `b8/monkey.pdf`) | (needs a window; not run on the host) |

- The **Exact solver runs**: without GMP Blender falls back to the Fast (BMesh) solver silently, and the union
  test separates the two (Exact 16/14 on both machines; Fast 32/11 on the Pi, 26/6 on x86-64 — the float BMesh
  solver is not even stable across machines on coplanar faces). The difference test does not separate them.
- **QuadriFlow differs slightly** from x86-64 (924/918 against 929/922, all quads on both): its solver is
  floating-point and seeded the same, so the likely cause is arm64's arithmetic (e.g. FMA contraction; not
  investigated).
- **Volumes:** the import reads Blender's own Blosc-compressed caches from x86-64 and the Pi; Cycles renders them
  through NanoVDB (`WITH_NANOVDB`). The cache's default format is now OpenVDB: -7's fluid checks write `.vdb`
  data files (smoke and liquid PASS, format OPENVDB, 6 `.vdb` each; the `.uni` files beside them are the caches'
  config files).
- **Draco:** "Draco mesh compression is available, use library at
  /boot/system/apps/Blender/3.6/lib/libextern_draco.so"; the compressed file has the same size as x86-64's.
- The PDF test of the first session was wrong (a window run's script has no `active_object` in its context); the
  fixed test passed in a second session (11:21–11:25), which also showed the **German interface** on screen
  (`b8/german-ui.png`: menus, splash, properties translated, umlauts drawn) and a **no-argument start** as from
  Deskbar (`b8/noargs.png`: the UI with the new Language row; 0 "wrong thread" lines).
- Sessions: 0 debugger entries, 0 PANIC (UART `20261120-104401-session-b8.log`, `20261120-112151-session-b8.log`).

**Regression probes with -8 installed** (same session):
- M3 (`b8/m3.txt`): version, bpy (Python 3.10.22), subsurf 98 vertices, 960×540 cube **9.8 s**, factory 1080p
  **3 min 31 s**, 1.55 GB peak, Filmic — as -7 (9.7 s, 3 min 30 s, 1.5 GB).
- M5 (`b8/m5.txt`): EEVEE factory **35.4 s**, scene 57.2 s, Cycles scene 82.0 s, the SSS message once (-7: 34.9,
  56.4, 82.7 s).
- M4 on the staged tree (`b8/m4.txt`, frames `b8/m4/`): 3.3 core context; fps default 6.4, edit mode 6.8, 100k
  triangles 6.3 (-7: 6.4/6.8/6.4); save and reload; Preferences; F12 Cycles 10.1 s; keyinject; **0 "wrong
  thread" lines**. The splash's Quick Setup now has a Language row (translations). Frames 6-render and 7-key are
  not taken, as in -7's run (pi-snap-on stops after 5-preferences).
- `blender-probe.sh`: `sdlthread: PASS`, every program status 0.

**Libraries** (`scripts/build-blender.sh` steps `boost blosc openvdb gmp potrace libharu`; packages in
`artifacts/packages-test/blender-8/`, not published):
- **Boost 1.83 revision 2:** once `WITH_BOOST` is on, Blender's `find_package(Boost)` asks for `filesystem regex
  thread date_time iostreams system` (+ `locale` with i18n); the published -1 has only what OIIO links. -2 adds
  regex, iostreams (OpenVDB's delayed loading uses only `mapped_file`, so no compression filters: zlib, bzip2,
  lzma and zstd are switched off explicitly) and locale (iconv backend from libiconv, no ICU, no POSIX backend).
  The step fails if a library is missing, if iostreams links a compressor or if locale does not link libiconv;
  the package names `lib:libiconv` (package-port.py only derives requires from `non-packaged/`).
- **c-blosc 1.21.6** (ours, `tools/recipes/dev-libs/c_blosc`; Blender pins 1.21.1, HaikuPorts has 1.18.1): the
  system's LZ4, Zstd and zlib, no Snappy. OpenVDB writes LZ4 blocks, so the step fails unless `libblosc` links
  `liblz4` (a Blosc without it builds and links, then fails on real files); `lz4`/`lz4_devel` (published) are now
  extracted into the sysroot. GCC 16 defaults to C23, where `shuffle.c`'s `typedef _Bool bool` is an error: C11.
  Generic shuffle only (its CMake does not recognise `aarch64` for the NEON variant).
- **OpenVDB 10.1.0** (ours, `tools/recipes/media-gfx/openvdb`; Blender 3.6 pins 10.0.0, 10.1 is the newest release
  of the same ABI 10; HaikuPorts has 7.1 and 13.0): shared core with Blosc, zlib, delayed loading, oneTBB 2022
  (supported since 9.x), OpenVDB's own half type; NanoVDB's headers; `vdb_print`. The step fails unless
  `libopenvdb` links blosc, zlib, TBB and Boost iostreams and `version.h` has `OPENVDB_USE_BLOSC`,
  `OPENVDB_USE_ZLIB` and `OPENVDB_USE_DELAYED_LOADING`. Explicit instantiation makes big compile jobs: 8 jobs were
  OOM-killed at 14 GB, 5 jobs (16 GB cap) built it in 11 min; 0 warnings. `libopenvdb.so.10.1` is 56 MB (package
  10 MB).
- **GMP 6.3.0** (HaikuPorts recipe; no gmp package existed in our repository or the bootstrap set): gmplib.org
  refused connections, the GNU mirror has the same file (the recipe's sha256 checks it). Two traps: GCC 16's C23
  rejects the K&R tests of GMP's configure ("could not find a working compiler": `-std=gnu17`), and libtool links
  the C++ `libgmpxx` with `-lstdc++` resolved through the cross tools' `libstdc++.la`, whose `libstdc++.a` does not
  exist (the libtiffxx trap of §7.3) — the generated libtool gets `-l:libstdc++.so` instead. ARM64 assembly
  (`mpn/arm64`).
- **potrace 1.16** and **libharu 2.4.3** (HaikuPorts recipes; Blender 3.6 pins libharu 2.3.0, its calls compile
  against 2.4 unchanged).

**Blender** (`tools/cmake/blender-minimal.cmake`): `WITH_BOOST WITH_OPENVDB WITH_OPENVDB_BLOSC WITH_NANOVDB WITH_GMP
WITH_POTRACE WITH_HARU WITH_INTERNATIONAL WITH_QUADRIFLOW WITH_DRACO` on. Guards added: each must be ON in the cache
*and* appear as `-DWITH_…` in `build.ninja` (a find module or `set_and_warn_dependency` can turn one off with a normal
variable the cache compare cannot see), the `extern_draco` target must exist, `blender` must link libopenvdb,
libgmp, libgmpxx, libpotrace, libhpdf and libboost_locale, and the package must have `3.6/lib/libextern_draco.so`,
German `.mo` files and **no `3.6/python`**.
- **Translations** need the generator `msgfmt` on the host. It links `bf_blenlib`, whose link line names the
  target's TBB and GMP that the host configure found in the sysroot ("file in wrong format"); the objects it uses
  need neither, so `hosttools` links it with that line minus the sysroot's libraries. Its German `.mo` is
  **byte-identical** to the official x86-64 3.6.23 release's (CPython 3.10's `msgfmt.py` was tried first: its
  catalogue keys differ, 11 371 of its 15 462 entries under another message context). 38 languages, 39 MB.
- **Draco** (`patches/blender/0014-draco-on-haiku.patch`): Blender turns `WITH_DRACO` off without a bundled Python
  and installs `libextern_draco.so` into the bundled Python's `site-packages`. A `3.6/python` directory must not
  exist here — Blender takes it as its bundled Python's home (`bpy_interface.c`) and the system Python's standard
  library would not be found. On Haiku the library goes to `3.6/lib/`, and the glTF add-on (which knows only
  win32/linux/darwin; Haiku's `sys.platform` is `haiku1`) looks there.
- Quadriflow is bundled (Boost.Graph headers).
- Build: 10 min (10:28–10:38, `-j5`, 2991 steps after the reconfigure of -7's tree), 580 warning lines; `blender`
  98 MB unstripped. Then a **clean** `BLENDER_CLEAN=1 build-blender.sh configure blender_package` (after a run of the
  `sysroot` step with its new lz4 lines): 16 min (11:03–11:19, 4960 steps), 867 warning lines, the same binary size;
  its package has the same provides, requires and 2457 paths as the tested one (which was put back). The patched
  tree equals a fresh 3.6.23 + `patches/blender/*.patch` (0001–0014).

**Packages** (`artifacts/packages-test/blender-8/`):

| Package | Size | Note |
|---|---|---|
| blender-3.6.23-8 | 64.8 MB (-7: 51.0) | +39 MB translations (unpacked) |
| boost1.83-1.83.0-2 (+ _devel) | 423 kB | replaces the published -1: + regex, iostreams, locale |
| openvdb-10.1.0-1 (+ _devel) | 10.1 MB | libopenvdb 56 MB unpacked, `vdb_print` |
| c_blosc-1.21.6-1 (+ _devel) | 20 kB | requires lz4, zstd (published) |
| gmp-6.3.0-1 (+ _devel) | 223 kB | libgmp + libgmpxx |
| potrace-1.16-1 (+ _devel) | 78 kB | libpotrace, `potrace`, `mkbitmap` |
| libharu-2.4.3-1 (+ _devel) | 501 kB | libhpdf |

**blender -8 against -7** (`scripts/package-diff.sh`):
- requires gain `boost1.83 >= 1.83.0-2`, `lib:libboost_{date_time,filesystem,iostreams,locale,regex,system,thread}`,
  `lib:libgmp`, `lib:libgmpxx`, `lib:libhpdf`, `lib:libopenvdb`, `lib:libpotrace` and `lib:libtiff` (tiff
  4.7.0-1 is published; `source/blender/io/gpencil/CMakeLists.txt` links TIFF next to libharu, which a static
  libharu needs for two fax tables; harmless with ours); none dropped;
- files 2333 → **2457**, none removed: + `3.6/datafiles/locale/` (38 languages + `languages`, 116 paths),
  `3.6/lib/libextern_draco.so`, Cycles' `source/nanovdb/` headers (6 paths). No `3.6/python`.

**boost1.83 -2 against the published -1:** provides gain `lib:libboost_{iostreams,locale,regex}`, requires gain
`lib:libiconv` (published); files 11 → 14 (the three libraries), nothing removed; `_devel` gains the three
`devel:` provides and their `develop/lib` links.

**Sysroot:** the shared `artifacts/sysroot-arm64` now also holds (in `non-packaged/`) OpenVDB, NanoVDB's headers,
c-blosc, GMP, potrace, libharu and Boost's regex/iostreams/locale, none of them published; and (in `lib/`) lz4 from
its published package. Another port whose configure auto-detects one of them (GMP especially: GCC-style and
crypto ports look for it) would depend on a package that is not in the repository until these are published.

Clean intermediates: the library work trees were deleted after packaging (sources and build directories); the
official x86-64 Blender used as reference (in the agent's temp directory) is deleted at the end.

**Misses and gaps:** QuadriFlow's result differs slightly from x86-64 (cause not investigated); the Boolean
difference case does not separate Exact from Fast (the coplanar union does); only German of the 38 languages was
looked at; Mesh to Volume and the geometry-nodes volume nodes were not probed; the update path from an installed
-7 is untested; M4's frames 6-render and 7-key were not taken (as in -7's run).

**Not done, with effort** (*estimated*):
- **USD**, 2–4 days, high risk (as §7.14: USD 23.05 uses the TBB 2020 API).
- Blosc's NEON shuffle (its CMake does not recognise `aarch64`; generic shuffle is used): small, no measured need.
- Not dependency questions (unchanged): GPU subdivision (no compute shaders), EEVEE SSS (4 colour attachments),
  tablet pressure (native GHOST, M7).
- Still off and not attempted: Cycles OSL and Embree, OpenXR, JACK/PulseAudio, OpenImageIO's own OpenVDB and
  FFmpeg readers (Blender reads `.vdb` and video through its own code).

**Proposed KNOWN-ISSUES F12 text for the publish:**
- **Gone:** "Built without USD and OpenVDB (no `.usd`/`.vdb`, no voxel remesh or volume nodes)" becomes "Built
  without USD (no `.usd` import/export)".
- **New sentence:** "From blender -8: OpenVDB volumes (`.vdb` import, voxel remesh, Volume to Mesh, Cycles
  volumes, OpenVDB fluid caches), the Exact Boolean solver (GMP), QuadriFlow remesh, Draco glTF compression, Grease
  Pencil Trace Image and PDF export, and translated interfaces (Preferences ▸ Interface ▸ Translation)."
  (Mesh to Volume and the geometry-nodes volume nodes need OpenVDB too, but were not probed.)
- Everything else in F12 stays.

**Proposed USER-GUIDE §11.6 text** (replacing the "Limits are listed …" item's "no USD/OpenVDB" and adding a
sentence to **Works**):
> From blender 3.6.23-8: **OpenVDB** — File ▸ Import ▸ OpenVDB (`.vdb`), voxel remesh (Remesh modifier in Voxel
> mode, Object Data ▸ Remesh), the Volume to Mesh modifier, volumes rendered by Cycles, and fluid caches in
> OpenVDB format (the default); the **Exact** solver of the Boolean modifier (it was silently replaced by Fast);
> **QuadriFlow** remesh; glTF export with **Draco** mesh compression; Grease Pencil **Trace Image** and **PDF
> export**; the interface in **38 languages** (Preferences ▸ Interface ▸ Translation, or the splash screen's
> Language). (blender -8 needs boost1.83 -2; only a fresh install from the test packages was checked, not
> `pkgman update` over an installed -7 — check that at the publish.)
>
> Limits: no USD; …(the rest as now).

**Recommendation:** publish blender -8 together with **boost1.83 -2** (blender -8 cannot install against the
published -1: it requires `boost1.83 >= 1.83.0-2`), openvdb, c_blosc, gmp, potrace and libharu (+ their _devel
packages). lz4, zstd, tiff and libiconv are already published. Revision bump checklist (AGENTS.md): the
`.hpkg`s into `artifacts/packages/` (boost1.83 -1 and blender -7 to packages-old), the same files into
`sources/haiku/generated.arm64/download/` if the image lists them, and the versions in
`build/jam/repositories/HaikuPorts/arm64`.

### 7.16 blender -9: USD import/export (2026-11-20 14:14–16:15; sessions b9 15:09–15:21, b9b, b9c, b9d 15:32–15:34, b9e 15:35–15:47, b9f 15:47–15:50, b9g 16:00–16:02, b9h 16:04–16:07, image-2026-11-19b)

Task B9, time-boxed to one working day: USD (File ▸ Import/Export ▸ Universal Scene Description, `.usd`/`.usda`/
`.usdc`/`.usdz`). Blender linked with USD after **54 minutes** (15:08); everything below is in
`scripts/build-blender.sh` (step `usd`, then the Blender steps) and `artifacts/packages-test/blender-9/` (not published).

**Route (feasibility, 14:14–14:24):**
- **USD version.** Blender 3.6 pins USD 23.05, whose `WorkDispatcher` uses the legacy `tbb::task` API that oneTBB
  removed. OpenUSD's CHANGELOG: **24.08 is the first release that builds with oneTBB** ("Added support for optionally
  building with oneTBB", PRs #2457–#2466); 23.11 and 24.05 do not. oneTBB **2022** needs one more change, which came
  with 25.05 (PR #3392, `m_wait_ctx` → `m_wait_vertex`); our oneTBB is 2022.3, so the patchset backports it. In
  24.08 every other legacy-TBB use is behind `TBB_INTERFACE_VERSION_MAJOR >= 12` (`work/dispatcher.h`,
  `threadLimits.cpp`) or only in the precompiled headers (off). 24.08 also makes Boost optional (only for Python).
- **The API gap is nil.** Before building anything, every `source/blender/io/usd/intern/*.cc` was compiled
  `-fsyntax-only` with the cross compiler and Blender's flags against the unpacked 24.08 tree (+ a generated
  `pxr/pxr.h`): **one error**, `SEP_STR` undeclared in `usd_common.cc` — a Blender bug in code that is only compiled
  when USD has no Python support, which Blender's own library builds never have (`patches/blender/0015`). The
  `usdImaging` shape adapters' `GetPoints`/`GetTopology` that 3.6's gprim reader calls still exist in 24.08.
- **Rejected: USD 23.05 against a private legacy TBB 2020.3.** USD's public headers include TBB headers
  (`work/dispatcher.h`, `tf/…`), so Blender's io/usd translation units would see both TBBs next to the BLI headers
  that include oneTBB; TBB 2020 has no Haiku port; and two schedulers would share the four cores.
- **Not optional: usdImaging.** `usd_reader_shape.cc` includes the usdImaging adapters unconditionally
  (`USD_HAS_IMAGING` only selects a test), so imaging is built, without GL (no Storm/hgiGL/glf).

**USD 24.08** (ours, `tools/recipes/media-gfx/usd/` + `patches/usd-24.08.patchset`, 3 commits):
- **`arch: Haiku support`:** Haiku takes the Linux code paths (`ARCH_OS_LINUX` + `ARCH_OS_HAIKU`) except for what it
  lacks: `<sys/statfs.h>`, `<ucontext.h>`, ptrace (a debugger is attached when the team has a debugger nub thread),
  `mincore`, `sincos` without `_GNU_SOURCE`, `_SC_LEVEL1_DCACHE_LINESIZE` (64), `/proc/self/exe` (the team's
  `B_APP_IMAGE`), `__libc_fork`, and the "non-locking execve", a raw Linux system call (`svc 0`, x8 = 221: plain
  `execv`). **And `ArchGetAddressInfo()`**, which used `dladdr()` only `#if defined(_GNU_SOURCE)`: without it Plug
  could not find its plug-in descriptions beside the library — the first Pi run failed every USD operation with
  "Failed to find plugin for ArDefaultResolver" and Blender then crashed (`TF_DEBUG=PLUG_*`: "Failed to determine
  absolute path … using ArchGetExecutablePath()", search under `apps/Blender/usd`). The step now fails unless
  `libusd_ms` imports `dladdr`.
- `sdf: remove SdfChildrenProxy::_ValueProxy::operator=` (calls a `_Set` that does not exist; GCC 16 checks
  template bodies); `work: oneTBB 2022` (PR #3392).
- Options: monolithic shared (`libusd_ms.so`, the name Blender's FindUSD takes), imaging + usdImaging without GL,
  no Python, tools, tests, examples, usdview, MaterialX, OpenVDB, OIIO, OCIO, Ptex, Embree, PRMan, Alembic or Draco
  plug-ins, no precompiled headers.
- **Plug-ins at run time:** Blender installs `datafiles/usd` only with its own library tree (`LIBDIR`), so
  `ensure_usd_plugin_path_registered()` finds nothing here; USD finds `lib/usd/*/resources/plugInfo.json`
  relative to `libusd_ms` (`Plug_InitConfig`). The monolithic build puts usdShaders, sdrGlslfx and hioAvif in
  `<prefix>/plugin/usd`; the step moves them into `lib/usd` (no top-level `plugin/` in the package). All 27
  plug-ins have an empty `LibraryPath` (they are inside `libusd_ms`). `pxrConfig.cmake`/`cmake/` name the host's
  sysroot and are dropped.
- Checks (the step fails otherwise): oneTBB 2022.3 found; `libusd_ms` links libtbb and libosdCPU and no
  GL/Python/Boost, no run path, imports `dladdr`; `PXR_VERSION 2408`; no Python (`pyModule.h` absent — else Blender's
  FindUSD turns `USD_PYTHON_SUPPORT` on — and `PXR_PYTHON_SUPPORT_ENABLED` under `#if 0`); usdImaging headers; the
  plug-in descriptions Blender's reader/writer need (ar, sdf, usd, usdGeom + `generatedSchema.usda`, usdShade,
  usdLux, usdSkel, usdVol, usdImaging, usdShaders); each non-empty `LibraryPath` resolves to `libusd_ms`.
- Build: 2615 steps, **8½ min** at `-j8` (heavy-build, 3 GB/job), 16 warnings (USD's own: array bounds, range-loop
  copies, …). `libusd_ms.so` 51 MB (42 MB stripped); NEEDED libtbb, libosdCPU, libstdc++, libgcc_s, libroot.

**Blender:**
- `WITH_USD ON` (`tools/cmake/blender-minimal.cmake`), `USD_ROOT_DIR` for both configures; guards: `WITH_USD` in the
  cache and `-DWITH_USD` in `build.ninja`, `blender` NEEDED `libusd_ms.so`, no `3.6/datafiles/usd`.
- `0015-usd-common-include-path-util.patch` (above).
- **`0016-blenlib-haiku-recursive-operation.patch` — a crash on Haiku in every revision so far.** Haiku's `struct
  dirent` has no `d_type`, so `recursive_operation()` (`BLI_delete(…, true, …)`, `BLI_copy` of a directory) stats each
  entry, building its path with `BLI_path_join(…, NULL)`; in 3.6 `BLI_path_join` is a macro that counts its
  arguments, so the NULL became one more path element and `BLI_path_join_array` dereferenced it. Any recursive
  delete or copy of a **non-empty** directory crashed. USDZ export (it deletes its temporary directory) hit it:
  `.usdz` was written, then Blender died (session b9c: debug_server `report` + `addr2line`: `BLI_path_join_array` ←
  `recursive_operation` ← `export_endjob_usdz_cleanup`). The entry's path is already in `from_path`.
- Build: incremental 2443 steps in 7 min (15:01–15:08) + the 0016 relink. Then a **clean** `BLENDER_CLEAN=1
  build-blender.sh configure blender_package`: 17 min (15:36–15:53, 4988 steps), 881 warning lines; its package has
  the same provides, requires and 2457 paths as the tested one (which was put back). The patched tree equals a fresh
  3.6.23 + `patches/blender/*.patch` (0001–0016).

**Results on the Pi** (`tools/pi-tests/blender-b9.sh` + `blender-b9.py`; `artifacts/blender-tests/b9d/`, final in
`b9e/`), against the official x86-64 Blender 3.6.23 (USD 23.05) running the same script
(`artifacts/blender-tests/ref/b9ref.txt`, its files in `ref/b9/`):

| Check | Pi, blender -9 (USD 24.08) | x86-64 official 3.6.23 |
|---|---|---|
| `bpy.app.build_options.usd` | 1 | 1 |
| Factory scene + Suzanne (Subdivision, render level 2) + a material → `.usdc`, re-imported | 762 705 bytes; **4 objects (camera, light, 2 meshes), 7966 vertices, 7878 faces, 2 materials** | 762 704 bytes; the same counts |
| … → `.usda`, re-imported | 2 535 574 bytes; the same counts | 2 534 140 bytes; the same |
| … → `.usdz`, re-imported | 762 867–762 871 bytes (the zip's time stamps); the same counts | 762 865–762 870 bytes; the same |
| … → `.usd` (crate), re-imported (session b9g) | 762 705 bytes; the same counts | 762 697 bytes; the same |
| x86-64's `.usdc`/`.usda`/`.usdz`/`.usd` imported on the Pi | the same counts, all four | — |
| The Pi's `.usdc`/`.usda`/`.usdz` imported by x86-64's Blender | — | the same counts, all three |
| **As the GUI runs them** (`blender-b9-gui.py`, a window; session b9h, 2 runs): File ▸ Export's file browser confirmed, the export **as a window-manager job** (worker thread), then the import job | 3333 bytes; 3 objects (camera, light, mesh, 8 vertices) re-imported, 2 of 2 | 3331 bytes; the same (Xvfb) |
| UsdGeom gprims (usdImaging adapters): Capsule, Cone, Cube, Cylinder, Sphere | **82/90, 31/20, 8/6, 42/30, 92/100** vertices/faces | the same |
| Times (export / import): usdc, usda, usdz | 377/47, 349/211, 231/36 ms | 76/8, 90/70, 64/8 ms |

- The `.usda` text equals x86-64's (as sorted lines; the "sha" in the log is not a byte-identity check: two x86-64
  runs gave different hashes and 2 534 140 / 2 534 139 bytes) except for the prim order (`defaultPrim` Suzanne vs Cube) and the last digit of
  some floats of the subdivided Suzanne (points, normals, UVs, extent: OpenSubdiv's float arithmetic on arm64; the
  cube, camera, light and materials are identical): 5 lines differ after sorting.
- 0 debugger entries in the final sessions (b9d–b9h); USD printed no warnings or coding errors.
- The headless checks run the operators directly (no job); the GUI check runs them through invoke, where Blender
  starts them as window-manager jobs (`as_background_job`): USD on a worker thread works too.

**Regression probes with the final -9 installed** (session b9e 15:35–15:47, `artifacts/blender-tests/b9e/`; the
same probes on the package before 0016, session b9, gave the same within 0.6 s, but a manual `pi-ssh` debugging
command ran during b9's M3, so its numbers are not quoted):
- M3: version, bpy (Python 3.10.22), subsurf 98 vertices, 960×540 cube **9.7 s**, factory 1080p **3 min 29 s**,
  1.57 GB peak, Filmic (-8: 9.8 s, 3 min 31 s, 1.55 GB).
- M5: EEVEE factory **35.6 s**, scene 57.2 s, Cycles scene 81.4 s, the SSS message once (-8: 35.4, 57.2, 82.0 s).
- M4 on the staged tree: 3.3 core context; fps default **6.4**, edit mode 6.8, 100k triangles 6.3 (-8: 6.4/6.8/6.3);
  save and reload; Preferences; F12 Cycles 9.9 s; keyinject; **0 "wrong thread" lines** (frames `b9e/m4/`).
- `blender-probe.sh`: `sdlthread: PASS`, every program status 0. 0 debugger entries.
- **Update path** (session b9f 15:47–15:50): on a fresh image `pkgman install blender` takes the published -8 from
  the repository (52 s); then -9 + usd from files over it (3 s); the B9 checks pass on that install (the same
  numbers).

**Packages** (`artifacts/packages-test/blender-9/`):

| Package | Size | Note |
|---|---|---|
| blender-3.6.23-9 | 65.0 MB (-8: 64.8) | requires `lib:libusd_ms` |
| usd-24.08-1 | 12.7 MB | `libusd_ms.so` + `lib/usd` (27 plug-ins); requires haiku, libtbb, libosdcpu (both published); license: the Tomorrow Open Source Technology License 1.0 (OpenUSD's from 24.08: Apache 2.0 with a different §6, Trademarks), its text in `data/licenses` |
| usd_devel-24.08-1 | 1.6 MB | headers (`develop/headers/pxr`) |

**blender -9 against the published -8** (`scripts/package-diff.sh`): requires gain `lib:libusd_ms`, nothing dropped;
files 2457 → 2457, **the same paths** (USD's data is in the usd package).

**Sysroot:** `artifacts/sysroot-arm64` now also holds USD in `non-packaged/` (`lib/libusd_ms.so`, `lib/usd/`,
`include/pxr/`), unpublished.

**Not done / limits:**
- No USD Python module (`from pxr import Usd` in Blender's console): the official build has it; ours is built
  without Python (Blender 3.6's io/usd does not need it; it would bring Boost.Python and a `lib/python` tree).
- Not probed: USD skeletal animation (UsdSkel) and blend shapes, volumes (UsdVol with OpenVDB assets), instancing,
  animated (time-sampled) export; the file browser was confirmed by script, not clicked.
- The update was checked from files (`pkgman install` of -9 + usd over -8), not as `pkgman update` from a
  repository that has -9.

**Proposed KNOWN-ISSUES F12 text:** "Built without USD (no `.usd` import/export)" goes. **New sentence** for the
USER-GUIDE Blender section: "From blender 3.6.23-9: **USD** — File ▸ Import/Export ▸ Universal Scene Description
(`.usd`, `.usda`, `.usdc`, `.usdz`), with OpenUSD 24.08 (the usd package). Blender's Python has no `pxr` module."
Also fixed in -9 for every user: recursive deletes and copies of non-empty directories (0016) no longer crash.

**Recommendation:** publish blender **-9** with **usd 24.08-1** (+ usd_devel): every check equals the official
x86-64 3.6.23 in both directions (`.usd`, `.usdc`, `.usda`, `.usdz`; headless and as GUI jobs), the regression
probes are unchanged from -8, and -9 also carries the Haiku recursive-delete fix (0016). Revision bump checklist (AGENTS.md): the `.hpkg`s into `artifacts/packages/` (blender
-8 to packages-old), the same files into `sources/haiku/generated.arm64/download/` if the image lists them, and the
versions in `build/jam/repositories/HaikuPorts/arm64`; usd's requirements (libtbb, libosdcpu) are published. GitHub
size: blender -9 is 62.0 MiB (-8 61.8), usd 12.1 MiB.

### 7.17 BW1: the viewport's memory traffic, measured at the bus (2026-11-21/22; session bw1, image-2026-11-21b + blender -9)

Question: §7.10/§7.11 concluded the viewport is GPU-bound (~37 render jobs × 5.3 ms per orbit frame). Is it
bound by memory bandwidth, and is there a cheap cut?

**Tool.** `tools/haiku-tests/axibw/` (README): reads the BCM2711 system AXI bandwidth monitor (0xfe009800) through
`/dev/misc/mem`, three bus watchers per window. Found and calibrated on the Pi:
- **V3D is bus 7** (the vendor's table calls it ARGON, the rpivid port; they share it) **with AXI ID v3d1** (ID
  filter 26; v3d0/v3d2/argon read 0). Selectors 37–42 read as 5–10 (32+n aliases n there).
- **16 bytes per transaction** for every master checked: CPU memcpy (`axibw selftest`, ARM_UC) 15.9 R / 16.0 W;
  HVS scan-out 31.11 M reads/s = 497.7 MB/s = 1920×1080×4×60 exactly; V3D with `tools/gl-tests/glbw.c` (render
  passes of known size): clear-only 1024² RGBA8 +2.6 %, load+store RGBA8/RGBA16F +3–4 % (control lists, tile
  state). Bytes below = transactions × 16.
- **V3D's ceiling** (glbw at Blender's viewport size 1322×762): load+store 5.5–5.7 GB/s (R+W), clear-only stores
  5.0 GB/s, a full-screen shaded pass 4.2–4.3 GB/s. Time scales with bytes; the render-target count (V3D's tile
  size shrinks with it) adds nothing beyond its bytes: RGBA16F load+store 2.92 / 6.00 / 10.07 / 13.25 ms per pass for
  1–4 targets. `V3D_DEBUG=db` (double-buffered tiles) changes nothing, in glbw or in Blender.

**Blender** (`tools/pi-tests/blender-bw.{sh,py}` + `blender-bw-table.py`): per config 8 s of orbiting and 8 s idle
while axibw samples V3D, HVS, ARM_UC every 500 ms; frame time from the orbit. Orbit = the scripted 2° `view_orbit` +
region redraw (blender-perf.py's), or with `NAV=1` a **real middle-button drag** (uiinject; frames = a POST_PIXEL draw
handler's calls), which gave the same frame times (193.3 / 158.0 / 124.4 / 196.3 ms for solid / AA off /
AA+smooth off / Material Preview) — the scripted numbers stand for interactive navigation. n = 3 unless noted,
spread ≤ 0.6 ms.

| 1600×900 window (viewport 1322×762) | ms/frame | fps | V3D R+W GB/s | V3D MB/frame (R+W) |
|---|---|---|---|---|
| factory (Solid, Anti-Aliasing 8, Smooth Wires on) | 193.0–193.3 | 5.18 | 1.48+1.19 | 285+229 = **514** |
| Preferences ▸ Viewport ▸ Anti-Aliasing **None** | 157.7–157.8 | 6.34 | 1.43+1.25 | 226+198 = 424 |
| Anti-Aliasing FXAA / 5 / 8 | 193.0–193.3 | 5.18 | same | 514 |
| scene viewport_aa off (Workbench F12 setting) | 193.0 (n=1) | 5.18 | same | 514 |
| Smooth Wires off | 159.1–159.6 | 6.28 | 1.56+1.27 | 248+203 = 451 |
| Anti-Aliasing None + Smooth Wires off | 123.8–124.0 | 8.06 | 1.52+1.38 | 188+170 = 358 |
| grid (floor + axes) off (n=1) | 168.0 | 5.95 | 1.67+1.36 | 280+228 = 508 |
| selected-object outline off (n=1) | 175.1 | 5.71 | 1.46+1.17 | 256+205 = 461 |
| all overlays off (n=1) | 142.1 | 7.04 | 1.68+1.35 | 238+192 = 430 |
| AA None + Smooth off + grid off + outline off (n=1) | 87.4 | 11.44 | 2.01+1.88 | 176+165 = 341 |
| Material Preview (EEVEE) | 195.5–196.3 | 5.10 | 1.43+1.00 | 279+196 = 475 |
| Material Preview + Smooth Wires off | 163.0–163.2 | 6.13 | 1.54+1.07 | 251+175 = 426 |

| 1024×600 window (viewport 845×485) | ms/frame | fps | V3D MB/frame (R+W) |
|---|---|---|---|
| factory | 81.5–81.7 | 12.2 | 120+95 = 215 |
| Anti-Aliasing None | 66.9–67.0 | 14.9 | 95+82 = 177 |
| Smooth Wires off | 67.5–67.6 | 14.8 | 104+84 = 188 |
| both | 52.9–53.0 | 18.9 | 80+71 = 151 |
| Material Preview | 83.7–83.8 | 11.9 | 120+83 = 203 |
| Material Preview + Smooth Wires off | 70.1 | 14.3 | 108+74 = 182 |

- **The ID filter misses nothing that matters:** unfiltered bus 7 against `argon/v3d1` while orbiting (session bw1
  second part, 01:42–): Solid 92.5 / 92.2 M reads/s, 74.1 / 74.1 M writes/s; Material Preview 89.3 / 88.7 and
  62.3 / 62.3. The difference is ID v3d2 (0.3–0.6 M reads/s, 1–2 MB per frame); v3d0 reads 0.
- **HVS** 498 MB/s at all times (the 1920×1080 desktop's scan-out; Blender changes nothing). **ARM** ~145 MB/s while
  orbiting, ~11 MB per frame each way: the CPU is not a factor. `v3d_stats` (its serial-line clock aligned to axibw's
  by a marker, offset 28.1 s): Solid orbit 34 render jobs per frame at 5.7 ms (bin 0.23 ms), Material Preview 37 at
  5.3 ms (bin 0.15 ms), GPU busy 99 % in both; in the idle window after the orbit 23 % (Solid) and ~19 % (Material
  Preview) busy.
- **Calibration against simple GL** (glmark2-es2, 800×600 window, axibw on bus 7 during 4 s of each scene): build 489
  fps, 0.34+2.87 GB/s; texture 440 fps, 0.84+2.56; shading 374 fps, 0.42+2.23; refract 59 fps, 3.27+1.43 (4.7 GB/s,
  near the ceiling); terrain 27 fps, 1.44+0.51 (1.95 GB/s, shader-bound). Blender's 2.7 GB/s sits with the
  shader-bound scenes, not with refract.
- **Not memory-bound.** The factory viewport moves 514 MB per frame at **2.7 GB/s, half of what V3D reaches** (5–5.7
  GB/s). At the ceiling those bytes would take ~93 ms of the 193. Frame time and bytes do not move together: the grid
  costs 25 ms and 6 MB (a full-screen shader), the outline 18 ms and 53 MB, AA 35 ms and 90 MB, Smooth Wires 34 ms and
  63 MB. The remaining cost is per-pass shading and texture fetch (the jobs are full-screen passes), not DRAM. That
  is consistent with §7.11's upper bounds (no loads at all −4 %, no stores −11 %) and caps any tile load/store or
  format work in Mesa well below its effort: **no Mesa change is justified** (none written).
- Cost scales with pixels: 1024×600 has 41 % of the pixels, 42 % of the time and of the bytes.
- Material Preview costs the same as Solid here (EEVEE's own AA is not affected by the Workbench setting).
- The idle windows after an orbit are not idle: Workbench (8 samples) and EEVEE keep drawing progressive
  anti-aliasing samples for seconds (V3D ~0.4 GB/s averaged over the 8-s window after a Solid orbit, ~0.7 GB/s after
  Material Preview), so per-frame numbers above are gross (orbit rate × frame time; V3D moves nothing when the GPU
  idles).

**Cheap change: `patches/blender/0017-draw-v3d-no-anti-aliasing-while-navigating.patch`** (haiku-rpi branch `bw1`,
not merged). Blender already draws navigation frames with 1 sample + SMAA; on v3d (renderer "V3D", the
GPU_DEVICE_UNKNOWN/OPENSOURCE class of 0004) it now leaves out the SMAA and the overlays' smooth-wire resolve while
`DRW_state_is_navigating()`, and the first frame after the navigation is anti-aliased as before (TAA accumulates).
v2 (4b8fad5, the version on the branch) also keeps Workbench's history/depth/SMAA buffers while navigating instead of
freeing and re-allocating them at every drag start and end (v1 freed them; frame times equal). Paint strokes count as
navigation in Blender (RV3D_PAINTING), so they lose anti-aliasing while drawn too. Real middle-button drag, control =
the packaged -9 binary without resources (uiinject cannot drive an app with B_ARGV_ONLY); 1600×900: v1 n = 3, v2 n = 1
(126.9 ms); 1024×600: v2 n = 3:

| | control ms/frame | 0017 ms/frame | fps | V3D MB/frame |
|---|---|---|---|---|
| factory settings | 192.5–193.4 | **126.6–126.8** | 5.18 → **7.89 (+52 %)** | 513 → 381 |
| Smooth Wires off | 159.6–159.9 | 124.2–124.3 | 6.26 → 8.05 | |
| Anti-Aliasing None | 158.0–158.1 | 126.6–126.7 | 6.33 → 7.90 | |
| Material Preview | 196.4–196.6 | 165.3–165.5 | 5.09 → 6.05 (+19 %) | 475 → 434 |
| 1024×600 factory | 81.6–81.9 | **54.0** (3 of 3) | 12.2 → **18.5 (+51 %)** | 215 → 159 |
| 1024×600 Material Preview | 83.9–84.1 | 70.7–71.0 | 11.9 → 14.1 | 202 → 184 |

- The frame after the drag (draw intervals around the drag's end, `BBW navtail`, 1600×900 Solid, 2 drags each): control
  193 ms during and after; v1 and v2 127 ms during, then 174–195 ms for the first anti-aliased frame and ~190 for
  the TAA samples after it — no extra cost at the transition.

- HDMI frames (artifacts/bw1/look-*.png): during the drag the wires and the cube's edges are aliased, as with the two
  settings off; 3 s after the drag the viewport equals the control's (anti-aliased; 1320×760 pixels compared, largest
  difference 3 of 255, capture noise); v2 the same (only the mouse pointer's shape differs). Scripted orbiting (not
  "navigating") is unchanged (193.5 ms with the v1 package), so only navigation frames differ.
- **Calibration of the binaries:** 0017's binary was linked in the -9 build tree (`ninja blender`, which also
  recompiled ~10 stale objects outside the draw module); stripped, it is the size of -9's binary.
- Test package **blender 3.6.23-10** in artifacts/packages-test/blender-10/: a **repack of the -9 package** (`package
  extract`, the v2 binary with -9's resources re-attached by xres, version and `provides` set to -10, `package
  create`), not a build-blender.sh build. The v1 repack installed with `pkgman`, started and orbited on the Pi (exit 0,
  0 PANIC); the v2 repack itself was not installed (its binary was tested directly). Not published. The shared build
  tree was returned to -9's sources afterwards (0017 reverse-applied, relinked). To ship: 0017 into patches/blender/ on
  main, build-blender.sh's `--revision 10` + its comment, the usual bump steps.

**The candidates of the task, one by one:**
- TLB loads/stores of buffers a pass does not need: bounded by §7.11 (−4 % / −11 % with none at all), and the bus is
  half used; not pursued.
- MSAA: Blender 3.6's viewport framebuffers are single-sample (Workbench and the overlays anti-alias in shaders);
  nothing to cut.
- Depth formats (D24S8 throughout): not examined separately; their loads/stores are inside §7.11's bounds.
- Passes that could be skipped: Workbench's SMAA and the overlays' smooth-wire resolve while navigating → 0017;
  the grid and the outline are user choices (documented), the scene's viewport_aa does nothing in the viewport.
- The SDL present path: §7.10 (one 5.6 MB cache sync, ~0.65 ms per frame); ARM traffic 11 MB per frame. Not a factor.
- V3D tile size / TLB format: glbw shows no cost beyond bytes for smaller tiles (more targets), and double-buffered
  tiles (`V3D_DEBUG=db`) change nothing. Not a lever.

**Recommendation.** Merge 0017 and publish blender -10 with the next release: +52 % fps while orbiting at the
default settings, no change to still frames. With it, the Smooth Wires and Anti-Aliasing settings no longer matter
while navigating; what is left for users (§7.8) is the grid and outline overlays (−13 % / −9 % of the factory frame
time) and a smaller window (1024×600 with 0017: 18.5 fps).
Not cheap, and not done: making the passes themselves cheaper (the grid's and SMAA's shaders on V3D's QPUs, fewer
overlay framebuffer switches, half-resolution overlays) — that is shader/draw-manager work, where the bus monitor
now shows whether a change moves bytes or only time.

### 7.18 blender -10: 0017 built and published (2026-11-22 02:12–03:40; session b10 03:21–03:35, image-2026-11-21b)

Task B10: build blender **3.6.23-10** properly (BW1's -10 in `artifacts/packages-test/blender-10/` was a repack of -9
with a relinked binary; deleted) and publish it.
- **Build:** `scripts/build-blender.sh` at `--revision 10` (out to `artifacts/packages-test/blender-10/`; `stage` takes
  blender from there). The `src` tree BW1 left (0017 reverse-applied) was deleted and recreated, so the build is
  a fresh 3.6.23 + 0001–0017: `BLENDER_CLEAN=1 build-blender.sh blender_source blender_package`, hosttools and
  configure from scratch, 4988 steps in 24 min (02:13–02:37), 881 warning lines (as -9). The `WITH_*` cache values
  and the `blender` NEEDED list equal -9's build (saved before the clean).
- **Against the published -9** (`scripts/package-diff.sh`): provides/requires the same (only the version), files
  2457 → 2457, the same paths; 65 045 307 bytes (-9: 65 042 171).
- **Pi** (`artifacts/blender-tests/b10/`): `pkgman install` of the -10 file over the published repository on a fresh
  image-2026-11-21b. The first try failed after 89 s on a download ("Failed to download package oidn: Operation
  would block"); the same install run again a minute later (blender-b9.sh's) succeeded, `pkgman search` shows
  `blender 3.6.23-10`, the installed binary is the package's (same size).
  - B9 USD (`blender-b9.sh`): every check PASS (`.usdc` 762 705, `.usda` 2 535 574, `.usdz` 762 871 bytes as -9;
    `.usd` 762 704, one byte less than -9's 762 705 in session b9g; 4 objects, 7966 vertices, 7878 faces, 2 materials; the five primitives; x86-64's
    four files import).
  - M3: cube 9.8 s, factory 1080p 3 min 31 s, 1.57 GB peak, Filmic (-9: 9.7 s, 3 min 29 s). M5: EEVEE factory
    35.8 s, scene 57.4 s, Cycles scene 81.6 s, the SSS message once (-9: 35.6, 57.2, 81.4). `blender-probe.sh`: every
    program status 0, `sdlthread: PASS`.
  - **BW1 drag** (`blender-bw.sh`, NAV=1, real middle-button drag; uiinject cannot drive the packaged app, which has
    B_ARGV_ONLY, so the installed package's binary was run with its resources stripped — `.text` identical — beside a
    link to the installed `3.6/`): 1600×900 factory Solid **127.1 ms (7.87 fps; -9 control in §7.17: 193.0 ms, 5.18
    fps, +52 %)**, V3D 200+179 = 379 MB/frame (§7.17: 381); Material Preview 166.1 ms (6.02 fps; -9: 196.5);
    1024×600 Solid **54.0 ms (18.5 fps; -9: 81.7)**. n = 1 each. The frames after the drag: 170, 90, then ~195 ms
    (the anti-aliased frame and TAA samples, as §7.17).
  - **Still frames** (`blender-bw-look.sh`, HDMI): 3 s after the drag the viewport equals BW1's 0017-v2 frame (1440×770
    compared, largest difference 8 of 255, no pixel above 8) and the -9 control's except the pointer's 19×17 pixels
    (as in BW1): anti-aliasing is back. During the drag the edges are aliased (5543 distinct colours in the crop;
    control 6119, BW1's 0017 5597).
  - 0 debugger entries, 0 PANIC (syslog and the serial log). The bench lock waited 02:38–03:21 behind the other
    project's gate; the session was stopped at 03:35 (card untouched).
- **Published** (03:36, packages repository b8aa108): -9 to `artifacts/packages-old/`, -10 into `artifacts/packages/`, `publish-repo.sh`;
  `…/arm64/packages/blender-3.6.23-10-arm64.hpkg` serves HTTP 200 (65 045 307 bytes). Blender is not in the jam
  image's repository list (no `HaikuPorts/arm64` or `download/` change); the mega image takes the newest file.

### 7.8 Draft user documentation (for USER-GUIDE / KNOWN-ISSUES at the next release; not published yet)

**USER-GUIDE — Blender 3.6 (3D modelling, animation, Cycles rendering)**

> Blender 3.6 LTS runs on the Pi 4 with the desktop OpenGL 3.3 driver. Install it with
> `pkgman install blender` (it brings Python 3.10 with NumPy, OpenImageIO, OpenColorIO, OpenSubdiv,
> OpenImageDenoise, Alembic, FFTW, TBB and the SDL2 it needs) and start it from Deskbar ▸ Applications ▸ Blender, or `/boot/system/apps/Blender/Blender`.
> - **Works:** the whole UI, the solid (Workbench) viewport, edit mode, modifiers including Subdivision
>   Surface, save/load, the Preferences window, Cycles rendering on the CPU (F12 into the image editor, or
>   headless: `Blender -b scene.blend -E CYCLES -f 1`), Python scripting, Filmic colour management, video
>   output and the Video Sequencer (FFmpeg), sound playback (SDL), typing any characters your keymap gives;
>   from blender -7 also **denoising** (Cycles' Denoise for F12 and the viewport, the compositor's Denoise
>   node; OpenImageDenoise on the CPU), Alembic import/export, the Ocean modifier, fluid
>   simulation (Mantaflow; smoke baking checked, liquids not yet) and Python's `aud` audio module.
> - **Video output:** choose FFmpeg Video, container MPEG-4, codec H.264 and audio AAC: H.264 is encoded by
>   the Pi's VideoCore (fast; the Output Quality presets become a bit rate, or set Constant Bitrate). MPEG-4,
>   MJPEG and FFV1 also work. MediaPlayer plays the result.
> - **EEVEE and Cycles both render** (F12, Material Preview, Rendered view). EEVEE is the faster one; on the
>   Pi 4's GPU it renders without Subsurface Scattering (see Known issues).
> - **Speed:** the default cube renders in about 1½ minutes at 1920×1080 (4 cores), 3½ minutes with
>   denoising on (the default in a new file; Render Properties ▸ Sampling ▸ Denoise, Prefilter Fast makes
>   it about a minute shorter). The viewport draws about
>   5 frames per second while navigating in a 1600×900 window (8 with blender -10, which leaves out
>   anti-aliasing while you navigate); the GPU's time grows with the window's size, so a smaller window is much
>   faster (1024×600: 12 fps, 18 with -10). Turning off the viewport's grid and the selected object's outline (Viewport
>   Overlays menu) helps further; with blender -9 also Preferences ▸ Viewport ▸ Smooth Wires and Anti-Aliasing.
> - **Memory:** a simple scene needs about 300–400 MB; large scenes and big textures may not fit in 4 GB.
> - **Input:** click into the Blender window once before typing — keys go to the active window, and to the
>   area under the mouse pointer.

**KNOWN-ISSUES — Blender**

> - **EEVEE without Subsurface Scattering:** the Pi 4's GPU (V3D 4.2) has 4 colour attachments, EEVEE's
>   SSS needs 6; subsurface materials render as diffuse (a message in the terminal says so once). Use
>   Cycles for skin, wax and similar materials.
> - **Denoising is slow and needs memory** (OpenImageDenoise on the CPU): about 20 s per denoising pass of a
>   1920×1080 frame, three passes with the default Accurate prefilter (one with Fast), ~1.5 GB of memory;
>   viewport denoising redraws every few seconds.
> - **No USD or OpenVDB** (no `.usd`/`.vdb` import, no voxel remesh, no volume conversion nodes; fluid
>   caches use Blender's own format).
> - **H.264 quality on flat scenes:** the VideoCore encoder caps quality on simple content, so Medium and
>   Low presets can give the same file; no B-frames, no lossless H.264 (use FFV1 for lossless).
> - GPU subdivision is off (no compute shaders); subdivision runs on the CPU.
> - No tablet pressure; input methods (IME) untested.

### 7.19 blender -11: starts from the Deskbar and the Test Apps folder (TA1, 2026-11-22; sessions ta1, mega36 and a test image)

- Owner report: Blender from the Test Apps folder or the Deskbar shows no window; from a Terminal it works. Two
  causes, one of them Blender's: the whole story in [tracker-launch.md](tracker-launch.md).
- **Deskbar entry (Blender's own bug):** the Deskbar's Applications entry is a link, and the roster passes the link
  as `argv[0]`. `where_am_i()` takes `argv[0]` as the program path on Haiku, so Blender looked for `3.6/` in
  `/boot/system/data/deskbar/menu/Applications/`: `bpy: couldn't find 'scripts/modules'`, `No module named
  'bpy'`, then `Abort` (exit 1) about 2 s after the start, after a short-lived window. `patches/blender/0018`
  resolves the path with `realpath()` on Haiku (Linux has binreloc for this). blender **-11** (only `appdir.c`
  recompiled, 0 warnings; same file list as -10): `artifacts/packages-test/blender-11/`, also in
  `artifacts/packages-test/ta1/`.
- **Test Apps entry (Haiku's bug, fixed in libbe):** the launcher `exec`s Blender in the team the roster
  pre-registered; the exec deleted the looper port the registrar had given the team, and Blender's BApplication
  (in SDL's "SDLApplication" thread) adopted the dead port and spun; SDL waited forever for `ReadyToRun()`.
- The `B_ARGV_ONLY` flag of -5 (§7.12) is why a `B_QUIT_REQUESTED` from another program cannot reach Blender
  (the roster gives no messenger to an argv-only application): the TA1 checks quit it by sending its windows
  B_QUIT_REQUESTED, as their close buttons do (`trackeropen -w`): gone after 0.6 s from both entries.
- **Published (R4, 2026-11-23):** blender 3.6.23-11 in the package repository (the test package's bytes, sha256
  9128674b…; -10 to packages-old); the libbe fix ships in image-2026-11-23; mega37 has both. Owner by hand on mega36
  (2026-11-22, started from a Terminal): the "Classroom" demo scene loads quickly, the viewport preview is correct, an
  F12 render starts and its first iterations look right.

### 7.20 BR1: the render window's tab above the screen; the zoom button "goes full screen" (libsdl2 -9, 2026-11-23; sessions br1)

- **Owner reports (mega36, 2026-11-22):**
  1. F12 opens the "Blender Render" window about as large as the screen, so high that its tab is above the top
     edge. Dragging an edge fixes it.
  2. The main window's zoom button made Blender "full screen". Window > Toggle Window Fullscreen then did nothing,
     and there was no way back.
- **One cause, in our libsdl2's Haiku backend** (also upstream SDL2's, `src/video/haiku`).
  - SDL places a window by its content area, and `_InitWindow()` makes that the BWindow's frame unchanged. The tab
    and border lie outside the frame, and Haiku moves no window by itself.
  - So a window at y = 0, or one as large as the screen, has its tab above the screen.
- **Blender asks for such windows twice:**
  - **The render window:** `render_view_open()` asks for the render size + 30 × 60 (1950 × 1140 at the default
    1920 × 1080). `wm_window_check_size()` clamps that to the *screen* size, centred on the mouse, and
    `wm_window_ghostwindow_add()` passes the result to `SDL_CreateWindow()`.
    - With the mouse at (700, 450) in the main window, the content frame is (-255, -60)–(1664, 1019).
  - **The main window:** with no geometry stored, it is created at 0,0 with the screen size
    (`wm_window_ghostwindows_ensure()`), then maximized. SDL_MaximizeWindow → `BWindow::Zoom()` zooms it to the
    screen minus the Deskbar, and **remembers the 0,0 screen-size frame as the one to zoom back to.**
    - The zoom button then un-zooms to that frame. It looks exactly like full screen: no tab, the Deskbar covered.
- **Why the toggle "did nothing":**
  - The `Zoom()` hook of `SDL_BWin` posted `BAPP_MAXIMIZE` for both directions. `BAPP_RESTORE` was never
    handled, so SDL_WINDOW_MAXIMIZED never cleared.
  - Toggle Window Fullscreen → `SDL_SetWindowFullscreen(1)` gives the same frame without a border. Toggling back
    restores the same 0,0 screen-size frame (`_non_fullscreen_frame`, then `_Restore()` to `_prev_frame`, also
    that frame). Three states, one picture.
  - A second `SDL_MaximizeWindow()` would also have un-zoomed: `BWindow::Zoom()` toggles.
- **Measured on -8** (mega36, session br1 00:51–00:58; window frames by scripting with `tools/haiku-tests/winframes`,
  HDMI frames in `artifacts/br1/`):

  | Step | Main window frame (content) | Look |
  |---|---|---|
  | start (maximized) | 5,29 – 1778,1074 | titled |
  | zoom button | **0,0 – 1919,1079**, tab off screen (`a3-zoom.webp`) | titled |
  | Toggle Window Fullscreen | 0,0 – 1919,1079 | no border |
  | toggle again | 0,0 – 1919,1079 | titled |
  | zoom button | 5,29 – 1778,1074 | titled |

  F12: "Blender Render" at **-255,-60 – 1664,1019**: tab and left edge off screen (`a2-render.webp`).
- **Fix: `patches/libsdl2/libsdl2-2.32.10-haiku-window-placement.patch`, libsdl2 -9.**
  - `SDL_BWin::KeepTabOnScreen()` uses `DecoratorFrame()` for the border and tab sizes. It moves a window whose tab
    or left border would be off the top or left edge, and shrinks a window that cannot fit if it is resizable.
    Other overhangs stay where the program put them.
  - It runs at creation (before `SDL_CreateWindow()` returns, with SDL's x/y/w/h updated, because Blender reads
    them at once), after `SDL_SetWindowPosition()`, and on leaving full screen.
  - Borderless and fullscreen windows are left alone.
  - The `Zoom()` hook posts `BAPP_RESTORE` for the un-zoom (it mirrors BWindow's remembered frame), and
    `SDL_RestoreWindow()` of a zoomed window does the same. The handler maps it to SDL_WINDOWEVENT_RESTORED, which
    also gives unminimizing its missing event.
  - `SDL_MaximizeWindow()` zooms only a window that is not zoomed.
  - Not used: `BWindow::MoveOnScreen(B_MOVE_IF_PARTIALLY_OFFSCREEN)`. It also pulls in windows that only overhang
    the right or bottom edge, and centres windows placed fully off screen.
- **After, -9** (same session, the test library first in LIBRARY_PATH, `listimage` shows
  `/boot/home/br1/lib/libSDL2-2.0.so.0`):
  - F12: "Blender Render" at **5,29 – 1914,1074**. The tab is visible, the window fits the screen and the render
    completed (`b2-render.webp`).
  - Zoom and fullscreen sequence (`b-*.webp`):

    | Step | Frame | Look |
    |---|---|---|
    | start | 5,29 – 1778,1074 | titled |
    | zoom (un-zoom) | 5,29 – 1914,1074 (tab visible) | titled |
    | Toggle Window Fullscreen | 0,0 – 1919,1079 | no border |
    | toggle back | 5,29 – 1914,1074 | titled |
    | zoom | 5,29 – 1778,1074 | titled |

    - The un-zoomed frame covers the Deskbar (`b-zoom-005647.webp`). That is Blender's own start frame (the
      screen size, now fitted below the tab), not Zoom: Zoom leaves the Deskbar out, as before.

    - From the zoomed state: full screen, then back, gives the un-zoomed frame, because Blender sets "normal"
      (SDL_RestoreWindow). Zoom then gives the zoomed frame again.
  - Edit > Preferences: 375,186 – 1034,705, where Blender put it (`b-prefs.webp`). The main window opens maximized,
    as before (`b1-main.webp`).
  - 0 PANIC.
- **Other SDL programs** (mega37 = image-2026-11-23 + mega, session br1 01:50–01:58; the control is the image's
  libsdl2 -8, by `listimage`):

  | Program, request | -8 frame | -9 frame |
  |---|---|---|
  | sdl-winpos, centred 1920×1080, resizable | 0,0 – 1919,1079 (tab off) | 5,29 – 1914,1074 (shrunk to fit) |
  | sdl-winpos, centred 1920×1080, fixed size | 0,0 – 1919,1079 (tab off) | 5,29 – 1924,1108 (moved, size kept, bottom and right overhang) |
  | sdl-winpos at 200,150, then moved to 300,200 / 0,0 / 1700,900 | as asked | as asked, except 0,0 → 5,29 |
  | sdl-winpos borderless at 0,0 | 0,0 | 0,0 |
  | Quake II, 1920×1080 window | 0,0 – 1919,1079 (tab off) | 5,29 – 1924,1108: tab visible, HUD's bottom ~28 px below the screen (`q2-1920x1080-s9.webp`) |
  | Quake II, 1280×720 window | not run | 320,180 – 1599,899 (centred) |
  | Quake II, full screen | not run | 0,0 – 1919,1079, no border |
  | SuperTuxKart, 1280×720 window | not run | 320,180 – 1599,899 (`stk-1280x720-s9.webp`) |

  - SDL state (`tools/gl-tests/sdl-winpos`, `max max restore max`):
    - -8: after `SDL_RestoreWindow()` SDL still says "maximized", so the next `SDL_MaximizeWindow()` does nothing.
    - -9: "restored" is reported, and the next maximize zooms again.
  - Maximize → full screen → windowed returns to the zoomed frame on both.
  - A window *created* full screen and then made windowed: -8 at 0,0 (tab off), -9 at 5,29. Both keep the screen
    size, because SDL's backend takes the creation frame (already the screen) as its windowed frame. That part is
    unchanged.
  - Blender -11 on mega37 with -9: the same F12 and zoom/fullscreen frames as on mega36. 0 PANIC.
- **Session br1 02:14–02:21 (mega37):** -9 rebuilt with `-DSDL_SYSTEM_ICONV=OFF`. The first -9 build had found the
  sysroot's libiconv, which has been there since the Blender build, and linked `libiconv.so.2`, which the package
  did not require; -8 has SDL's own iconv. `NEEDED` is now the same as -8's and `package-diff.sh` shows no change in
  provides, requires or files. Results:
  - The same Blender frames as above, with the rebuilt library.
  - The -9 package activated in `~/config/packages` behaves the same (5,29; maximize/restore events).
  - **Real full screen and minimizing.** SDL minimizes a real fullscreen window when it loses the focus, and
    leaves full screen first:

    | Case | -8 | -9 |
    |---|---|---|
    | sdl-winpos `full min restore` | stays "minimized fullscreen" for ever | "restored", back in full screen |
    | Quake II full screen, another window takes the focus | minimized | minimized |
    | Quake II re-activated by scripting | windowed at 0,0, tab off | windowed at 5,29 with the tab |

    Neither version re-enters full screen after scripting activation: no unminimize reaches the program
    (`q2-refocus-s9.webp`). A resizable fullscreen window of screen size is shrunk to fit below the tab while it
    is minimized (RESIZED 1910×1046), and gets 1920×1080 back on restore.
  - 0 PANIC.
- **Unchecked:**
  - a real mouse click on the zoom button (B_ZOOM was sent by `winmsg`, the message the decorator sends);
  - unminimizing a fullscreen game from the Deskbar;
  - a second monitor;
  - a Deskbar placed at the top or on the left;
  - vkQuake and the other Quakes;
  - Wine (not SDL);
  - a window placed off the left or top edge, even fully off screen, is pulled in, while right and bottom overhangs
    stay. `move -50 400` was not run.
- **Published 2026-11-23 (P1):** the test packages' bytes (libsdl2 sha256 2cabd492…, _devel af3dfcc6…; haiku-pi/packages
  514cc04), and the image list names -9 (haiku `db1f8f465f`). Gate on mega38 (session p1, 0 PANIC): F12 render window
  5,29 – 1914,1074 with its tab, render completed; un-zoom 5,29 – 1914,1074; Toggle Window Fullscreen 0,0 – 1919,1079
  and back to 5,29 – 1914,1074; zoom 5,29 – 1778,1074. OpenArena, QuakeSpasm, vkQuake, Quake II and Quake III opened
  through Tracker, kept their window 10 s and ended 100–180 ms after a quit request. KNOWN-ISSUES G3 closed.
- **Tool caveats:**
  - `hey` cannot script an application started with B_ARGV_ONLY. `winframes` reached the copy without resources.
  - A program finds a `lib/` next to itself first (`%A/lib`), so the -8 control runs a copy elsewhere
    (`br1-win.sh`).
- **Blender is unchanged (no -12).** It asks for the same frames on Linux. There the window manager decides where
  the title bar goes; on Haiku nothing moves a window the program placed, so the SDL backend has to.

## 8. Files

- New, for step 0:
  - `tools/gl-tests/blender-glprobe.c` (SDL2 + EGL);
  - `tools/gl-tests/blender-vkprobe.c` (Vulkan, headless);
  - `tools/pi-tests/blender-probe.sh`.
- BW1 (§7.17): `tools/haiku-tests/axibw/` (bus monitor), `tools/gl-tests/glbw.c` (GPU traffic of known size),
  `tools/pi-tests/blender-bw.{sh,py}`, `blender-bw-table.py`, `blender-bw-look.sh`; raw logs and HDMI frames in
  `artifacts/bw1/` (not in git).
- BR1 (§7.20): `tools/pi-tests/br1-win.sh` (the Pi steps), `tools/haiku-tests/winframes.cpp` (window frames by
  scripting), `tools/gl-tests/sdl-winpos.c` (SDL window placement), `patches/libsdl2/…-haiku-window-placement.patch`;
  HDMI frames in `artifacts/br1/` (not in git).
- Kept: `artifacts/downloads/blender/blender-3.6.23/` (286 MB, the source tree M2 builds) and
  `artifacts/downloads/blender/sp-v5.3.0/` (31 MB, track B reference). Deleted: the 3.6.23 tarball (65 MB, on
  download.blender.org), the 4.0/4.1/4.2/4.5 sparse checkouts, the oneTBB headers and the scratch sysroot/builds.

## Sources (web)
- [Haiku forum: Blender port](https://discuss.haiku-os.org/t/blender-port/15541): HaikuPorts blender3 crash in
  `HAIKU_GL_MakeCurrent`/`BGLView::UnlockGL` on F12, Shading crash, a 4.2.3 x86-64 build.
- [Raspberry Pi forums: Openshot and Blender](https://forums.raspberrypi.com/viewtopic.php?t=357321): Blender 3.4.1
  on Bookworm needs `MESA_GL_VERSION_OVERRIDE=3.3`, background renders ~2× a laptop, 1 GB crawls.
- [Manjaro forum: can't run Blender on Pi 4](https://forum.manjaro.org/t/cant-run-blender-in-raspberry-pi-4-majaro-kde/14110):
  "works damn slow and the lighting is broken" with the override.
- [Blender forum: Building modern Blender for Raspberry Pi 5](https://forum.blender.org/t/building-modern-blender-for-raspberry-pi-5-i-guess-probably-not/32217):
  builds, but GL 4.3 is out of reach; no Vulkan result.
- [Igalia (Iago Toral) on V3D and OpenGL 3](https://blogs.igalia.com/itoral/2020/01): 4 render targets as the GL 3.0 limiter.
- [Phoronix: V3DV Vulkan 1.3](https://www.phoronix.com/news/Mesa-24.3-V3DV-Vulkan-1.3).

# Blender on the Pi 4 (Haiku arm64): feasibility and plan

Status (2026-11-19): **M1 (SDL2 per-thread GL context) done, §7.2; M2 done: `blender` 3.6.23 links for Haiku
arm64 (cross-built, minimal option set), §7.3; M3 done: Cycles renders the default cube headless on the Pi
(1920×1080 factory scene in 1 min 37 s), §7.4; M4 mostly done: the UI runs through GHOST_SDL on the desktop —
solid viewport, edit mode, save/reload, preferences window, F12 Cycles render into the image editor — after two
GPU patches; injected keyboard and mouse input acts (Tab, middle-drag and numpad orbit, F12), §7.5–7.6; M6
done as test packages (unpublished): blender-3.6.23-1 + 15 library packages with OpenColorIO (Filmic) and
OpenSubdiv, installed with pkgman and started from the Deskbar entry; the factory scene renders as it is, §7.7.
Open: EEVEE (M5, incl. an F12 crash with the EEVEE engine).** Owner (11-18): "If we have OpenGL 3.3 … schedule an
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

### 7.8 Draft user documentation (for USER-GUIDE / KNOWN-ISSUES at the next release; not published yet)

**USER-GUIDE — Blender 3.6 (3D modelling, animation, Cycles rendering)**

> Blender 3.6 LTS runs on the Pi 4 with the desktop OpenGL 3.3 driver. Install it with
> `pkgman install blender` (it brings Python 3.10, OpenImageIO, OpenColorIO, OpenSubdiv, TBB and the SDL2 it
> needs) and start it from Deskbar ▸ Applications ▸ Blender, or `/boot/system/apps/Blender/Blender`.
> - **Works:** the whole UI, the solid (Workbench) viewport, edit mode, modifiers including Subdivision
>   Surface, save/load, the Preferences window, Cycles rendering on the CPU (F12 into the image editor, or
>   headless: `Blender -b scene.blend -E CYCLES -f 1`), Python scripting, Filmic colour management.
> - **Render with Cycles, not EEVEE:** in Properties ▸ Render, set Render Engine to *Cycles* before F12. The
>   default scene uses EEVEE, which needs 6 colour outputs; the Pi 4's GPU has 4 (see Known issues).
> - **Speed:** the default cube renders in about 1½ minutes at 1920×1080 (4 cores); the viewport redraws
>   at about 4–5 frames per second at 1600×900 — use a smaller window for smoother navigation.
> - **Memory:** a simple scene needs about 300–400 MB; large scenes and big textures may not fit in 4 GB.
> - **Input:** click into the Blender window once before typing — keys go to the active window, and to the
>   area under the mouse pointer.

**KNOWN-ISSUES — Blender**

> - **EEVEE does not work** (Material Preview, Rendered view and F12 with the EEVEE engine): its material
>   shaders need 6 colour attachments, the V3D 4.2 GPU has 4; F12 with EEVEE currently crashes. Use Cycles
>   or Workbench. (Fix planned: docs/design/blender.md M5.)
> - **No denoising:** OpenImageDenoise is not ported; renders are noisier at low sample counts (the
>   Denoise checkbox is ignored instead of stopping the render).
> - **No video, audio, Alembic/USD/OpenVDB import, fluid simulation** in this first package (built without
>   FFmpeg, audaspace, Alembic, USD, OpenVDB, Mantaflow).
> - GPU subdivision is off (no compute shaders); subdivision runs on the CPU.
> - Text input is ASCII only (Blender's SDL backend); no tablet pressure, no input methods.

## 8. Files

- New, for step 0:
  - `tools/gl-tests/blender-glprobe.c` (SDL2 + EGL);
  - `tools/gl-tests/blender-vkprobe.c` (Vulkan, headless);
  - `tools/pi-tests/blender-probe.sh`.
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

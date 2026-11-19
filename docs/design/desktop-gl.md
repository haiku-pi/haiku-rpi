# Desktop OpenGL above 2.1 on the Pi 4 (V3D 4.2)

Status (2026-11-18 23:30): **implemented on branches `v5-gl`** (mesa haiku-pi 364a5ec8c79, libglvnd haiku-pi 83d9cc2)
plus an SDL2 patch (`patches/libsdl2/libsdl2-2.32.10-haiku-glview-core.patch`), Pi-tested (§6): **OpenGL 3.3 core
(GLSL 3.30) and compatibility 3.1 (GLSL 1.40)**, was 2.1 and no core profile at all. SuperTuxKart's shader renderer
and Quake II's GL3 renderer run. **Merged** (mesa/libglvnd rpi4, 2026-11-18) and released in image-2026-11-19 with mesa
26.2.7-3, libsdl2 2.32.10-7 and supertuxkart 1.5-3 (its desktop build keeps the legacy renderer by default:
patches/supertuxkart/0002). A further deviation found later (Blender probe, 11-19): **4 colour attachments**
(MAX_DRAW_BUFFERS / MAX_COLOR_ATTACHMENTS 4; GL 3.0 asks for 8) — a shader with more outputs fails to link.
Owner (11-18): "raise desktop OpenGL above 2.1" — KNOWN-ISSUES P1.

Citation keys: **[M]** `sources/mesa` (branch `rpi4` b691443f2cd = 26.2.7 + our work; upstream `origin/main`
18879c94176), **[G]** `sources/libglvnd` (`rpi4` 8391faa), **[S]** SDL 2.32.10 with `patches/libsdl2`,
**[K]** SuperTuxKart 1.5 source, **[Q]** Yamagi Quake II 8.60 source, **[W]** `sources/wine/wine-haiku-11.21`.

## 1. Where "2.1" came from: two separate limits

1. **The window system asked for the wrong thing.** A BGLView (libglvnd's HGL) made every desktop context with
   `eglCreateContext(..., NULL)`: no version, no profile — a *compatibility* context [G] `src/HGL/GLView.cpp`
   `Renderer::Init()`. SDL2's Haiku backend made every context through a BGLView and passed on only the ES
   profile (our 10-20 patch); a core-profile request (SuperTuxKart: 4.3, 3.3, 3.1 core; Quake II GL3: 3.2 core)
   still got the compatibility context. EGL itself was fine: egl_haiku maps a 3.2+ core request or any 3.1
   request to `API_OPENGL_CORE` [M] `src/egl/drivers/haiku/egl_haiku.cpp` `haiku_context_api()`.
2. **The driver's versions.** Mesa computes each API's version from the driver's extensions and limits
   ([M] `src/mesa/main/version.c` `compute_version()`); `glinfo` prints which gate extensions a context lacks.
   Measured on the Pi with the stock Mesa 26.2.7-2 (§6.1):
   - **No context above 2.1 at all, in either profile**: of the 3.0 gate only `GL_ARB_texture_compression_rgtc`
     is missing. V3D cannot sample RGTC, and Mesa offers it anyway by decompressing at upload when the frontend
     sets `allow_compressed_fallback` — a driconf option every DRI frontend defaults to on
     (`driinfo_gallium.h`). Haiku's hgl frontend fills no driconf options, so it stayed off. The often-quoted
     "V3D stops at 3.1" is Linux's figure; on Haiku every 3.x request was refused.
   - With the fallback (`MESA_EXTENSION_OVERRIDE=+GL_ARB_texture_compression_rgtc` on the stock driver):
     **compatibility 3.1** (GLSL 1.40, `glsl_feature_level_compatibility = 140`) and **core 3.1**.
   - The core profile's caps already have GLSL 3.30 (`glsl_feature_level = 330`) and geometry shaders; of the 3.2
     gate only `GL_ARB_depth_clamp` (`depth_clip_disable = devinfo.ver >= 71`) and `GL_ARB_seamless_cube_map`
     (the cap is never set) are missing, and the 3.3 gate is complete (dual-source blending, RGB10_A2UI,
     2_10_10_10 vertices, timer queries — the Haiku v3d driver reports the CPU queue and multisync). With those
     two overridden too: **core 3.3**, GLSL 3.30.
   - Upstream Mesa main has the same caps: the V3D 7.1 (Pi 5) has depth clamping in hardware but still no seamless
     cap, which is why the Pi 5 also stops at 3.1 on Linux.

So three things stood between programs and OpenGL 3.3: a frontend option (RGTC, gates 3.0/3.1), the window system
(BGLView/SDL asked only for compatibility contexts) and two features of the 3.2 gate.

## 2. The two missing pieces of OpenGL 3.2

**Depth clamping** (`GL_ARB_depth_clamp`): turn off clipping against the near and far planes and clamp the
fragment depth to the depth range instead. V3D 4.2 has neither: the Z clip mode and Z clamp bits of `CFG_BITS`
exist only on 7.1 ([M] `src/broadcom/cle/v3d_packet.xml`), and V3DV reports `depthClamp` only for 7.1. Mesa's
state tracker once emulated it for virgl and removed that in 2021 (9b2600da875, "mesa/st: Remove
GL_ARB_depth_clamp emulation"). How V3D 4.2's pipeline works matters for an emulation: the *coordinate* shader
(binning) gives the clipper clip-space X, Y, Z, W; the *render* shader gives screen X/Y, the window Z it computed
itself and 1/W ([M] `src/broadcom/compiler/v3d_nir_lower_io.c`); the clipper derives the window Z of the vertices
it creates from the clip-space Z ("Clipper Z Scale and Offset"). A Z that is only changed for the clipper would
therefore give clipped primitives the wrong depth — the depth has to come from somewhere the clipper does not
touch.

**Seamless cube maps** (`GL_ARB_seamless_cube_map`): filtering across cube faces, on or off by
`GL_TEXTURE_CUBE_MAP_SEAMLESS`. V3D's TMU always filters across faces (OpenGL ES 3 and Vulkan semantics); the
sampler state has no bit to turn it off ([M] `v3d_packet.xml` "Sampler State"). Precedent for exposing the
extension anyway: Mesa's d3d12 driver (`caps->seamless_cube_map = true` on always-seamless Direct3D 12).

## 3. Options

| | What | Honest? | Work |
|---|---|---|---|
| A | `MESA_GL_VERSION_OVERRIDE=3.3` | No: claims depth clamping that does nothing (GL_DEPTH_CLAMP accepted, geometry still clipped) | none |
| B | Emulate depth clamping in the shaders, expose seamless as always-on | Yes, with two documented deviations (§5) | ~250 lines in Mesa |
| C | Core profile through BGLView/SDL, and the RGTC fallback in hgl | Yes (Mesa's own decompression, as on every DRI platform) | small, but only 3.1: SuperTuxKart's shader path qualifies, Quake II GL3 (3.2) does not |

Chosen: **B + C** — the window-system work is needed either way; B is what makes 3.2/3.3 real.

## 4. Implementation (branches `v5-gl`)

| Repo | Commit | What |
|---|---|---|
| mesa (haiku-pi) | 9fbf45c0374 `hgl: allow the compressed-format fallback, as DRI does by default` | the RGTC fallback: 3.0/3.1 for both profiles |
| mesa | 4b9cd0bc85b `v3d: emulate depth clamping on V3D 4.x, expose seamless cube maps`, 3de858c34bf `v3d: polygon offset for emulated depth clamping`, 364a5ec8c79 (no `ffma`: V3D's backend has none) | `v3d_nir_lower_depth_clamp.c` (new): the fragment-shader side; `v3d_nir_lower_io.c`: the last geometry stage's side; `v3d_program.c`: the keys; `v3d_screen.c`: `depth_clip_disable` on every version, `seamless_cube_map` |
| libglvnd (haiku-pi) | 83d9cc2 `HGL: BGL_CONTEXT_CORE — a core-profile OpenGL context in a BGLView` | `GLView.h` flag 4096; `Renderer::Init()` asks for 3.2 core, else 3.1 |
| haiku-rpi | this repository | `patches/libsdl2/libsdl2-2.32.10-haiku-glview-core.patch`; `tools/gl-tests/glinfo.c`, `glcore.c`, `glview-core.cpp`; `tools/pi-tests/desktop-gl.sh` |

**Depth clamping, V3D 4.x.** Keyed on the rasterizer state (`!depth_clip_near || !depth_clip_far`), so no shader
changes while clamping is off:
- *Fragment shader* (`v3d_fs_key.depth_clamp`): a hidden input at `V3D_DEPTH_CLAMP_SLOT` (`VARYING_SLOT_VAR30`:
  programs use at most 16 generic varyings, VAR0–VAR15) carries the clip-space Z, perspective-interpolated.
  Window depth = Z / W (the fragment's interpolated W, the FEP's W payload) × viewport Z scale + offset — what
  the hardware computes, and correct where the clipper cut the primitive, because only the clipper's own Z is
  changed. The shader writes it clamped to offset ± |scale| (the depth range); a shader's own `gl_FragDepth` is
  clamped the same way; `gl_FragCoord.z` reads the unclamped depth.
- *Last geometry stage* (`v3d_vs_key`/`v3d_gs_key.depth_clamp`, set when the bound fragment shader reads that
  slot): stores its clip-space Z into the slot and gives the fixed-function outputs Z = 0, which lies between
  the near and far planes of every vertex in front of the eye — nothing is clipped against them; the w > 0
  clipping stays. Applies to the coordinate (binning) and render variants of a VS or GS.
- Left alone (clipped, not clamped — the old behaviour): a fragment shader with no free input slot (all 64
  components used) or with `layout(early_fragment_tests)`; its geometry stage then sees no reader of the slot.
- Polygon offset (second commit): the hardware applies it to its own Z, which the shader now overrides, so the
  shader adds it (`v3d_fs_key.depth_offset` when `offset_tri` is on, as `v3dx_emit.c` enables the hardware's;
  units scaled to the depth buffer's resolution on the CPU, per fragment from the depth's exponent for a float
  buffer; new intrinsic `load_depth_offset_v3d` → `QUNIFORM_DEPTH_OFFSET_*`).
- Cost while clamping is on: the fragment shader writes Z, so early Z tests are off; one varying more.

**Seamless cube maps**: `caps->seamless_cube_map = true`; the sampler bit is ignored (there is none).

**BGLView**: `BGL_CONTEXT_CORE` — EGL 3.2 core-profile request, else 3.1; Mesa returns the newest core version
it has for either. `BGL_CONTEXT_ES` wins over it. The header comes with mesa_devel (libglvnd's GLView.h).

**SDL2**: `SDL_GL_CONTEXT_PROFILE_CORE` → `BGL_CONTEXT_CORE`; after creating the view SDL compares the context's
`GL_VERSION` with the requested major.minor and, if older, destroys it and returns NULL ("OpenGL X.Y core profile
not available"), as SDL does on other platforms — programs that walk down a list of versions
(SuperTuxKart) then get the next one. Compatibility and ES requests are unchanged.

## 5. Deviations from the specifications (documented, not hidden)

1. `glDisable(GL_TEXTURE_CUBE_MAP_SEAMLESS)` has no effect: cube maps are always filtered seamlessly (better
   edges than the non-seamless filtering the core profile defaults to; programs that care enable it).
2. While depth clamping is on, the polygon offset is computed in the fragment shader (factor × the larger of
   the depth's screen-space derivatives + units × the depth buffer's resolution, then the clamp) instead of by
   the hardware: the slope comes from the quad's finite differences, exact for the planar depth of a triangle.
3. While depth clamping is on, fragments with forced early fragment tests, or shaders with all 64 varying
   components in use, are clipped instead of clamped.
4. Per-pixel, not per-sample, depth while clamping with MSAA (as any shader that writes `gl_FragDepth`).

## 6. Results (Pi sessions v5gl1 19:35 and v5gl2 23:12, games-bench image of image-2026-11-18 + test files)

Serial logs `artifacts/uart/*-session-v5gl1.log`, `*-session-v5gl2.log` (0 PANIC); screenshots `artifacts/desktop-gl/`
(not in git). Branch Mesa installed with pkgman over the image's 26.2.7-2 as `mesa{,_devel}-26.2.7-91` (test
revision, version string `git-364a5ec8c7`).

### 6.1 Versions (`glinfo`; EGL contexts of each kind)

| | stock 26.2.7-2 | stock + override RGTC | stock + override RGTC, depth clamp, seamless | **branch** |
|---|---|---|---|---|
| no attributes (what a BGLView got) | 2.1, GLSL 1.20 | 3.1, GLSL 1.40 | 3.1 | **3.1 (compatibility), GLSL 1.40** |
| core 3.1 / 3.2 / 3.3 request | refused | 3.1 / refused / refused | 3.3 / 3.3 / 3.3 | **3.3 (Core Profile), GLSL 3.30** |
| core 4.0 | refused | refused | refused | refused |
| OpenGL ES | 3.1 | 3.1 | 3.1 | 3.1 (unchanged) |

Gates on the branch: every extension of 3.0–3.3 advertised; what stops 4.0 is everything of the 4.0 list V3D 4.2
lacks (tessellation, fp64, gpu_shader5...). The core 3.1 context lists `GL_ARB_color_buffer_float`,
`GL_NV_primitive_restart`, `GL_NV_texture_rectangle` as absent: core contexts do not advertise those (their
features are core), as the glinfo header says.

### 6.2 Rendering (`glcore`, core 3.3 context; `glview-core`, BGLView)

`glcore` **PASS** (every check) on the branch:
- depth clamping: beyond far/near (depth exactly 1 / 0), depth range 0.25–0.75 (0.75 / 0.25), `gl_FragDepth = 2.0`
  (0.75 with clamping, 1.0 without), a geometry shader as last stage, same depths as unclamped inside the planes
  (1352 pixels, largest difference 6e-8 = one D24 step), `gl_FragCoord.z` (6e-8), a triangle crossing the near plane
  (1352 pixels clamped vs 902 clipped, corner depth 0), a vertex behind the eye (only what is in front, depths
  in 0..1), transform feedback keeps the program's z, 4× MSAA coverage equal to the unclamped reference;
- polygon offset while clamping vs the hardware's without: units 6e-8, factor/both ≤ 8.8e-6 (the slope terms are
  ~1e-2: the shader's quad derivatives and the hardware's slope agree to <0.1 %);
- 3.2/3.3 features: geometry shader, base vertex, provoking vertex, BGRA and 2_10_10_10 vertices, dual-source
  blending, fences, timer queries, RGB10_A2UI render target, multisample texture fetch, seamless enable;
- `note cube-edge seamless off/on: 128/0/128` both — the documented deviation (always seamless).

Bugs the Pi found in the first run, fixed: the pass emitted `ffma` (V3D has none: compile abort), and glcore's
own transform-feedback section changed programs while capturing.

`glview-core` (BGLView + BGL_CONTEXT_CORE): **3.3 (Core Profile), profile mask core, GLSL 3.30**, shader triangle
checked by readback, PASS. Regression checks PASS: glview (compatibility, now 3.1), glview-es (ES 3.1), gltri
(its desktop context now 3.1), vktest.

## 7. Programs

| Program | before (stock) | branch | |
|---|---|---|---|
| **SuperTuxKart 1.5** desktop build, with the SDL2 patch | 2.1 → legacy fixed-function renderer | **3.3 core, GLSL 3.3, "GLSL supported": shader renderer** (deferred lighting, motion blur); hacienda race 60 s completed, 13–19 frames/s at 1280×720 (egl_haiku) — the GLES build's shader renderer ran at 16–18 (10-20), the legacy renderer at 28–38 unlit: a gain in features (lighting, shadows), not speed | gained |
| SuperTuxKart, the image's SDL2 (no patch) | 2.1, legacy renderer | compatibility 3.1 → its shader path → **crash**: STK calls `glVertexAttribDivisor` (the 3.3 core name), which its glad loads only for GL ≥ 3.3 — on 3.1 it loads only `glVertexAttribDivisorARB`, so the pointer is NULL (STK's own bug on any 3.1 context, not something compatibility 3.1 breaks in general) | **regression unless SDL2 ships with it** |
| **Quake II GL3** (`ref_gl3.so`, 3.2 core forward-compatible) | could not start (no 3.2) — the image defaults to gl1 | **runs: "got version 3.3", textured and lit on HDMI, 67–72 frames/s** at 1280×720 (attract demo) | gained |
| Quake II GL1 | 2.1 | compatibility 3.1, renders | unchanged |
| Wine d3dtest-x86 (wined3d: 4.4 core, else 3.2 core, else legacy) | legacy context (4.4 and 3.2 refused): 133.7 fps, image right | **3.2-core path (3.3 context)**: 135.0 fps, image right | path changed, same rate |
| Wine gltest-x86 (WGL, legacy) | 2.1: 167.3 fps | compatibility 3.1: 161.7 fps | within the per-boot spread (163–194 seen) |
| Firefox WebGL | WebGL 1 and 2 through an ES 3.1 context (patch 0003) | unchanged: a BGLView's compatibility GLSL is 1.40 < 1.50, so 0003 still takes ES | no gain needed |

Not run / not covered:
- Warcraft III and the client-pointer A/B on the new wined3d core path (W3 is Direct3D 8/9: wined3d enables
  GL_DEPTH_CLAMP only for D3D10/11 rasterizer states with DepthClipEnable = FALSE, so the emulation itself does not
  reach it — the core path does); photocraft-gpu-it, mega-smoke; OpenTTD (wants 3.2).
- Depth clamping with D16 and D32F depth buffers (the offset's units scaling and its float path ran only on
  D24S8), and with points and lines.
- `GL_EXT_depth_clamp` is now exposed in OpenGL ES contexts too (Firefox WebGL may use it).
- No libsdl2 package was built, only the library (tested from /boot/home through LIBRARY_PATH).
- 1986798cb22 (`st_pbo.c`: depth clipping on in the PBO rasterizer state — it was zeroed, so every PBO upload and
  readback draw would have run the emulation for nothing) is built, not Pi-run.

### 7.1 Why the packaged SuperTuxKart got 3.1 with `force_legacy_device="false"` (2026-11-19)

Seen on the mega image after the release (mesa 26.2.7-3, libsdl2 2.32.10-7): "OpenGL version: 3.1, GLSL 1.4,
GLSL supported", then the `glVertexAttribDivisor` crash. **Not an SDL2 bug — a stale copy of SDL2 shadowed the
package.** `scripts/build-games.sh` staged its own `lib/libSDL2-2.0.so.0` into `artifacts/games/non-packaged`
(once meant for images whose libsdl2 had no Vulkan), and `build-mega-image.sh` / `games-bench-image.sh` /
`gpu-queues-image.sh` copied it to `/boot/system/non-packaged/lib`, which comes before `/boot/system/lib` in the
library search path. That copy was built 11-04 (the -6 patches, no glview-core patch), so every SDL program on
those images ran without `BGL_CONTEXT_CORE`: each core request got the compatibility 3.1 context, Irrlicht's 4.3
and 3.3 attempts failed its version check and the 3.1 one passed. V5's 3.3 run loaded its SDL2 through
LIBRARY_PATH, ahead of the copy. The release image has no such copy (checked in the image file).

Session sdlm1 (`tools/pi-tests/sdl-gl-check.sh`, `tools/gl-tests/sdl-coreseq.c`: Irrlicht's sequence — SDL
started, stopped, started; core 4.3, 3.3, 3.1 in new windows; profile 0 2.1):
- the mega image's own SDL2 (the copy): 4.3, 3.3 and 3.1 each "3.1 Mesa", profile mask 0 → FAIL; STK crashes;
- the package's -7 (LIBRARY_PATH): 4.3 refused ("OpenGL 4.3 core profile not available"), **3.3 core taken**;
  STK **"3.3 (Core Profile)", GLSL supported, shader renderer, the 60 s race completes, 16.1 frames/s**
  (egl_haiku); -8 the same, 16.8.

Fixed in the scripts: build-games.sh no longer stages libSDL2; the three image scripts drop any old copy (and
gpu-queues-image.sh warns when its base has no libsdl2 package); the stale file is deleted from
`artifacts/games/non-packaged`. The current `artifacts/images/haiku-pi4-mega.img` still has it until it is
rebuilt (or `rm /boot/system/non-packaged/lib/libSDL2-2.0.so.0` on a running one).

## 8. Recommendation

Merge all three together, after a mega image of them passes mega-smoke and a Wine W3 run:
- mesa `v5-gl` (5 commits on rpi4: depth clamp emulation + seamless, polygon offset, hgl compressed fallback, no
  ffma, st_pbo) and libglvnd `v5-gl` (BGL_CONTEXT_CORE) — one mesa package. Squash 364a5ec8c79 into 4b9cd0bc85b
  when integrating: 4b9cd0bc85b's message is stale ("from 3.1", "polygon offset is not applied");
- **libsdl2 with `libsdl2-2.32.10-haiku-glview-core.patch` in the same image** (revision bump): without it the RGTC
  fix alone hands SDL programs that walk core versions (SuperTuxKart) a compatibility 3.1 context, and STK
  crashes in its shader path instead of using its legacy renderer;
- `build-stk.sh`/the STK package description ("OpenGL 2.1 (the legacy renderer)") and `patches/yquake2`
  (default gl1 "because Haiku's OpenGL is 2.1") can then change: gl3 works.
- Blast radius to watch: every desktop context moves 2.1 → 3.1 (compatibility) and core requests now succeed;
  wined3d switches to its core-profile path (d3dtest fine; W3/WoW64 GL games untested on it); S3TC/RGTC/LATC
  textures are now decompressed by Mesa where they used to be refused.

## 9. KNOWN-ISSUES P1 text (proposal)

> **Desktop OpenGL is 3.3 core / 3.1 compatibility.** OpenGL ES is 3.1. The V3D 4.2 has no tessellation or
> double precision, so OpenGL 4 is out of reach. Two deviations from the specification: cube maps are always
> filtered seamlessly (disabling GL_TEXTURE_CUBE_MAP_SEAMLESS has no effect), and depth clamping is done in the
> shaders (correct depths, but early depth tests are off while GL_DEPTH_CLAMP is on). A BGLView gives a
> compatibility context unless the program asks for `BGL_CONTEXT_CORE` (SDL: the core profile).

(P1 can then move to "fixed" with the release that ships it.)

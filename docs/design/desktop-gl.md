# Desktop OpenGL above 2.1 on the Pi 4 (V3D 4.2)

Status (2026-11-18): **implemented on branches `v5-gl`** (mesa haiku-pi, libglvnd haiku-pi) plus an SDL2 patch
(`patches/libsdl2/libsdl2-2.32.10-haiku-glview-core.patch`); results in §6. Not merged; recommendation in §8.
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
   ([M] `src/mesa/main/version.c` `compute_version()`). For v3d on V3D 4.2 ([M]
   `src/gallium/drivers/v3d/v3d_screen.c` `v3d_init_screen_caps()`):
   - compatibility profile: `glsl_feature_level_compatibility = 140`, yet the compatibility context reports
     **2.1** (§6.1 shows which 3.0 gate fails);
   - core profile: `glsl_feature_level = 330` (GLSL 3.30 is there), **3.1**: of the 3.2 gate only
     `GL_ARB_depth_clamp` (`depth_clip_disable = devinfo.ver >= 71`) and `GL_ARB_seamless_cube_map` (the
     `seamless_cube_map` cap is never set) are missing; the 3.3 gate is complete (dual-source blending,
     RGB10_A2UI, 2_10_10_10 vertices, timer queries: the Haiku v3d driver reports the CPU queue and multisync,
     which `query_timestamp` needs). Geometry shaders were already supported (OpenGL ES 3.2 level).
   - Upstream Mesa main is the same: the V3D 7.1 (Pi 5) has depth clamping in hardware but still no seamless
     cap, which is why the Pi 5 also stops at 3.1.

So the BGLView path was stuck at 2.1 even though the driver had a 3.1 core profile, and the driver's core profile
stopped one gate short of 3.3.

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
| C | Core profile through BGLView/SDL only | Yes | small, but only 3.1: SuperTuxKart's shader path qualifies, Quake II GL3 (3.2) does not |

Chosen: **B + C** — the window-system work is needed either way; B is what makes 3.2/3.3 real.

## 4. Implementation (branches `v5-gl`)

| Repo | Commit | What |
|---|---|---|
| mesa (haiku-pi) | 4b9cd0bc85b `v3d: emulate depth clamping on V3D 4.x, expose seamless cube maps` | `v3d_nir_lower_depth_clamp.c` (new): the fragment-shader side; `v3d_nir_lower_io.c`: the last geometry stage's side; `v3d_program.c`: the keys; `v3d_screen.c`: `depth_clip_disable` on every version, `seamless_cube_map` |
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

## 6. Results

(filled in from the Pi sessions below)

## 7. Programs

## 8. Recommendation

## 9. KNOWN-ISSUES P1 text

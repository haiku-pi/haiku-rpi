# H15 survey: Wine + x86 translation on Haiku arm64 (Raspberry Pi 4)

**Date:** 2026-10-21. **Scope:** the survey step of [wine-x86.md](wine-x86.md): verify the plan's *(check)* items
against current releases. Every fact below has its source. Where a source could not be reached or a fact could not
be confirmed, the text says so.

**How the facts were gathered.** WineHQ's own sites (`winehq.org`, `gitlab.winehq.org`, `appdb.winehq.org`,
`dl.winehq.org`) could not be reached from the survey host: its DNS resolver returned a block page for them. So:

- Wine release notes and source come from the official GitHub mirror (`github.com/wine-mirror/wine`), at the release tags.
- WineHQ AppDB ratings come from Internet Archive snapshots of the AppDB pages. Each snapshot URL carries its date.
  The live AppDB now sits behind an anti-scraper wall (Anubis), so the snapshots are 2024–2025 data. Recheck them in a
  browser before relying on a rating.
- Mesa facts come from a Mesa 26.2.0 tree (26.2.0 plus 22 commits, 2026-09-25). The links point to the `mesa-26.2.0` tag.

---

## 1. Wine on Haiku today (HaikuPorts)

### The HaikuPorts recipe

Recipe directory: <https://github.com/haikuports/haikuports/tree/master/app-emulation/wine>

| Recipe | Status | ARCHITECTURES | Build |
|---|---|---|---|
| `wine-11.8.recipe` | **current**, added by PR [#14036](https://github.com/haikuports/haikuports/pull/14036) (merged 2026-05-08, commit [93b2312](https://github.com/haikuports/haikuports/commit/93b2312d83)) | `all !x86_gcc2` (the secondary x86 architecture is commented out as "Untested") | `--enable-archs=i386,x86_64 --disable-tests --with-wayland --without-x`. The PE side is built with HaikuPorts' `llvm21` clang and lld |
| `wine-7.1.recipe` | old (X512's 2022 port), kept for its native driver | `!all !x86_gcc2` (disabled) | the `winehaiku.drv` native driver |

- **The only build actually shipped is x86_64.** HaikuDepot lists `wine` **11.8-1 for x86_64 only**, dated 2026-07-23:
  <https://depot.haiku-os.org/__multipage/pkg/wine>.
- **Only 64-bit programs run.** The recipe's DESCRIPTION says "Wine on Haiku can only run Win64 executables as of this
  version". The PR author lists the open problems: "Can only run 64bit .exes", the Wine Gecko and Wine Mono installers
  hang, and there is no sound with OSS ([#14036](https://github.com/haikuports/haikuports/pull/14036)).
- **Work in progress:** PR [#14440](https://github.com/haikuports/haikuports/pull/14440) "Update Wine to 11.14" is
  still open. Its last comments (2026-07-26/27) report the same problems as 11.8. A kqueue attempt for wineserver
  failed, because Haiku lacks `EVFILT_USER`. waddlesplash suggests deleting the SIGSEGV-handler debug block.
- PR [#14444](https://github.com/haikuports/haikuports/pull/14444) was rejected because it was AI-generated. It still
  names three real bugs:
  - Winelib C++ static initializers do not run.
  - The SIGSEGV handler blocks.
  - `get_self_exe()` fails because Haiku has no `/proc`. The maintainer says the canonical fix uses
    `get_next_image_info` / `B_APP_IMAGE`.
- Haiku MediaKit audio is only wished for: issue [#14124](https://github.com/haikuports/haikuports/issues/14124), closed.

### The 11.8 patchset (`wine-11.8.patchset`)

The patchset is 5 patches, 2,018 lines, about +1,308/−13 lines in all. **980 of the added lines are one copied Linux
header** (`winewayland.drv/input-event-codes.h`). The real Haiku code is about 330 lines across 27 files.

| Area | Files (lines added) | What |
|---|---|---|
| ntdll, Unix side | `signal_x86_64.c` (+124), `virtual.c` (+51), `system.c` (+16), `thread.c` (+15), `socket.c` (+15), `loader.c` (+8), `file.c` (+7), `server.c`, `serial.c` | `signal_x86_64.c`: Haiku `mcontext` register macros (`RAX_sig` … `RIP_sig`, `FPU_sig`); FS/GS/SS returned as NULL. The TEB is set through `_kern_generic_syscall("thread", THREAD_SET_GS_BASE, …)`. The patch also leaves **debug code in `segv_handler`** that `printf`s and then **blocks on `fgetc(stdin)`**. `loader.c`: an `mprotect` of the builtin PE header |
| wineserver | `server/sock.c` (+18), `signal.c`, `fd.c`, `change.c` | build and portability fixes |
| graphics driver | `winewayland.drv/*` (+8, plus the header) | **Haiku's Wine uses Wine's own Wayland driver** on X512's in-process Wayland server `wayland_server` (<https://github.com/X547/wayland-server>; the HaikuPorts recipe `dev-libs/wayland-server`, version `0.1.20251004`), which "implements the Wayland protocols over the Haiku API" |
| other | `crypt32`, `ws2_32`, `nsiproxy.sys`, `winex11.drv` (build only), `winedbg`, `winegcc`, `configure.ac`, `wineoss.drv` (OpenSound) | small fixes |

- The patches are by X512, Peppersawce and Ken Mays (April–May 2026). They grew out of Sergei's Wine 10.6 recipe on
  the Haiku forum: <https://discuss.haiku-os.org/t/running-wine-10-configure-does-not-pass-lib-checks/16655/130>.
- X512's newest public Wine tree is `work-wl-9.17`: <https://github.com/X547/wine/tree/work-wl-9.17> (cited in #14036).
- A separate `wine-11.8-home.patchset` ("Move wine dir to /config/settings (buggy)", 118 lines) is **not** in `PATCHES`.

### The old native driver (7.1)

`wine-7.1.patchset` is 13 patches and 6,145 lines. Most of it is **`winehaiku.drv`**, X512's native Haiku user driver:
windows, GDI, clipboard, keyboard and mouse, display settings, systray, and a standalone Vulkan WSI. It also carries
ntdll and wineserver changes. The PR author kept it "as that includes winehaiku.drv (native backend) work". Its
history:

- 2022 forum thread: <https://discuss.haiku-os.org/t/my-progress-in-porting-wine/11741>
- Phoronix, 2022: <https://www.phoronix.com/news/Wine-On-Haiku-Starts-2022>

### arm64 Haiku and Wine

No attempt to run Wine on arm64 Haiku was found: no forum thread, HaikuPorts issue or patch. Haiku's arm64 port
itself only boots to the desktop under QEMU (March 2026):

- <https://discuss.haiku-os.org/t/my-haiku-arm64-progress/19044>
- <https://www.osnews.com/story/144799/haiku-on-arm64-boots-to-desktop-in-qemu/>

All the existing Haiku-specific Wine code is x86_64-only. Wine's `dlls/ntdll/unix/signal_arm64.c` has only `linux`
and `__APPLE__` branches (wine-11.0, for example line 71), so **Haiku needs a third branch**. Two other facts bear on
this:

- Wine's arm64 code keeps the TEB in **x18** (`mov x18, x4 /* teb */` in the syscall dispatcher).
- Haiku's arm64 `PAGESIZE` is 4096 (`headers/posix/arch/arm64/limits.h` in the Haiku tree), and Wine's ARM64 support
  requires 4K pages (section 2).

---

## 2. Wine: the newest stable release and its ARM64EC/WoW64 state

### Releases

- **The newest stable release is Wine 11.0, tagged 2026-01-13.**
  - Tag: <https://github.com/wine-mirror/wine/releases/tag/wine-11.0>
  - Official release page (unreachable from here): <https://gitlab.winehq.org/wine/wine/-/releases/wine-11.0>
  - Repology lists 11.0 as "newest", and its version list has no 11.0.x entry:
    <https://repology.org/project/wine/versions>. WineHQ's own download pages could not be checked.
  - The next stable, 12.0, is due in January 2027. Phoronix calls the 11.x releases development releases "toward
    the Wine 12.0 stable release next January": <https://phoronix.com/news/wine-11.2-released>
- **The newest development release is 11.20, tagged 2026-10-16.** Its notes:
  <https://github.com/wine-mirror/wine/blob/wine-11.20/ANNOUNCE.md>

### Wine 11.0 release notes

Source: <https://github.com/wine-mirror/wine/blob/wine-11.0/ANNOUNCE.md>

- **New WoW64:** "first introduced as experimental feature in Wine 9.0 is considered fully supported, and
  essentially has feature parity with the old WoW64 mode."
  - 16-bit applications are supported.
  - `WINEARCH=win32` prefixes are deprecated.
  - The separate `wine64` loader is removed.
- **ARM64 page size:** "On ARM64, there is support for simulating a 4K page size on top of larger host pages …
  Using a 4K-page kernel is strongly recommended."
- **OpenGL:** "In new WoW64 mode, OpenGL buffers are mapped to 32-bit memory space using Vulkan extensions if
  available." The EGL backend is extended, and OSMesa is removed.
- **WineD3D's Vulkan renderer** "is not yet at parity with the GL renderer, and is therefore not yet the default."
- The 11.0 notes have no separate ARM64EC section. ARM64EC was declared complete in 10.0 (below).

### Earlier ARM64 milestones

**Wine 10.0** (2025-01-21), <https://github.com/wine-mirror/wine/blob/wine-10.0/ANNOUNCE.md>:

- "The ARM64EC architecture is fully supported, with feature parity with the ARM64 support."
- "Hybrid ARM64X modules are fully supported … `--enable-archs=arm64ec,aarch64` … This still requires an experimental
  LLVM toolchain, but it is expected that the upcoming LLVM 20 release will be able to build ARM64X Wine out of the box."
- "The 64-bit x86 emulation interface is implemented … No emulation library is provided with Wine … specifying its
  name in the `HKLM\Software\Microsoft\Wow64\amd64` registry key. The FEX emulator implements this interface when
  built as ARM64EC."
- "ARM64 support requires the system page size to be 4K." (11.0 relaxed this; see above.)

**Wine 9.0**, <https://github.com/wine-mirror/wine/blob/wine-9.0/ANNOUNCE.md>:

- "The 32-bit x86 emulation interface is implemented … `HKLM\Software\Microsoft\Wow64\x86`. The FEX emulator
  implements this interface when built as PE."

### ARM64 items in the 11.x development releases

These items are **not in 11.0 stable**. Sources: `ANNOUNCE.md` at each tag on the GitHub mirror.

| Release | Item |
|---|---|
| 11.9 | "Thread suspension in emulated code on ARM64" |
| 11.13 | "FFmpeg optimizations on ARM64EC" |
| 11.15 | "Support for ARM64EC build in Mingw mode" |
| 11.16 | "Improved exception handling on ARM64EC" |
| 11.20 | "Relay debugging for ARM64EC" |
| 11.14 | "New WoW64 mode supported on FreeBSD" (a precedent for a non-Linux Unix) |

### Toolchain

- Wine's `configure.ac` (wine-11.0) looks for the compilers `arm64ec-w64-mingw32-clang`, `aarch64-w64-mingw32-clang`
  and `i686-…-clang`, or plain `clang` (lines 416–431). It also accepts `--with-mingw=llvm-mingw`.
- Hangover builds Wine with `--with-mingw=clang --enable-archs=arm64ec,aarch64,i386`:
  <https://github.com/AndreRH/hangover/blob/hangover-11.16/docs/COMPILE.md>
- **A minimum llvm-mingw version is not documented.** The only statement is 10.0's expectation that LLVM 20 would
  suffice.
- Proven toolchain: Hangover 11.16 builds Wine with **mstorsjo llvm-mingw 20260826 (LLVM 23.1.0)**:
  <https://github.com/AndreRH/hangover/blob/hangover-11.16/.packaging/ubuntu2404/Dockerfile>
- Newest llvm-mingw: **20261020 (LLVM 23.1.4)**, released 2026-10-21: <https://github.com/mstorsjo/llvm-mingw/releases>
- Wine 11.15's "ARM64EC build in Mingw mode" suggests that Wine ≤11.14 builds ARM64EC modules in clang's MSVC-target
  mode. llvm-mingw's clang serves both modes, and Hangover 11.0 was built with it. *Not verified in detail.*

---

## 3. FEX-Emu

**Newest tagged release:** **FEX-2610**, 2026-10-07. A point release, FEX-2609.1, also exists.

- Release: <https://github.com/FEX-Emu/FEX/releases/tag/FEX-2610>
- Blog post: <https://fex-emu.com/FEX-2610/>
- The GitHub release has **no binary assets**; it is a source tag.

### Wine DLLs

The source has two Windows targets in `Source/Windows/`: `arm64ecfex` → **`libarm64ecfex.dll`** (ARM64EC, x86-64)
and `wow64fex` → **`libwow64fex.dll`** (WoW64, i386):
<https://github.com/FEX-Emu/FEX/tree/FEX-2610/Source/Windows>.

How the DLLs arrived:

- WoW64 front end: FEX-2310, October 2023, "initial WOW64 Wine front-end … only wired up to work through a 32-bit
  x86 part of the layer": <https://www.phoronix.com/news/FEX-Emu-2310-Released>
- The ARM64EC module is documented by Wine 10.0 (January 2025, above).
- Prebuilt DLLs: since **FEX-2501**, the Ubuntu PPA has a `fex-emu-wine` package that "provides wow64 and arm64ec
  emulator DLL files that can be applied directly to an AArch64 build of WINE":
  <https://fex-emu.com/FEX-2501/>

How to build them:

- FEX's wiki builds both DLLs with **bylaws/llvm-mingw** and recommends bylaws' Wine fork, because "upstream wine has
  various things missing for full FEX/ARM64EC support": <https://wiki.fex-emu.com/index.php/Development:ARM64EC>.
  The page is undated and may be stale. Hangover uses upstream Wine plus about 10 patches (section 5).
- Hangover builds `libarm64ecfex.dll` with `bylaws-llvm-mingw-20240929`:
  <https://github.com/AndreRH/hangover/blob/hangover-11.16/.packaging/ubuntu2204/fexpeec/Dockerfile>

### CPU requirements: Cortex-A72 qualifies

- README: "FEX requires ARMv8.0-a or newer hardware, with minimum extensions FEAT_FP and FEAT_CRC32."
  - README at the tag: <https://github.com/FEX-Emu/FEX/blob/FEX-2610/Readme.md>
  - The wording comes from commit 2005933518, 2026-09-21, "Readme: Update with minspec update":
    <https://github.com/FEX-Emu/FEX/commit/2005933518d51c15c7ff115522cf3d577a9f1a91>
- **LSE atomics, LRCPC/LRCPC2 (the TSO helpers) and LSE2 are optional.** FEX detects them at runtime
  (`ENABLE_DISABLE_OPTION(SupportsAtomics, …)`, `SupportsRCPC`, `SupportsTSOImm9`):
  <https://github.com/FEX-Emu/FEX/blob/FEX-2610/Source/Common/HostFeatures.cpp>
- FEX has had ARMv8.0 code paths for a long time, for example PR [#1244](https://github.com/FEX-Emu/FEX/pull/1244)
  "Properly implement single CAS on ARMv8.0" and [#1257](https://github.com/FEX-Emu/FEX/pull/1257) "Fix unaligned
  CASPair on ARMv8.0".
- The Pi 4's A72 reports `fp asimd evtstrm crc32 cpuid`:
  <https://openbenchmarking.org/system/2501213-NE-RAPSBERRY24/ARMv8%20Cortex-A72%20-%20%20-%20Raspberry%20Pi%204%20Model%20B%20Rev%201.4/lscpu>
  So it **meets the minimum**.
- **Expected cost:** without LSE or LRCPC, atomics fall back to LL/SC loops, and x86 memory-order (TSO) emulation
  falls back to full barriers. Expect it to be slow. FEX's per-application option to turn TSO emulation off will matter.
- No public report of FEX's ARM64EC DLL on a Cortex-A72 was found.

---

## 4. Box64 / Box32

**Newest tagged release:** **v0.4.4**, 2026-08-02. Earlier: v0.4.2 (2026-04-20), v0.4.0 (2026-01-03).
<https://github.com/ptitSeb/box64/releases>

- **WoW64 DLL: yes, `wowbox64.dll`, since v0.3.6** (2025-06-06): "This version introduces wowbox64.dll for Hangover
  … WowBox64 can be built directly from Box64 repo" (`-DWOW64=ON`).
  - Release: <https://github.com/ptitSeb/box64/releases/tag/v0.3.6>
  - Build notes: <https://github.com/ptitSeb/box64/blob/v0.4.4/docs/COMPILE.md>
  - The build docs still call it "highly experimental".
  - v0.3.8 finished the "host extension detection" for WowBox64:
    <https://github.com/ptitSeb/box64/releases/tag/v0.3.8>
- **ARM64EC: no.** "Box64 now supports 32-bit WOW64 DLL … And we plan to support Arm64EC in the future." For arm64
  Wine the doc recommends Hangover. <https://github.com/ptitSeb/box64/blob/v0.4.4/docs/WINE.md>
- **Cortex-A72: supported.** There is a dedicated `RPI4ARM64` build target (`-march=armv8-a+crc -mtune=cortex-a72`)
  in `CMakeLists.txt` and a "for Raspberry Pi 4" section in COMPILE.md:
  - <https://github.com/ptitSeb/box64/blob/v0.4.4/CMakeLists.txt>
  - <https://github.com/ptitSeb/box64/blob/v0.4.4/docs/COMPILE.md>
- **Box32** is Box64's Linux-side mode for 32-bit Linux binaries. It is irrelevant here, because Haiku has no Linux
  syscalls. Only `wowbox64.dll` matters.
- Box64's Wine doc warns that with a WoW64 Wine, "the performance of WineD3D is pretty bad for 32-bit". The reason
  is architectural: in WoW64, Wine's own i386 PE DLLs (`d3d9`, `wined3d`, `user32`, …) are x86 code, so they run
  inside the emulator. Only the 64-bit side, behind the syscall and unix-call boundary, is native
  ([Hangover README](https://github.com/AndreRH/hangover/blob/hangover-11.16/README.md), "How it works"). Under
  ARM64EC, Wine's DLLs are native ARM64EC code, and "only the application's x86-64 code requir[es] emulation" (Wine
  10.0 notes).

---

## 5. Hangover

**Newest release:** **hangover-11.16**, 2026-08-30. Its notes:

- "Updated FEX to 2608"
- "Updated Box64 to v0.4.4"
- "llvm-mingw toolchain with fixed exit thunks for vararg functions"
- wine-mono support

Assets: `.deb` tarballs for Debian 12/13 and Ubuntu 22.04/24.04/25.10/26.04 arm64, plus `hangover_11.16_dlls.tar`.
<https://github.com/AndreRH/hangover/releases/tag/hangover-11.16>

### Which Wine it pairs with

Hangover pairs with **upstream Wine of the same version number plus a small patch stack**, through the submodule
`AndreRH/wine`.

**hangover-11.16 = Wine 11.16 + 9 commits**
(<https://github.com/AndreRH/wine/commits/3ea3a14941b6a122b892c84141ce9662c008081e>):

- 5 by Billy Laws:
  - "ntdll: Force all wow64 host allocations outside of the 32-bit AS"
  - "ntdll: Implement WOW64 thread suspension helpers"
  - "wow64: Support running a BT module provided suspend routine"
  - "ntdll: Support cross-process wow64 suspend on ARM64"
  - "server: Ensure allocated space for mappings is in accessible memory"
- 4 conveniences:
  - default `libarm64ecfex.dll` for amd64 (`HODLL64`)
  - default `wowbox64.dll` for i386 (`HODLL`)
  - a warning on page sizes other than 4K
  - a version string suffix

**hangover-11.0 (2026-01-13) is built entirely on stable tags:**

- **Wine 11.0 + 10 commits.** The same set as above, plus "WIP: ntdll: ARM64EC suspend support".
  <https://github.com/AndreRH/wine/commits/f6816331a2cf8c111967240750ce98077c3eaca2>
- **FEX-2601 + 2 small Hangover commits**:
  <https://github.com/AndreRH/FEX/commits/7f06647ffa68a9ae7f006421195eae2ac136a5df>
- **Box64 v0.4.0** exactly: <https://github.com/AndreRH/box64/commit/dae0917c47b4edd8956f314210417a20fd225c4b>
- The release note says "we are down to 10 patches on top of Wine":
  <https://github.com/AndreRH/hangover/releases/tag/hangover-11.0>

### Translators it packages

From the README (<https://github.com/AndreRH/hangover/blob/hangover-11.16/README.md>):

- **x86-64:** `libarm64ecfex.dll` (FEX), the default.
- **i386:** `wowbox64.dll` (Box64), the default, or `libwow64fex.dll` (FEX).
- QEMU was dropped.
- FEX is the "upstream PE version plus some conveniences"; Box64 is the "upstream PE version".

### CPUs

The README names no CPU list. It does require 4K pages: the patch warns otherwise and points to the wiki page
"Page-Size". On the **Raspberry Pi 4**:

- Issue [#164](https://github.com/AndreRH/hangover/issues/164) (2024, Hangover 9.15, Ubuntu 24.04, 4K pages): 32-bit
  programs ran once a fresh prefix was made. The maintainer said 64-bit was "not supported yet" at that time; ARM64EC
  matured afterwards.
- Pi 5 and Snapdragon reports appear in [#193](https://github.com/AndreRH/hangover/issues/193).

---

## 6. Graphics on V3D 4.2 (Pi 4)

### WineD3D on OpenGL: Direct3D up to 9 only

All references are to wine-11.0 source.

- **The floor is GLSL 1.20, which OpenGL 2.1 provides.** The renderer stops with "GLSL version %s is too low; 1.20 is
  required" (`dlls/wined3d/adapter_gl.c`, around line 5118):
  <https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/wined3d/adapter_gl.c>
- **Feature-level rules** (`feature_level_from_caps`, lines 1242–1291 of the same file):
  - **D3D 10/10.1/11** need `WINED3D_GL_VERSION_3_2` + `ARB_polygon_offset_clamp` + `ARB_sampler_objects`, plus
    shader model ≥4 (GLSL 1.50 + extensions).
  - **FL 9_3** needs shader model 3 + 4096-pixel textures + 4 render targets.
  - Shader model 3 needs `ARB_shader_texture_lod` or core gradient functions
    (`shader_glsl_get_shader_model`, `dlls/wined3d/glsl_shader.c` lines 11281–11311):
    <https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/wined3d/glsl_shader.c>
- **V3D 4.2 under Mesa:**
  - The Mesa v3d driver sets `fragment_shader_texture_lod = true`, which exposes `ARB_shader_texture_lod`, and
    `glsl_feature_level_compatibility = 140`:
    <https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.0/src/gallium/drivers/v3d/v3d_screen.c>
  - Mesa's `docs/features.txt` lists `GL_ARB_depth_clamp` and "8 draw buffers" for v3d as **`v3d/vc7+`** only
    (Pi 5): <https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.0/docs/features.txt>
  - V3D 4.2 lacks at least `ARB_depth_clamp`, which GL 3.2 requires, so it cannot offer GL 3.2.
  - **Consequence:** at most FL 9_3. **Direct3D 7, 8 and 9 (SM3) through WineD3D GL work in principle; D3D10/11 do
    not.**
  - *Check on the bench:* the exact GL version Haiku's Mesa reports (the plan says 2.1).
- **No GLES backend.** wined3d contains no OpenGL ES context code (no ES profile requests, checked across
  `dlls/wined3d` at wine-11.20). GLES 3.1 on V3D cannot carry WineD3D.
- **DXT/S3TC textures:**
  - V3D has no hardware BC formats.
  - Mesa's state tracker can expose `EXT_texture_compression_s3tc` through a fallback that stores the textures
    uncompressed as RGBA8 (`texture_mapping_compressed_fallback` in `src/mesa/state_tracker/st_extensions.c`, Mesa
    26.2.0). That costs CPU on upload.
  - The fallback is gated by the driconf option `allow_compressed_fallback`. It defaults to `true` for gallium
    drivers loaded through the pipe-loader (`src/gallium/auxiliary/pipe-loader/driinfo_gallium.h`).
  - *Unverified:* whether Haiku's Mesa front end reads driconf, so whether DXT is available on the Pi under Haiku.
    That matters for Direct3D 8/9 games such as Warcraft III.
  - wined3d's own BC1–3 decompressor applies only to 3D textures (`dlls/wined3d/utils.c`, `init_format_decompress_info`).
- **32-bit GL under WoW64:**
  - Wine 11.0 maps GL buffers for 32-bit programs with Vulkan's `VK_EXT_map_memory_placed`
    (`dlls/opengl32/unix_wgl.c`; the 11.0 note quoted above).
  - **V3DV does not expose that extension** (Mesa 26.2.0 `src/broadcom/vulkan/v3dv_device.c`), so 32-bit OpenGL games
    take the slower fallback.
  - Wine 9.0 had warned of "Reduced OpenGL performance and lack of ARB_buffer_storage" in new WoW64 mode. This is a
    performance risk for Half-Life and UT.

### DXVK: not viable on V3D 4.2

**Newest release: v3.1.1**, 2026-09-15: <https://github.com/doitsujin/dxvk/releases>

**DXVK 3.x** needs **Vulkan 1.4** plus these required items
(<https://github.com/doitsujin/dxvk/wiki/Driver-support>):

- `VK_EXT_depth_clip_enable`
- `VK_KHR_maintenance5`
- `VK_KHR_maintenance6`
- `VK_KHR_load_store_op_none`
- `VK_EXT_robustness2`
- `VK_EXT_transform_feedback`
- 256 B of push constants, descriptor indexing, 8/16/64-bit integer types, `scalarBlockLayout`

**DXVK 2.7** needed Vulkan **1.3** and the same list minus `load_store_op_none` (wiki history, revision 1db7de2,
2026-02-18).

**V3DV on V3D 4.2** (`ver 42`), from Mesa 26.2.0
<https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.0/src/broadcom/vulkan/v3dv_device.c>:

- API version 1.3, not 1.4.
- **Missing:** `EXT_depth_clip_enable`, `scalarBlockLayout`, `shaderInt16` and `shaderInt8` (all `ver >= 71`, Pi 5
  only); `KHR_maintenance6`; `EXT_transform_feedback` ("FIXME: update when supporting EXT_transform_feedback");
  `shaderInt64 = false`; `textureCompressionBC = false`; `tessellationShader = false`.
- **Present:** `maintenance5`, `robustness2`, `load_store_op_none`, `present_wait`, 256 B push constants
  (`v3dv_limits.h`).

**Even legacy DXVK 1.10.3** (Vulkan 1.1) hard-requires, for D3D9, `textureCompressionBC`, `depthClamp`,
`shaderCullDistance` and `shaderStorageImageWriteWithoutFormat`
(<https://github.com/doitsujin/dxvk/blob/v1.10.3/src/d3d9/d3d9_device.cpp>). All four are false on V3D 4.2.

**Verdict:** no DXVK version can run on the Pi 4 GPU. The Hangover README says the same in general terms: "DXVK
requires a Vulkan 1.3 driver with certain features and that might not be the case for a lot of ARM64 hardware".

### WineD3D's Vulkan renderer

- Present, but **not the default**: "not yet at parity with the GL renderer" (11.0 notes). Select it with the
  `renderer=vulkan` key under `HKCU\Software\Wine\Direct3D`, or `WINE_D3D_CONFIG`.
- Its hard requirements are low. `adapter_vk.c` (wine-11.0) marks only `VK_KHR_maintenance1` and
  `VK_KHR_swapchain` as required; transform feedback, extended dynamic state and the rest are optional:
  <https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/wined3d/adapter_vk.c>
- So it is the **only Vulkan path that V3DV could carry**. It needs testing, and features that depend on transform
  feedback (stream output) will be missing.

---

## 7. Legal free test programs

**Terms that apply to all of them:**

- The demos were released free of charge by their publishers for evaluation.
- The Internet Archive's [Classic PC Games](https://archive.org/details/classicpcgames) collection says it "consist[s]
  primarily of PC demos, freeware, and shareware".
- The Archive's Terms of Use make users certify that their use "will be noncommercial and will be limited to
  noninfringing or fair use under copyright law". This is quoted secondhand from <https://blog.archive.org/?p=9040>;
  read the current text at <https://archive.org/about/terms.php>.
- As the plan says, we only download to the bench, never redistribute, and show screenshots or video.

**AppDB ratings** come from Wayback snapshots (the date is in the URL). The live AppDB was unreachable. "Wine" is the
newest Wine version tested in that entry.

| Program (32-bit unless noted) | Download (archive.org item) | Licence / terms | AppDB rating (snapshot) | Graphics API |
|---|---|---|---|---|
| **StarCraft Demo** (1998) | [`SCDEMO`](https://archive.org/details/SCDEMO) (`SCDEMO.EXE`, 29.6 MB) | Blizzard free demo | **Demo: Platinum** (Wine 4.8-staging, 18 tests); 1.16.1 Gold; 1.18+ Silver; [snapshot 2024-12-08](https://web.archive.org/web/20241208220026/https://appdb.winehq.org/objectManager.php?iId=72&sClass=application) | DirectDraw 2D, 640×480×8 |
| ↳ *used instead* | the 1998 **shareware CD** ([`cdrom-starcraft-shareware`](https://archive.org/details/cdrom-starcraft-shareware), `.img` + `.ccd`), not `SCDEMO.EXE` | Blizzard shareware | see tools/mega/assets.txt |
| **Half-Life: Uplink** (1998 demo) | [`Half-lifeUplink`](https://archive.org/details/Half-lifeUplink) (`hluplink.exe`, 50.9 MB) | Valve free standalone demo | **No Uplink row** under Half-Life (iId 8). The retail **1.1.x (WON) is Platinum** (Wine 2.0.3); [snapshot 2025-01-20](https://web.archive.org/web/20250120154149/https://appdb.winehq.org/objectManager.php?sClass=application&iId=8). CodeWeavers rates Uplink "Runs Well" (outdated): <https://www.codeweavers.com/compatibility/crossover/half-life-uplink> | OpenGL 1.x (also software and D3D) |
| **Diablo II Demo 1.04** (2000) | [`DiabloIiDemo`](https://archive.org/details/DiabloIiDemo) (138 MB) | Blizzard free demo | **Demo: Gold** (Wine 3.0.3); full 1.xx Platinum; [snapshot 2024-11-23](https://web.archive.org/web/20241123155308/https://appdb.winehq.org/objectManager.php?iId=74&sClass=application) | DirectDraw / Direct3D / Glide |
| **Unreal Tournament GOTY**, full game | [`ut-goty`](https://archive.org/details/ut-goty) (2 ISOs) and the installer at <https://www.oldunreal.com/downloads/unrealtournament/full-game-installers/> | Free with Epic's blessing since Nov 2024. Epic: "people are free to independently link to and play these versions" ([Slashdot](https://games.slashdot.org/story/24/11/15/181257/internet-archive-now-hosts-classic-unreal-games-epic-games-gives-blessing)); the item description says the upload is "officially sanctioned by OldUnreal (who has received permission from Epic Games …)" | **Silver** (Wine 7.0, 41 tests); demo Silver (Wine 1.1.21); [snapshot 2024-12-26](https://web.archive.org/web/20241226021613/https://appdb.winehq.org/objectManager.php?sClass=application&iId=90) | OpenGL / D3D renderers. Patch: stable **469e** is Windows x86 only. **469f-rc6** (2026-10-17, a release candidate) adds **Windows-amd64**, a future x86-64 test case: <https://github.com/OldUnreal/UnrealTournamentPatches/releases> |
| Unreal Tournament Demo 338 | [`UnrealTournament`](https://archive.org/details/UnrealTournament) | Epic free demo | Demo Silver (as above) | OpenGL / D3D / software |
| Age of Empires II: Age of Kings Demo | [`AgeofEmpiresIITheAgeofKings_1020`](https://archive.org/details/AgeofEmpiresIITheAgeofKings_1020) | Microsoft free demo | **Demo: Gold** (Wine 1.7.26); 2.x Platinum; [snapshot 2024-12-07](https://web.archive.org/web/20241207112359/https://appdb.winehq.org/objectManager.php?sClass=application&iId=99) | DirectDraw |
| SimCity 3000 Demo | [`Simcity3000Demo`](https://archive.org/details/Simcity3000Demo) | Maxis/EA free demo | **Demo: Platinum** (Wine 1.3.17, only 2 tests); retail Garbage; [snapshot 2024-06-25](https://web.archive.org/web/20240625215459/https://appdb.winehq.org/objectManager.php?sClass=application&iId=4086) | DirectDraw |
| Warcraft III: Reign of Chaos Demo 1.01 | [`WarcraftIiiReignOfChaosDemo`](https://archive.org/details/WarcraftIiiReignOfChaosDemo) | Blizzard free demo | Demo: Silver (Wine 6.18); RoC 1.x Gold; [snapshot 2024-12-31](https://web.archive.org/web/20241231104945/https://appdb.winehq.org/objectManager.php?sClass=application&iId=897) | Direct3D 8 (needs DXT, see section 6) |
| Need for Speed: Porsche Unleashed Demo | [`NeedForSpeedPorscheUnleashedDemo`](https://archive.org/details/NeedForSpeedPorscheUnleashedDemo) | EA free demo | No demo row; full 3.5 **Platinum** (Wine 8.1); [snapshot 2024-08-03](https://web.archive.org/web/20240803231321/https://appdb.winehq.org/objectManager.php?sClass=application&iId=2040) | Direct3D 6/7 |
| Age of Empires Demo / Rise of Rome Demo | [`AgeofEmpires_1020`](https://archive.org/details/AgeofEmpires_1020) | Microsoft free demos | Demo Gold (Wine 1.7.22); RoR demo Gold; [snapshot 2024-09-22](https://web.archive.org/web/20240922004041/https://appdb.winehq.org/objectManager.php?sClass=application&iId=762) | DirectDraw |

**Results on the Pi (2026-10-31, H15 sweep; wine 11.20-23 packages, Box64 v0.4.4, network session of the mega
image; frame rates from `WINEDEBUG=+fps`, judged by HDMI captures).** The SHA-256s are in
[tools/mega/assets.txt](../../tools/mega/assets.txt); "0028" is the Wine patch that removes the WoW64 buffer copies
(not yet packaged).

| Program | Result | Notes |
|---|---|---|
| Age of Empires II demo | **Works** (mega image) | DirectDraw, full screen 800×600: menus, a random-map game, units and buildings; ~31 fps in game. The zip's setup program is a CAB: `7z x` gives the game tree, no installer run needed. |
| Unreal Tournament demo 338 | **Works** with the OpenGL renderer (mega image) | ~50 fps at 640×480 in DM-Morpheus. Needs two settings or it crashes at its first frame (KNOWN-ISSUES W10). Direct3D also works: 5–6 fps, 16 with 0028. |
| Diablo II demo 1.04 | **Works in a window** (`-w`; mega image) | Installer runs under Wine; menus, character creation, walking in the Act 1 camp; animates smoothly (a new picture in the HDMI capture ~30 times a second). Full screen stops on "Error 22" (DirectDraw P8 + 3D: W12). |
| Warcraft III demo 1.01 | **Works, slow** (mega image) | Installer needs Windows XP set for it ("Windows NT is not supported"). Direct3D 8 through wined3d: menus, prologue cinematic and map play; 3 fps (1–3 in game) with the packaged Wine, 12–18 fps with 0028. DXT textures work (Mesa's fallback). Menu buttons need the mouse button held ~0.3 s at 3 fps. |
| Need for Speed: Porsche Unleashed demo | **Partly**: menus and garage, races crash | Direct3D 7: menus 2.5 fps (26 with 0028), car models render; starting a race faults in the game (W11). Its InstallShield setup crashed the wineserver (alignment fault, fixed by Wine 0029: W13). Not in the mega image. |

Two other candidates were checked and set aside:

- **Heroes of Might and Magic III demo:** the classicpcgames collection has only the **Macintosh** complete demo
  ([`heroes_3_complete_demo`](https://archive.org/details/heroes_3_complete_demo)). A Windows demo is listed on
  FilePlanet's archive (<https://www.fileplanet.com/archive/p-38433/Heroes-III-Demo-WINDOWS>, not checked further).
  **The AppDB entry was not located; the rating is unconfirmed.**
  *Used since:* the Windows demo `h3demo.exe` from the Internet Archive item
  [`HeroesOfMightAndMagicIiiTheRestorationOfErathia`](https://archive.org/details/HeroesOfMightAndMagicIiiTheRestorationOfErathia)
  (the mega image's sources: [tools/mega/assets.txt](../../tools/mega/assets.txt)).
- **StarCraft (full, free since April 2017, patch 1.18):** <https://www.pcworld.com/article/406475/the-original-starcraft-and-its-beloved-brood-war-expansion-are-now-free.html>.
  Blizzard's free download today is the Remastered client through Battle.net, and the AppDB "1.18+" entry is
  **Silver** (Wine 9.10). A 2020 Wine bug comment says the original download was replaced by Remastered:
  <https://list.winehq.org/pipermail/wine-bugs/2020-June/537796.html>. That is heavier and needs an account, so the
  demo is the better test.

---

## Recommendation

### Wine version (owner decision needed)

- **Strict reading of "stable only": Wine 11.0** (2026-01-13), with **Hangover 11.0's 10-patch stack** (Billy Laws'
  WoW64 allocation and suspension fixes).
  - Hangover 11.0 shows that this exact base works with stable translators: **FEX-2601** and **Box64 v0.4.0**.
  - Next stable bump: Wine 12.0, expected January 2027.
- **Trade-off:**
  - The ARM64EC improvements after 11.0 sit only in **development tags**: 11.9 thread suspension, 11.15 Mingw-mode
    ARM64EC, 11.16 exception handling, 11.20 relay debugging.
  - Development tags are tagged releases, not master snapshots. The newest Hangover (11.16) pairs with one.
  - HaikuPorts itself tracks development releases (11.8, with 11.14 in review).
- **The choice also fixes the translator versions.** Stable Wine 11.0 means **FEX-2601 + Box64 v0.4.0**, the
  Hangover 11.0 pins. **Newer FEX with Wine 11.0 is untested.** The emulator interface has moved since then: 11.9
  added thread suspension in emulated code, and Hangover carries further suspend patches. So the real choice is a
  **January-2026 stack (Wine 11.0, FEX-2601, Box64 0.4.0)** or an **August-2026 stack (Wine 11.16, FEX-2608, Box64
  0.4.4, i.e. Hangover 11.16)**.
- **Default proposal:**
  - Do the native-arm64 Haiku bring-up (plan steps 2–3) on **Wine 11.0**. The Haiku work is the same either way.
  - Pair it with the translators Hangover 11.0 pinned: **FEX-2601** and **Box64 v0.4.0**.
  - Move to 12.0 when it ships.
  - Only if ARM64EC bugs block us, ask the owner to allow a development tag (11.20 or later) for that part.

### Translators (given ARMv8.0)

- **x86-64: FEX `libarm64ecfex.dll` (ARM64EC).** It is the only ARM64EC translator: Box64 has none, and Wine ships
  only the `xtajit64` stub. FEX's minimum (ARMv8.0 + FP + CRC32) **includes the A72**. Without LSE/LRCPC, expect
  slow atomics and TSO emulation; plan to turn TSO off per game.
- **32-bit x86: Box64 `wowbox64.dll` (WoW64)** first. It is Hangover's default, has a dedicated Pi 4 build target, and
  has been in releases since v0.3.6. Keep FEX's `libwow64fex.dll` as the A/B alternative.
- Remember that under WoW64 the 32-bit Wine DLLs themselves (wined3d, ddraw) run emulated. This is a strong reason to
  keep the first games DirectDraw/2D.

### Toolchain

- **llvm-mingw** for the PE side (`--with-mingw=clang --enable-archs=arm64ec,aarch64,i386`):
  - Use **20260826 (LLVM 23.1.0)**, the release Hangover proved with Wine.
  - The newest release is **20261020 (LLVM 23.1.4)**.
  - **No documented minimum.** Wine 10.0 only expected LLVM 20 to be enough.
- FEX's DLLs were built by Hangover with **bylaws-llvm-mingw-20240929**. Try mstorsjo's first and fall back to bylaws'
  if FEX's ARM64EC build fails.
- Unix side: the Haiku arm64 cross GCC, as the plan says.
- **New Haiku work found by this survey:**
  - `ntdll/unix/signal_arm64.c` needs a Haiku branch (it has only `linux` and `__APPLE__`).
  - Haiku must not clobber **x18** in user code that Wine's TEB handling depends on. The kernel saves and restores
    x18 in its interrupt frame (`src/system/kernel/arch/arm64/arch_asm.S`). Whether Haiku's GCC or libroot use x18 as
    a scratch register was **not checked**.
  - Remove the blocking debug code from the 11.8 `segv_handler` before porting it.
  - Graphics: use **winewayland.drv on `wayland_server`**, as HaikuPorts 11.8 does. The alternative is reviving
    `winehaiku.drv` from the 7.1 patchset.

### Graphics

- **WineD3D on OpenGL**, Direct3D ≤9 only.
- No DXVK: V3DV on V3D 4.2 lacks the required features for every DXVK version.
- WineD3D's Vulkan renderer is an experiment for later.

### First three test games (all 32-bit, so WoW64 first)

1. **StarCraft Demo.** DirectDraw 2D, AppDB **Platinum**, 30 MB, light on the CPU. It proves the WoW64 path, the
   Wayland driver and input.
2. **Diablo II Demo 1.04.** DirectDraw/Direct3D, AppDB **Gold**. A known, eye-catching game, still mostly 2D.
3. **Half-Life: Uplink.** OpenGL 1.x, the 3D showcase. AppDB Half-Life WON 1.1.x is **Platinum**; Uplink itself has
   no AppDB row, and CodeWeavers rates it "Runs Well".

Next, as the 3D and speed stretch: **Unreal Tournament GOTY**, legally free through OldUnreal and the Internet Archive.
AppDB rates it Silver. Once 469f is final, its Windows-amd64 build becomes the first **x86-64 game** for the ARM64EC
path.

### Still unverified

- The exact OpenGL version Haiku's Mesa reports on the Pi, and whether it offers S3TC/DXT (driconf fallback).
- Whether stable FEX releases newer than FEX-2601 still work with Wine 11.0.
- Whether FEX's ARM64EC DLL builds with mstorsjo llvm-mingw.
- The HoMM3 AppDB rating.
- Current (2026) AppDB ratings for all entries; the table uses 2024–2025 snapshots.

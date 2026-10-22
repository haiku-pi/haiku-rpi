# H15: Windows programs on Haiku arm64 (Wine + x86 translation): plan

**Status: started 2026-10-21** (the owner asked for it on 2026-10-20, 23:50 CEST, to begin once the backlog was
done). The survey is done and the decisions below are made; step 1 is next.

## Goal

Run Windows x86-64 (and 32-bit x86) programs on Haiku on the Raspberry Pi 4: ordinary applications and some
GPU-accelerated games. The Pi 4 is no gaming machine; the point is to show that it works, and to make it as complete
and as fast as the hardware allows. Use the newest **stable releases and tags** of every component (Wine, the
translator, the toolchains), never a rolling master branch. Test only with **legal, free-to-use Windows binaries**.

## Decisions (2026-10-21, from the survey)

The survey, [wine-x86-survey.md](wine-x86-survey.md), answers every open question of this plan's first draft
with sources. What it settles:

| Question | Answer | Consequence |
|---|---|---|
| Wine version | ~~Wine 11.0, the newest stable release~~ — **revised by the owner (2026-10-21): "stable" means a numbered release, and the newest one** | **Wine 11.20** since 2026-10-22 (ported, tested on the Pi; 11.0 removed); the next numbered release when it ships |
| Translator for x86-64 (ARM64EC) | **FEX** is the only one (`libarm64ecfex.dll`); Box64 has no ARM64EC DLL yet | **FEX**, its newest release when step 3 starts (FEX-2610 as of 2026-10-22; the survey's FEX-2601 was Hangover 11.0's pairing) |
| Translator for 32-bit x86 (WoW64) | Box64's `wowbox64.dll` (Hangover's default, a Pi 4 build target) or FEX's `libwow64fex.dll` | **Box64 v0.4.4** (newest release, since 2026-10-22; v0.4.0 first), FEX's as the alternative |
| Does FEX run on the Pi 4's Cortex-A72 (ARMv8.0)? | Yes: ARMv8.0 + FP + CRC32 minimum; LSE/LRCPC optional, detected at run time | Expect slow x86 memory-ordering emulation without LSE/LRCPC; per-program TSO settings will matter |
| PE-side toolchain | mstorsjo **llvm-mingw**, a pinned release | **20260826** (LLVM 23.1.0), which Hangover built Wine with |
| Wine on Haiku today | HaikuPorts: Wine 11.8, **x86_64 only**, 64-bit programs only, the Wayland driver over X512's in-process Wayland server; ~330 lines of Haiku code | The Haiku patches move to 11.0 and to arm64; Wine's arm64 signal code has Linux/macOS branches only — Haiku needs its own |
| Direct3D | **DXVK cannot run on V3D 4.2** (Vulkan 1.3, no depth clip/clamp, no BC textures, no transform feedback); WineD3D on OpenGL; no GLES backend in Wine | **Direct3D ≤ 9 through WineD3D on desktop GL**; DirectDraw and OpenGL games are the natural targets |
| Test games | Free demos, AppDB-rated: StarCraft demo (Platinum), Diablo II demo 1.04 (Gold), Half-Life: Uplink (retail Platinum); Unreal Tournament GOTY (free since 2024; 469f adds a 64-bit build) | Almost all 32-bit: **the WoW64 path is the critical path**, not an extra |

## The work

1. **Wine on Haiku arm64 (11.0 first, 11.20 now), native arm64 Windows programs first** (no translator): the Unix side cross-built
   with the Haiku arm64 compiler (`scripts/cross-port.sh` style), the PE side with llvm-mingw; the HaikuPorts
   Haiku patches brought to the release and arm64 (signals and exception contexts — Wine keeps per-thread data in x18:
   check that Haiku's compiler and libroot leave it alone — thread/TLS setup, the loader); a console program
   first, then a window through the Wayland driver (X512's server). *Exit:* an arm64 `hello.exe` and an arm64
   GUI program run on the Pi.
2. **32-bit x86 through WoW64 + Box64** (`wowbox64.dll`; v0.4.4 now), then FEX's `libwow64fex.dll` for comparison.
   *Exit:* the StarCraft demo plays.
3. **x86-64 through ARM64EC + FEX** (its newest release). *Exit:* a 64-bit x86 program (7-Zip x64, UT 469f's 64-bit build).
4. **Graphics:** WineD3D on Mesa's desktop GL (2.1 on the V3D): DirectDraw, Direct3D ≤ 9, OpenGL games. Audio
   through Wine's driver for Haiku's media kit, or through SDL/OpenAL.
5. **Speed:** translator settings (TSO modes per program, the code cache, multi-threading), the CPU clock;
   measured as the rest of the port.
6. **Packages, docs, a showcase:** `wine` and the translators as packages in our repository, a user-guide
   section, screenshots and a short video of the games.

### Status (2026-10-21)

- Step 1 done: arm64 console programs, and windows through the Wayland driver (WineMine on the Haiku desktop).
- Step 2: the WoW64 + Box64 path runs 32-bit x86 games on DirectDraw through wined3d's GDI renderer, which is
  exact at 8, 16 and 32 bpp (`tools/wine-tests/ddtest.c`). Heroes III's demo plays its intro video and shows its
  main menu and plays a game. SimCity 3000's demo shows its title, then a garbled city — exactly as the same Wine on
  x86-64 does with the GDI renderer (`tools/wine-ref/run.sh`); with Wine's OpenGL renderer it is right there, so the
  fault is wined3d's GDI renderer (blits from its 8-bit surfaces), not the port. Fallout's demo gets past its dialogs
  to a black screen; on x86-64 Wine it stops on a privileged instruction (0046bfd5), so it is not ours either (under
  Box64 the instruction is not trapped).
- Fixed on the way: libwayland-client's dispatch on Haiku (`patches/wayland`), FreeType for Wine, Box64's FS
  selector under WoW64 (`patches/box64/0002`), a mapping for user-write-only pages (kernel), drive D: = /boot for
  programs that check free space (Z:, Haiku's rootfs `/`, has none).
- Next: **audio** — Wine has no driver for Haiku (HaikuPorts' Wine uses OSS, whose drivers do not cover the Pi):
  a `winehaiku` mmdevapi driver on the Media Kit, modelled on `wineoss` (`patches/wine-11.20/0002`; works). Then
  OpenGL (WineD3D on the V3D: SimCity 3000, Half-Life, UT), or the GDI renderer's 8-bit blits fixed; x86-64
  (FEX-2601 ARM64EC); packages.

### Status (2026-10-22)

- **Wine 11.20 + Box64 v0.4.4** are the build now (`scripts/build-wine.sh`, `scripts/build-box64.sh`; 11.0 and
  v0.4.0 removed), with crash reports and the Haiku arm64 write-fault fix
  ([wine-debugging.md](wine-debugging.md)). On the Pi: OpenGL on the V3D, sound, Heroes III, and
  **Half-Life: Uplink playing its first map** (software renderer, windowed).
- Next: wined3d's OpenGL renderer for DirectDraw/Direct3D games (its present path; the P8 recursion on GL
  2.1), Half-Life's rare full-screen fault (instrumented), StarCraft's picture, x86-64 through FEX, the
  packages published.

## Step 3: x86-64 through ARM64EC + FEX (work in progress, 2026-10-22)

**State (2026-10-22):** x86-64 programs run on the Pi: hello-x64 (threads, SEH), self-modifying code (crash-x64
`smc`, `smc-image`) and crash reports pass under FEX-2610, next to x86 (Box64) and arm64. It took two kernel
fixes (shared file mappings, below; ID registers) and Wine 0004/0009.

**Disk space:** an ARM64X Wine tree and a prefix need about **2 GB on the boot volume** (tree 974 MB, prefix
~725 MB). Test images need `-sHAIKU_IMAGE_SIZE` ≥ 5500.

**The prefix failure was the kernel's** (haiku 894c4abe7f, 2026-10-22). With the ARM64X build, a new prefix
never finished: win32u reported "Session object id doesn't match" for every new process. That happened with a
full boot volume, and also with 1.1 GiB free. wineserver keeps the session's shared objects in a temp file that
it writes through a `MAP_SHARED` mapping and every Wine process maps read-only. Tracing showed the file stopped
receiving the server's writes the moment a new process mapped it. Haiku's VM moved every mapping of the file
onto a private copy-on-write cache: `mprotect()` dropped `B_SHARED_AREA` from a shared mapping, `fork()` then
copied that mapping privately (a consumer of the file's cache), and the next `mprotect()` of a mapping of the
file, seeing a consumer, made the file's cache copy-on-write for all its areas. The fix keeps the area flags
across protection changes and never makes a file's cache copy-on-write. Reproducer:
`tools/kernel-tests/mmap-shared-mprotect.c` (FAIL before, PASS after). The ARM64X build gave the failure an
`mprotect()` and a `fork()` in the right order; the arm64-only build happened not to.

### How it fits together (Wine 11.20 and FEX-2610 sources, Hangover 11.16)

- **Wine** is configured with `--enable-archs=arm64ec,aarch64,i386`, as Hangover does. With both arm64ec and
  aarch64, every 64-bit PE module is built **ARM64X**: one file holds the aarch64 code and the ARM64EC code. Native
  arm64 programs use the first. In a process whose main executable is x86-64, the loader applies the file's
  ARM64X relocations and uses the second (`virtual.c` `update_arm64x_mapping`). `rundll32.exe` and the DLLs are
  ARM64X; `wineboot`, `explorer` and `services` are plain ARM64. arm64ec also makes configure build some modules
  for x86_64 (`extra_arch`); llvm-mingw 20260826 provides `arm64ec-w64-mingw32-clang` and `x86_64-w64-mingw32-clang`.
- **The emulator:** the ARM64EC `ntdll` loads the DLL named by the default value of
  `HKLM\Software\Microsoft\Wow64\amd64` (`wine.inf`: `xtajit64.dll`), from `C:\windows\system32`, which Wine
  serves from `lib/wine/aarch64-windows`. Its `BTCpu64*` exports and `DispatchJump`, `RetToEntryThunk` and
  `ExitToX64` are the emulator interface. FEX's `Source/Windows/ARM64EC` builds `libarm64ecfex.dll` with those
  exports. `build-wine.sh` installs it under both names, as it does for Box64 (`wowbox64.dll` as `xtajit.dll`).
  So no registry change is needed; another emulator can be chosen with the registry value.
- **32-bit x86 through FEX:** `Source/Windows/WOW64` builds `libwow64fex.dll` (the `BTCpu*` WoW64 interface).
  It is installed next to Box64 and chosen with `HKLM\Software\Microsoft\Wow64\x86` = `libwow64fex.dll`. Box64
  (`xtajit.dll`) stays the default.
- **Building FEX** (`scripts/build-fex.sh`): CMake with `Data/CMake/toolchain_mingw.cmake` and
  `MINGW_TRIPLE=arm64ec-w64-mingw32` (target `arm64ecfex`) or `aarch64-w64-mingw32` (target `wow64fex`). The flags
  follow Hangover's `.packaging/*/fexpeec/Dockerfile`: `ENABLE_LTO=False`, `BUILD_TESTING=False`,
  `TUNE_CPU=none`, `ENABLE_JEMALLOC_GLIBC_ALLOC=False`.
  - Hangover's COMPILE.md writes `BUILD_TESTS`, which is not a FEX option.
  - Hangover and FEX's wiki use bylaws' llvm-mingw fork; the upstream 20260826 (LLVM 23.1) builds both DLLs.
    Its only warning is "register X23 is disallowed on ARM64EC" from FEX's own `Module.S` (×5): FEX uses x23
    on purpose.
  - A tag archive has no submodules. The six the MinGW build adds (fmt, xxHash, range-v3, unordered_dense,
    rpmalloc, cpp-optparse) are fetched as archives of the commits the tag pins, each with a SHA-256.
  - Every import of both DLLs exists in Wine 11.20's `ntdll.spec`/`wow64.spec`.
- **FEX's Unix library** (`Source/Windows/UnixLib`, `libarm64ecfex.so`) is not built. It is Linux-only (`prctl`,
  `shm_open`), and every use of it is optional (`UnixLib::Available()`). Without it, FEX has no hardware-TSO
  switch (no such thing on the A72), no unaligned-atomic prctl, no VMA names, no SHM statistics and no
  file-backed code cache.
- **FEX's CPU features come from the registry**
  (`HKLM\Hardware\Description\System\CentralProcessor\N`, values `CP 4030` = ID_AA64ISAR0, `CP 4020`, …,
  `CP 4000` = MIDR, `CP 5801` = CTR_EL0). Without the key FEX stops on an assertion (`hlt #1`, which Wine
  reports as an illegal instruction). On Haiku wineboot made no such key: Wine's logical processor information
  was a stub, and the ID registers were read only on Linux, which emulates EL0 reads of them.
  - Wine 0009: the processor information on Haiku (one package, a core per CPU), and the ID registers read by
    `MRS` as on Linux.
  - The kernel emulates those reads as Linux does (haiku 7225a5f244; on an ARMv8.0 CPU they are undefined).
    The Pi reports MIDR 0x410fd083 and ISAR0 0x10000 (CRC32, no AES/SHA/PMULL, no LSE, no LRCPC), so FEX
    reports SSE4.2. On a kernel without the emulation, 0009 catches the SIGILL and the registers read as 0.
- **Packages:** the ARM64X DLLs double the 64-bit PE side (717 MB unpacked), and `wine` came out at 115 MB, over
  GitHub's 100 MiB. Now the packages are:

  | Package | Size | Contents |
  |---|---|---|
  | `wine` | 81 MB | Requires the next two |
  | `wine_data` | 14 MB | `data/wine` |
  | `wine_directx` | 20 MB | 64-bit D3DX 9–11, D3DCompiler, XAudio2/XACT |
  | `wine_x86` | | i386 side, Box64, and `libwow64fex.dll` |
  | `wine_x86_64` | | `libarm64ecfex.dll` + `xtajit64.dll` |

  `wine_data` and `wine_directx` are split off only for GitHub's file limit.
- **Test programs:** `hello-x64.exe`, `crash-x64.exe` (with the `smc` and `smc-image` self-modifying-code tests,
  now also for x86-64), `ddtest-x64.exe`, `tone-x64.exe`, `gltest-x64.exe` in `data/wine-tests`.

### Box64 or FEX, measured (2026-10-22, the Pi, `tools/wine-tests/cpubench.c`, ms)

| Build, emulator | integer | float | memory | qsort | total |
|---|---|---|---|---|---|
| arm64, native | 93 | 209 | 367 | 1300 | 1969 |
| x86, Box64 (default) | 199 | 219 | 370 | 2169 | 2957 |
| x86, FEX | 191 | 215 | 370 | 8511 | 9286 |
| x86, FEX, `FEX_TSOENABLED=0` | 191 | 214 | 371 | 1874 | 2650 |
| x86-64, FEX | 109 | 215 | 368 | 16618 | 17311 |
| x86-64, FEX, `FEX_TSOENABLED=0` | 110 | 215 | 368 | 16412 | 17105 |

- Straight-line code is close to native under both.
- FEX emulates x86's strong memory ordering by default. The Cortex-A72 has neither LSE nor LRCPC, so that
  ordering costs 4.5x on memory-heavy code (qsort). Box64 does not emulate it by default (`BOX64_DYNAREC_STRONGMEM=0`),
  so the fair comparison is FEX with TSO off: then FEX is slightly ahead. Box64 stays the default for 32-bit.
- x86-64's qsort is slow for another reason: the ARM64EC `ucrtbase.dll` is native code that calls the program's
  x86-64 comparison function 20 million times, each call a transition into the emulator (~0.8 µs). Programs that
  spend their time in their own code do not pay it.
- The checksums of the x86 and x86-64 builds agree; the arm64 build's differs (floating point: arm64 fuses
  multiply-adds).

### Haiku-specific changes

- **`0007-ntdll-haiku-arm64ec-map-noreserve`:** every ARM64EC process maps a one-bit-per-page code bitmap of the
  address space. That is 4 GiB for Wine's 47-bit user space, mapped committed read-only. Haiku commits memory
  for every readable private mapping without `MAP_NORESERVE`, which would end every x64 process on a 4 GB Pi
  ("failed to allocate ARM64EC map"). On Haiku the map is now reserved, mapped with `MAP_NORESERVE` and recorded
  as committed. Runs on the Pi.
- **`0004-ntdll-haiku-arm64-fault-write`** makes up the ESR Haiku's signal frame lacks. It now also gives an
  alignment fault (SIGBUS, `BUS_ADRALN`) its status: FEX emits an x86 store as a store-release, which faults when
  misaligned, and handles that only as `EXCEPTION_DATATYPE_MISALIGNMENT`. As an access violation FEX took it for
  a write to code it had translated and unprotected the page forever (crash-x64 `smc`).
- The rest of the ARM64EC Unix-side code (`loader.c`, `virtual.c`, `thread.c`, the server's
  `init_supported_machines`) has no OS-specific branch.

### Open, in the order to look at them

1. wineboot's syswow64 pass on the ARM64X build (a new prefix had an empty `syswow64`; run by hand,
   `rundll32 setupapi,InstallHinfSection Wow64Install` fills it).
2. `NtFlushProcessWriteBuffers` is a stub on Haiku (Linux: `membarrier`). FEX does not call it; some programs do
   (.NET's GC).
3. Runtime checks: FEX on a Cortex-A72 without LSE/LRCPC (no public report found), its TSO emulation cost, and
   the code cache.

## Test programs (to be chosen and license-checked at the start)

The owner's guidance (2026-10-21 00:13): test with older, very popular Windows games that are known to run under
Wine, from their **publicly available demo versions** or archives such as the Internet Archive's
[classicpcgames](https://archive.org/details/classicpcgames) collection. Nothing is hosted or redistributed
by this project: the binaries stay outside git and outside our packages, downloaded on the bench only to test,
and the result is shown as **screenshots or a short video**. Pick something that catches the eye.

Candidates, to be checked against Wine's application database (WineHQ AppDB ratings) and our GPU at the
start; nearly all are **32-bit x86**, so the WoW64 path (step 4) carries most of them:

| Game (demo) | Why | Graphics path on the V3D |
|---|---|---|
| Half-Life (Uplink / the demo) | iconic, rated well under Wine for years | its OpenGL renderer: fits OpenGL 2.1 |
| Unreal Tournament (1999 demo) | fast 3D, a good speed showcase | OpenGL renderer, or Direct3D 7 via WineD3D |
| Heroes of Might and Magic III (demo) | 2D, very popular, light on the CPU | DirectDraw (2D) |
| StarCraft / Warcraft II–III, Diablo II (demos) | Blizzard classics, well known under Wine | DirectDraw (2D); Warcraft III: Direct3D 8 |
| SimCity 3000 / 4, Need for Speed (demos) | broad recognition | DirectDraw / Direct3D 7–9 via WineD3D |
| Portal (and similar Direct3D 9 games) | stretch goal | Direct3D 9 shaders via WineD3D on GL 2.1 / GLES 3.1: probably beyond the V3D |

Applications, for completeness: open-source Windows builds of 7-Zip, Notepad++ and PuTTY (freely
redistributable). Each pick's source and license terms are recorded here before anything is downloaded.

## Risks

- Wine on Haiku is incomplete even on x86-64; the arm64 port may need much Haiku-side work (exception handling,
  memory layout, the window driver).
- ARM64EC/WoW64 maturity varies between Wine and translator releases; the newest stable pair may need patches.
- Performance on a Cortex-A72 at 1.5 GHz is modest: small 2D and older 3D games are the realistic target.

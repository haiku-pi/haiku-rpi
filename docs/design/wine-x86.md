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

- **Wine 11.21** (2026-11-01: our 29 patches rebased from 11.20, 3 adapted — 0001 configure, 0003/0006 win32u
  framebuffer code; 0028 still needed because Mesa 26.2.6 lacks GL_MESA_map_buffer_client_pointer; mega-smoke
  33/33; `patches/wine-11.21/`). Before: **Wine 11.20 + Box64 v0.4.4** were the build (`scripts/build-wine.sh`, `scripts/build-box64.sh`; 11.0 and
  v0.4.0 removed), with crash reports and the Haiku arm64 write-fault fix
  ([wine-debugging.md](wine-debugging.md)). On the Pi: OpenGL on the V3D, sound, Heroes III, and
  **Half-Life: Uplink playing its first map** (software renderer, windowed).
- Half-Life full screen (2026-10-22, wine 11.20-8): four faults, one under the other. Wine 0012 — the
  game hides the window that holds the exclusive DirectDraw device and plays in another full-screen window, so
  a hidden full-screen GDI swapchain now presents into the process's foreground window. Wine 0013 — wined3d
  evicted a texture's system memory while a DC drew from it (after a swapchain resize, the back buffer's; after
  the next flip the screen showed freed memory: stripes; SimCity 3000's garbled GDI picture was the same
  fault). wayland_server 3 — `WaylandWindow::WindowActivated`/`FrameResized` used the toplevel after the client
  destroyed it. Wine 0011 + haiku 6e517bb52c — a fault in a thread Wine did not create (that Wayland window
  thread) faulted again in Wine's handler with SIGSEGV blocked, and Haiku retried it forever: now the handler
  reports it and the kernel ends a team whose fault signal is blocked (as Linux does).
- Next: wined3d's OpenGL renderer for DirectDraw/Direct3D games (its present path; the P8 recursion on GL
  2.1).

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

## W11: Need for Speed: Porsche Unleashed (demo) crashed at every race start (2026-11-18)

KNOWN-ISSUES W11 (W44 10-31): menus, garage and car models render, every race start faults at
`Porsche.exe+0x8ced6`, `movl 0x264(%eax),%eax` with `%eax` = the global at 0x626b50, still NULL.

**Cause (static, from the demo's `Porsche.exe`):**
- The only store of a non-NULL value to 0x626b50 is in the constructor at 0x48f9c1 (`movl %ebp, 0x626b50`). It
  first asks for two network transports by name, `"IPX"` (0x55f0c0) and `"UDP"` (0x55ee00), then for entry 0 of a
  modem list (0x55d1a0, filled by 0x55cb00, `modemBuf`). With none of the three it destroys the object and
  returns: the global stays NULL. The race code checks it (`testl %eax,%eax; je 0x48ced6`) and jumps straight to
  the dereference: the game assumes the object exists.
- **UDP** (0x582030): `WSAStartup(1.1)`; the local address from RAS (`rasapi32` `RasEnumConnectionsA`, a dial-up
  connection) or else `gethostname()` → `gethostbyname()` → `inet_ntoa()` of the first address; UDP is offered only
  if that string starts with neither `"127."` nor `"0."` and `socket(AF_INET, SOCK_DGRAM)` opens. **IPX**:
  `socket()` for IPX through a table of function pointers (Wine has no IPX). The modem list is empty.
- Wine's `gethostbyname()` of the local host name builds the list from `GetIpForwardTable()` and
  `GetAdaptersInfo()` (`get_local_ips()` in ws2_32), else it asks the host's resolver. On Haiku the route table was
  not implemented (`nsiproxy.sys` `ipv4_forward_enumerate_all`: `/proc/net/route` on Linux, the routing sysctl
  on BSD/macOS, `FIXME("not implemented")` otherwise), so the host's answer for its own name was used: loopback
  or nothing. No UDP → no race object → the crash.
- So the game needs a non-loopback IPv4 address (a Windows PC without a network adapter likely has the same
  problem [inferred, not checked]). A Pi without any network keeps the crash: the game's limit, not Wine's.

**Fix: three Wine patches** (each was needed; found in that order on the Pi):
- `0031-nsiproxy-haiku-ipv4-routes`: `GetIpForwardTable()` on Haiku from `SIOCGRTSIZE`/`SIOCGRTTABLE` (one ifreq
  per route: the interface name, a `route_entry`, the route's addresses; as Haiku's `route` reads it); loopback
  routes get metric ~0 as on Linux.
- `0032-nsiproxy-haiku-find-interface-by-index`: a Haiku patch made `find_entry_from_index()` always return NULL,
  so every `update_if_table()` appended all interfaces again; the table grew between `GetAdaptersInfo()`'s size
  call and its data call, which then always failed with `ERROR_BUFFER_OVERFLOW`.
- `0033-ws2_32-local-ips-default-route-first`: `get_local_ips()` marked an interface as the default-route one only
  if that was its first route (Haiku lists host and network routes first), and compared metrics by unsigned
  subtraction (~0 wrapped): the loopback address came first, as 127.12.34.56.

**Results (session nfs5, 2026-11-18 22:13–22:28; release image-2026-11-18 + the Wine 11.21 test tree with Wayland
packages added; Pi on the wired LAN, 10.42.0.12):**

| | gethostbyname(own name) | GetAdaptersInfo | GetIpForwardTable | game probe | race start |
|---|---|---|---|---|---|
| packaged (11.21-2) | NULL (error 0xc0000005) | 111 (overflow) on the data call | not implemented | FAIL | **crash** `Porsche.exe+0x8ced6`, read of 0x264 (re-run as the control, same session) |
| + 0031 | NULL | 111 | 5 routes | FAIL | — |
| + 0031 + 0032 | 127.12.34.56, 10.42.0.12 | 3 adapters | 5 routes | FAIL ("127.") | — |
| + 0031–0033 | **10.42.0.12**, 127.0.0.1 | 3 adapters | 5 routes | **PASS** | **the race runs**: quick race, Normandie, 911 Carrera, 4 opponents; the clock counts, the car drives (screenshots `artifacts/wine-games/w11/`, not in git) |

Driven by `input.exe` (create player → singleplayer → quick race → RACE), screenshots over ssh. Only the
unix-side `nsiproxy.so` and the i386 `ws2_32.dll` were swapped (built incrementally in artifacts/wine-11.21/cross);
the packages are not rebuilt. **Not tested:** a Pi without any IPv4 address other than loopback (the game then
still crashes, as on Windows without a network adapter: its limit); more than one race; the race on WiFi only;
the x86-64 / arm64 builds of ws2_32 (rebuilt by the next build-wine.sh run). Trap: `scripts/disk-add-tree.sh`
copies no symlinks (the Wine tree's `bin/wine`, `wineboot`, …: 13 links) — they were made by hand on the Pi.
Known gap in 0032: on Haiku `add_entry()` still skips `if_get_physical()`, so an interface's type and hardware
address are left as `malloc` gave them (the loopback interface is then not typed as loopback and is listed by
`GetAdaptersInfo`, as in the table above); harmless for W11, to be set (loopback / Ethernet, zeroed address) in a
later patch. Merge gate for 0031–0033: a full `build-wine.sh` package build and mega-smoke (only the two libraries
were tried); the shared cross tree (artifacts/wine-11.21/cross) and the patched source tree already carry them.

## W14–W16: Haiku's cursor over full-screen games, Notepad++'s menu bar, boxes for symbols (2026-11-23, WC1)

Owner reports (mega36 on the card): in full-screen Wine games (Warcraft III, Diablo II) Haiku's arrow stays on top of
the game's own cursor; Notepad++'s menu bar wraps into 8 rows of ~2 items and ends with three boxes.
Reproduced and checked in one network session (`wc1`, 01:22–01:49, mega36 = hrev60450+373 on a netboot copy; card
and USB untouched; 0 PANIC), the pointer moved with `tools/haiku-tests/mouseto.cpp` (the real pointer, so app_server
picks the cursor of the window under it — `uiinject` posts to a window and leaves the pointer where it is), HDMI frames
in `artifacts/wc1/` (not in git; `montage-*.webp` crop the pointer's neighbourhood).

### W14: `wl_pointer.set_cursor(NULL)` was ignored (wayland_server)

- **Path.** A game hides the cursor with `ShowCursor(FALSE)` (wineserver: cursor count < 0) or `SetCursor(NULL)` (or
  a fully transparent cursor). wineserver posts `WM_WINE_SETCURSOR` with handle 0 to the window under the pointer
  (`server/queue.c` `update_desktop_cursor_window`/`_handle`), win32u calls the driver's `SetCursor`, and winewayland
  (`wayland_pointer.c` `wayland_set_cursor`) drops its cursor surface and sends `wl_pointer.set_cursor(enter serial,
  NULL, 0, 0)`, which the protocol defines as "hide the pointer image". At every `wl_pointer.enter` it sends the
  window's stored cursor again (NULL for a new window until win32u sets one, and for a window that hid it).
- **The server.** `HaikuPointer::HandleSetCursor()` handled a non-NULL surface only: NULL did nothing, so the
  application cursor stayed the last one set. Serials are not checked at all, so a stale serial was not the cause,
  and nothing differs in full screen (no other view or plane: the cursor is app_server's per-application cursor).
  Upstream `master` (8ede02e0e880) now sets `B_CURSOR_SYSTEM_DEFAULT` for NULL: an arrow, still not hidden.
- **Evidence (before, wayland_server -10).** `cursorhide full` (`tools/wine-tests/cursorhide.c`, a WS_POPUP of the
  screen's size with `ShowCursor(FALSE)` and `SetCursor(NULL)`): `WAYLAND_DEBUG=1` shows
  `wl_pointer@3.enter(4, wl_surface@16, …)` then `-> wl_pointer@3.set_cursor(4, nil, 0, 0)` (the enter's serial),
  `GetCursorInfo` says hidden, and the HDMI frame shows Haiku's hand (`before-full-in`). Warcraft III and Diablo II
  menus: Haiku's hand beside the game's gauntlet (`before-war3-a`, `before-d2-a`); their logs have 5 and 4 `set_cursor(…
  nil …)`.
- **Fix: wayland_server 0.1.20251004-11** (`patches/wayland_server/…-wl-pointer-hide-cursor.patch`): a NULL surface
  sets the application cursor to `B_CURSOR_ID_NO_CURSOR` (app_server's 1×1 transparent cursor) while one of the
  client's surfaces has the pointer; `wl_pointer.leave` to no surface restores `B_CURSOR_SYSTEM_DEFAULT` (outside the
  client's surfaces the cursor is the compositor's; the client sets its own again at the next enter). Not
  `BApplication::HideCursor()`: that hides the cursor for the whole screen until shown again, while the application
  cursor is what app_server shows only over that application's windows.
- **After (same session, -11 installed, nothing else changed):** `cursorhide full` and `hide` (windowed): no cursor
  over the window; the pointer moved to the desktop: Haiku's hand; back over the window: hidden again; after the
  program quits: the hand (`montage-cursorhide`). `cursorhide show`: the arrow. Warcraft III and Diablo II: only the
  game's gauntlet; after quitting, Haiku's hand (`montage-games-before-after`, again on the final wine -4 stack:
  `montage-games-final`). Windowed programs keep their cursors: Notepad++ (I-beam), Notepad, PuTTY, SumatraPDF
  (`final-*`). The 1×1 cursor leaves no artefact with the hardware cursor.
- A popup (Notepad++'s File menu, opened with `uiinject`, the pointer moved onto it): the arrow is drawn over it
  (`s2-npp-menu-popup`).
- New windows: winewayland sends NULL at the first enter of a new window (seen 3–4 times per start in Notepad++ and
  `cursorhide show`), so with -11 a new window shows no cursor until win32u sets the window's cursor
  (`WM_WINE_SETCURSOR` on the next pointer motion) — on every compositor, not only ours. A program that does not pump
  messages then shows no cursor over its window; not seen in the programs above.

### W15: Notepad++'s menu bar in 8 rows (Wine 11.21 regression)

`get_menu_bar_height()` (WM_NCCALCSIZE) lays the menu bar out through `NtUserDrawMenuBarTemp()` since Wine 11.21
(f3de8edf99; 11.20's `get_menu_bar_height()` still laid it out every time), which lays it out only when the cached height is 0, so the first layout's width stayed. Upstream fixed it
after 11.21 (b94b54c62b, "Force recalculating menu bar height in get_menu_bar_height"); **Wine 0034** is that commit.
Before: 8 rows (`before-npp-a`, as the owner's frame); after (wine 11.21-4): one row (`final-npp-a`); Notepad and
Notepad++ x86 one row too.

### W16: boxes for symbols (Haiku's fonts invisible to Wine)

- Notepad++ ends its menu bar with U+FF0B ＋, U+25BC ▼ and U+2715 ✕ (strings in `notepad++.exe`). Wine's Tahoma
  has none; its default font links (Tahoma → MS UI Gothic, …, Segoe UI Symbol) name Windows fonts; and without
  fontconfig Wine on Haiku loaded no system fonts at all (its `freetype_load_fonts` reads fontconfig, macOS's or
  Android's /system/fonts only): the registry's External Fonts listed Wine's own fonts only.
- **Wine 0035** (`patches/wine-11.21/0035-win32u-haiku-system-fonts-fallbacks.patch`): Haiku's font directories
  (`find_directory()`, in a file of its own: Haiku's headers clash with Wine's `system_info`) are read like Android's;
  the fonts app_server falls back to (GlyphLayoutEngine.h) are linked, at run time, after Tahoma's, Microsoft Sans
  Serif's and Lucida Sans Unicode's links — every non-symbol font falls back through Tahoma and Microsoft Sans Serif.
  On mega36 that is Noto Sans and Noto Sans Symbols (Thai, Cherokee and Symbols 2 are not installed).
- **Noto Sans CJK JP is left out:** a trial with it linked (11.21-5, not kept) drew ▼ only — ＋ and ✕ came out blank.
  Haiku ships it as a CFF2 variable font (`NotoSansCJKjp-VF.otf`: CFF2, fvar, HVAR); the FreeType Wine loads at run
  time is app_server's 2.6.3, which predates CFF2. Without it (11.21-4): ▼ and ✕ drawn, ＋ a box
  (`npp-glyphs-before-after4`, `npp-glyphs-with-cjk-link`, `npp-glyphs-final`). Fullwidth forms and CJK need a newer
  FreeType for Wine or a static CJK font.
- **A face that is not installed** (Arial, Courier New, Segoe UI…): Wine tries Arial/Liberation/Bitstream Vera by
  class, then its font backend's fallbacks (fontconfig elsewhere; none on Haiku), then the first family in name
  order — Tahoma before, **Noto Mono** once Haiku's fonts are loaded. So 0035 also answers the backend's fallbacks on
  Haiku: fixed pitch Noto Sans Mono / Noto Mono, serif Noto Serif, sans-serif Wine's Tahoma (as before).
  `tools/wine-tests/fontmap.exe` (GetTextFace of 12 requests) in a second session (`wc1`, 02:01–02:14, mega37 =
  hrev60450+375, the same wine -3 / wayland_server -10; 0 PANIC), stock → final -4: unchanged (Tahoma) for Arial,
  Segoe UI, Verdana, Times New Roman and Courier New without a class, MS Shell Dlg, Tahoma, no name; **changed** only
  where the program asks for the class: Times New Roman `VARIABLE_PITCH|FF_ROMAN` Tahoma → Noto Serif, Courier New and
  Consolas `FIXED_PITCH|FF_MODERN` Tahoma → Noto Mono. Notepad++ with its readme: editor text identical, menu 8 rows → 1
  (`montage-npp-text-before-after`); SumatraPDF identical to mega-smoke's stock screenshot (its bookmark pane of "0"
  rows is the test PDF's, also on stock). Not measured: Wine's start time with ~15 more fonts to scan (the prefix
  updates took 40–53 s; no baseline taken).

**Published 2026-11-23 (P1; haiku-pi/packages 514cc04, KNOWN-ISSUES W14 and W15 closed, W16 left as the fullwidth/CJK
residue).** Gate on mega38 (session p1, 03:02–03:12, 0 PANIC; frames `artifacts/p1/`, not in git): Warcraft III and
Diablo II menus show only the game's gauntlet, Haiku's hand back on the desktop after quitting; Notepad++ x86-64 menu
bar one row with ▼ ✕ (＋ a box) and its I-beam over the editor; PhotoCraft (the server's other client) starts, draws
and shows its cursor over its window and on the desktop; mega smoke 34 of 34, Tracker 39 of 39 with a fresh -4 prefix.
The packages were the test packages, byte for byte: wayland_server
0.1.20251004-11; wine, wine_data, wine_directx, wine_x86, wine_x86_64 11.21-4 (GCC 16.2, `WINE_PACKAGES_SHARED=no
scripts/build-wine.sh`; no warnings in the changed files; the committed series applied to a clean 11.21 gives the
built tree's `dlls/` and `server/` exactly). **Not checked:** a Wine program that hides the cursor without pumping messages; StarCraft and Age of Empires II
(their intro and EULA were up during the frames); the x86-64 build; a real mouse by hand.

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

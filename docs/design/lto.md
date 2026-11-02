# Link-time optimisation with GCC 16.2 (H17b, part 1: feasibility on the host)

Goal (PLAN.md row 3b, owner 11-01): find out whether Haiku and our ports build with `-flto` on GCC 16.2, what it
costs, and prepare a Pi A/B of the same image with and without LTO. Part 1 (this note, 11-02) is host only:
no Pi was used. The Pi runs are part 2.

**Result:** Haiku's whole userland (libroot, the kits, the servers, Tracker, Deskbar, the media kit, every app,
translator and add-on) builds with LTO, `@minimum-mmc` and the regular GL image (`-sHAIKU_PI_GL=1 @pi-mmc`) alike,
**without any source change**: one per-output-directory `UserBuildConfig`
([tools/build/UserBuildConfig.lto](../../tools/build/UserBuildConfig.lto)) with five workarounds for the build
rules. The LTO image boots to the desktop in QEMU and passes the same smoke tests as the non-LTO one. Kernel, kernel
add-ons and boot loader are left without LTO. The comparison image `gb-gcc16-lto.img` is ready for the Pi.

## Where it was built

In the GCC 16.2 tree (`/home/houp/haiku-rpi-gcc16`, see [gcc16.md](gcc16.md) step 3), Haiku at de1a4a439d (= the
`gb-gcc16.img` build), in a **separate output directory** so that `generated.arm64` (and `gb-gcc16.img`) stay as
they are:

```
cd /home/houp/haiku-rpi-gcc16/sources/haiku
mkdir generated.arm64-lto && cd generated.arm64-lto
../configure --cross-tools-prefix /home/houp/haiku-rpi-gcc16/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-
cp -al ../generated.arm64/download download                       # the same packages (hard links)
cp /home/houp/haiku-rpi/tools/build/UserBuildConfig.lto UserBuildConfig
```

The resulting `BuildConfig` equals `generated.arm64`'s except for its own paths (same 16.2 cross tools).
`scripts/build.sh --generated DIR` builds there (its images go to DIR, or `PI_IMAGE_OUT`).
`-sHAIKU_PI_LTO=0` builds the same directory without LTO: that baseline produced byte-for-byte the same sizes as
`generated.arm64` (libroot, libbe, app_server, libtracker checked), so `generated.arm64` is the size baseline.

## What LTO needs in Haiku's build (all in the UserBuildConfig)

| # | Problem | Symptom | Workaround |
|---|---|---|---|
| 1 | Where to add `-flto` | — | `TARGET_CCFLAGS_arm64`, `TARGET_C++FLAGS_arm64` += `-flto`; `TARGET_LINKFLAGS_arm64` += `-flto=4`. Kernel and boot objects clear `TARGET_CC/C++FLAGS` (KernelRules, BootRules), so they never get it. Not `-flto=auto` at link: jam has no make jobserver, so every concurrent link would start 16 LTRANS jobs |
| 2 | Static libraries | (prevented) | `TARGET_AR/RANLIB_arm64` = `aarch64-unknown-haiku-gcc-ar/-gcc-ranlib` (the plugin's symbol index; `liblto_plugin.so` is in the 16.2 cross tools) |
| 3 | `CreateAsmStructOffsetsHeader` reads `gcc -S` output | `...failed CreateAsmStructOffsetsHeader1 syscall_types_sizes.h` (the "assembly" is LTO IR) | the action redefined with `-fno-lto` |
| 4 | Symbol versioning is top-level asm (`B_DEFINE_SYMBOL_VERSION`: `.symver f, f@@VER`) | LTRANS assembler: `invalid attempt to declare external version name as default in symbol 'sigprocmask@@LIBROOT_1_ALPHA4'` (libroot), `BDirectory::GetStatFor@@LIBBE_1_ALPHA1` (libbe) — the asm and the function land in different partitions | `-flto-partition=one` for the four libraries that use it: libroot, libbe, libbsd, userlandfs' libfuse (`LINKFLAGS` config variable, local scope) |
| 5 | `MergeObject` (`ld -r` by plain ld, no plugin) | libbe: `undefined reference to hsl_color::from_rgb`, `DragTrackingFilter::DragTrackingFilter` — ld -r of slim LTO objects sees no undefined symbol, so the interface kit's `libshared.a` contributed nothing | `MergeObjectFromObjects` redefined: userland merges go through `gcc -r -nostdlib -flto=4` (GCC's incremental link: plugin, merged IR); kernel and boot merges keep plain `ld -r` (the boot loader adds raw ld flags) |
| 6 | `runtime_loader` is linked by plain `ld` (MainBuildRules `Ld`) | `plugin needed to handle lto object`, undefined `KMessage::…`, `arch_relocate_image` | its own objects `-fno-lto` (set in `UserBuildConfigRulePostBuildTargets`: `StaticLibrary` sets `C++FLAGS` on its objects, which hides a directory config variable), and `-ffat-lto-objects` in libroot, whose objects it also links. runtime_loader comes out identical to the non-LTO one |

Not needed: anything for the gcc driver links (collect2 always loads the plugin), for assembler files (`.S` get
`ASFLAGS`), or for the version scripts (`-Wl,--version-script`: libroot's and libbe's versioned exports are all
there). An upstreamable version would be a `HAIKU_USE_LTO` build option doing the same in the rules
(ArchitectureRules/MainBuildRules), plus `__attribute__((symver))` (GCC ≥ 10) in `B_DEFINE_SYMBOL_VERSION`, which
would let those four libraries partition too.

**Kernel and boot loader: excluded.** Both are linked by plain `ld` with linker scripts (KernelRules, BootRules); LTO
there means linking through the driver with `-nostdlib` and the scripts, and `vm.cpp` has the same `.symver` asm. Not
"trivially fine", so not tried; the kernel is the same in both images (text 1 725 752; 6 bytes differ: the build time
string).

## Per component

Builds from the same output directory (relink = only the final LTO link, with the objects present: `rm` the
binary, `jam` it again; the relinked files were byte-identical to the image build's).

| Component | Builds | Error / workaround | LTO relink | Largest process | text non-LTO → LTO | data |
|---|---|---|---|---|---|---|
| libroot.so | yes | #3, #4 (one partition), #6 (fat objects) | 14.1 s | 347 MB | 1 015 683 → 1 075 676 (**+5.9 %**) | 52 888 → 52 840 |
| runtime_loader | yes (no LTO) | #6 | — | — | 110 126 → 110 126 (identical) | |
| libbe.so | yes | #4, #5 | 28.7 s | 346 MB | 3 164 285 → 3 120 264 (−1.4 %) | 149 472 → 145 104 |
| app_server | yes | — | 15.9 s | 206 MB | 1 472 013 → 1 405 462 (**−4.5 %**) | 41 624 → 37 689 |
| libtracker.so | yes | — | 6.6 s | 189 MB | 1 833 558 → 1 722 341 (**−6.1 %**) | 99 864 → 96 844 |
| Tracker (app) | yes | — | | | 2 473 → 2 539 | |
| Deskbar | yes | — | | | 450 180 → 439 185 (−2.4 %) | 32 920 → 32 737 |
| libmedia.so (+ media_server, media_addon_server) | yes | — | 4.1 s | 184 MB | 763 105 → 765 930 (+0.4 %) | 44 308 → 43 896 |
| libtranslation.so | yes | — | | | 83 162 → 83 481 | |
| `@minimum-mmc` | yes | all of the above | | | | |
| `-sHAIKU_PI_GL=1 @pi-mmc` (regular GL image) | yes | all of the above; same 11 `not available` packages as without LTO | | | | |
| kernel, kernel add-ons, boot loader | not tried | plain-ld links (see above) | | | identical | |

Whole regular image, all 569 linked ELF files (shared objects and executables): **text 78 809 931 → 76 745 144
(−2.6 %)**, data −1.0 %; larger in 137, smaller in 233, unchanged in 199 (the kernel side). `haiku.hpkg` 36.39 →
35.81 MB. libroot grows because one partition inlines more (its string routines are assembler either way); the C++
kits and servers shrink.

**Build cost**, clean `objects/haiku` + `objects/catalogs`, same directory, same host tools, `-sHAIKU_PI_GL=1
-sHAIKU_IMAGE_SIZE=3500 @pi-mmc`, `scripts/build.sh` (heavy-build: 16 jobs), measured with `/usr/bin/time -v` and the
heavy-build scope's cgroup sampled every 2 s:

| | wall | user + sys CPU | largest single process | scope anon peak | scope memory.peak (incl. page cache) | `objects/haiku` |
|---|---|---|---|---|---|---|
| without LTO | 4:29 | 2889 + 390 s | 876 MB | 1.85 GB | 7.10 GB | 578 MB |
| with LTO | 5:15 (**+17 %**) | 3069 + 444 s (+7 %) | 878 MB | 2.58 GB | 6.92 GB | 769 MB |

Slim LTO compiles are fast (libbe's 388 objects in ~10 s); the time moves into the serial links, mostly the four
one-partition libraries (libbe's link 29 s). Memory is no concern: no LTO link exceeded 350 MB.

**Warnings** (same build, `warning:` lines 3628 → 3907): new at link time `-Wlto-type-mismatch` ×267 — every one is
`start_dyn.c` declaring `main(int, char**, char**)` against apps' `main()`/`main(int, char**)` (harmless); `-Wodr`
×32 — the locale kit's classes (`BLanguage`, `BLocale`, … with `U_ICU_NAMESPACE::Locale*` seen as `icu::` in some
units and `icu_74::` in others: same layout), `LocaleRosterData`, Time preferences' views, `DateTimeEdit`, libsolv's
`_Pool`/`_Repo` (field count differs between units: an `#ifdef`), strace's two different `struct enum_info` (a real
duplicate name in `area.cpp` and `network.cpp`); `-Wfree-nonheap-object` ×7 in print_server's
`Resource::~Resource` (deleting destructor through a non-primary base at offset 80; looks like a false positive). Gone
at LTO: a few `-Wformat-overflow`, `-Wstringop-truncation`, `-Wrestrict` (inlined away). None is an error; candidates
for upstream clean-up are the strace and libsolv ODR items.

**Exports.** LTO drops **unused vague-linkage symbols** from the dynamic tables: 10 006 distinct symbols (11 200 file/symbol pairs) in 198 files
(libbe 653, libtracker 646, app_server 427, libmedia 124, libroot 12 …), every one of them **weak** in the non-LTO
build (checked for all 11 200)
(inline functions, template instances, and 116 vtables/typeinfo in libbe of classes without a key function) — the
copies every user emits itself. Checked: no ELF file of the LTO build, and none of the 87 runtime packages we ship
(Mesa, WebKit, Firefox, Wine, SDL2, ffmpeg, Python, the games, …, extracted) imports a dropped symbol that its
`DT_NEEDED` libraries no longer provide (0 hits). libroot gained two exports (`__year_to_secs`, `__month_to_secs`,
musl internals). The versioned exports (`@@LIBBE_*`, libroot's) are all present.

## QEMU

`scripts/qemu-virt.sh` (virt, 4 CPUs, 2 GB):

- `@minimum-mmc` with LTO: Tracker/Deskbar desktop in 120 s; only the minimum profile's missing-library lines.
- Regular GL image with LTO vs without (the gcc16 tree's `haiku-pi4-regular.img`), both with
  `tools/pi-tests/gcc-syslibs.sh` as UserBootscript and `launchtime`/`cxxrt`: identical results — `cxxrt` and
  `cxxrt-rootfirst` ok, Tracker/Deskbar/Terminal on libstdc++.so.6.0.36, Terminal, StyledEdit, MediaPlayer,
  ShowImage, DeskCalc, Debugger each open 3 windows, GLTeapot runs 30 s, `debugger entries: 3` on both (the known
  baseline). QEMU launch times (TCG) are not a performance measure; the two sides were comparable (e.g. Terminal 358/360 ms,
  DeskCalc 84/88 ms on first launch).
- `gb-gcc16-lto.img`: boots to the desktop, `games-bench.sh` starts and QuakeSpasm plays demo1 (softpipe), as
  `gb-gcc16.img` did.

## The comparison image

`/home/houp/haiku-rpi-gcc16/artifacts/images/gb-gcc16-lto.img` — 3 707 764 736 bytes (1.3 GB on disk), sha256
4d6a6813…a6ff2c968f. Made exactly as `gb-gcc16.img` (gcc16.md "Performance comparison"), from the same game trees,
packages and test binaries (none changed since `gb-gcc16.img` was made, 07:05):

```
cd /home/houp/haiku-rpi-gcc16
PI_IMAGE_OUT=/home/houp/haiku-rpi-gcc16/artifacts/images/lto-regular-3500.img \
    scripts/build.sh --generated sources/haiku/generated.arm64-lto -sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=3500 @pi-mmc
S=/home/houp/haiku-rpi/artifacts/gcc-syslibs/16.2
scripts/games-bench-image.sh artifacts/images/lto-regular-3500.img artifacts/images/gb-gcc16-lto.img \
    artifacts/packages/glmark2-2023.01-2-arm64.hpkg:/boot/system/packages/glmark2-2023.01-2-arm64.hpkg \
    $S/launchtime:/boot/home/launchtime $S/cxxrt:/boot/home/cxxrt $S/cxxrt-rootfirst:/boot/home/cxxrt-rootfirst
rm artifacts/images/lto-regular-3500.img
```

**What differs between the two images: only Haiku's own userland** (libroot, the kits, servers, Tracker, Deskbar,
apps, translators, media and other add-ons — including the media kit's ffmpeg plugin, not ffmpeg's libraries).
Kernel, drivers and loader are identical; so are all packages: Mesa, SDL2, ffmpeg, Python, Wine, the games. Note that
**ioquake3 (the Quake III demo and OpenArena) already builds with LTO on both sides**: its CMakeLists enables
`CMAKE_INTERPROCEDURAL_OPTIMIZATION` when `check_ipo_supported` passes, and it does (388 `-flto=auto` in its
`build.ninja`). So the game and GL numbers will mostly show app_server/libroot/libbe effects, if any; boot, app
launch, Tracker and Python's libroot-bound start-up are where to look.

## Pi A/B plan (part 2, the main session runs it)

Same procedure as gcc16.md's comparison: A = `gb-gcc16.img`, B = `gb-gcc16-lto.img` (both in
`/home/houp/haiku-rpi-gcc16/artifacts/images/`), from the main tree, network boot, alternating **A → B → A → B → A →
B** (three of each), same card, cooling, firmware; median reported. If the 13.3-vs-16.2 series is still running, the
LTO runs can join it as a third image in the same rotation (13 → 16 → LTO), so the 16.2 runs serve both comparisons.

| Workload | Command per run (IMG = A or B; labels `…16-N` / `…lto-N`) | Read with |
|---|---|---|
| Games (QuakeSpasm, vkQuake, Yamagi Q2 timedemos, Q3 demo, OpenArena, STK 60 s race, Wine gltest/d3dtest, Half-Life Uplink) | `scripts/netboot-cycle.sh --image IMG --secs 2400 --until 'GB end' --retry-wedge --label gblto-1` (~25 min) | `scripts/games-bench-table.py --a gcc16 <gb16 logs> --b lto <gblto logs>` |
| glmark2-es2 (window + full screen) | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/glmark2.sh --secs 1200 --until 'GM2 end' --label gm2-lto-1` | `GM2 … Score` |
| App launch (Terminal, StyledEdit, MediaPlayer, ShowImage, DeskCalc, Debugger ×3), C++ runtime, GLTeapot | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/gcc-syslibs.sh --secs 600 --until 'CXXRT end' --label lt-lto-1` | `CXXRT launch …: window N ms` |
| Python 3.14 + sqlite (start-up, `benchmark`, sqlite3, hashlib, zlib) | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/python.sh --secs 600 --until 'PY end' --label py-lto-1` | `PY startup-*`, `PY benchmark` |
| Boot time (SD) | `scripts/sd-cycle.sh --flash IMG --secs 120 --label boot-lto-1`, then twice `scripts/sd-cycle.sh --secs 120 --label boot-lto-2` (warm) per image | `scripts/boot-times.sh artifacts/uart/*-boot-lto-*.log` |

Firefox start / Speedometer (PLAN.md lists them) need an image with Firefox and a network; Firefox itself is the same
13.3-built package on both sides, so only libroot/libbe/app_server differ under it — run it only if the cheaper
workloads show a difference. Restore the SD card's usual image afterwards.

Adoption rule (PLAN.md): adopt where it measurably helps. Sizes alone favour it slightly (−2.6 % text) at +17 %
build time; libroot's +5.9 % must not cost start-up time.

## Ports (assessment; nothing changed in the scripts)

Common need: LTO objects in static archives require the plugin-aware tools. Today every port uses plain
`ar`/`ranlib`/`nm`: `tools/meson/haiku-arm64.cross` (lines 17–18, no ranlib entry), `tools/cmake/haiku-arm64.cmake`
(`CMAKE_AR`/`CMAKE_RANLIB`, lines 57–58), `scripts/cross-port.sh` (line 98 script mode, lines 131–134 autotools).
Switching those to `gcc-ar`/`gcc-ranlib`/`gcc-nm` is harmless without `-flto` and is the first step; then a per-port
opt-in.

| Port | Script | Switch | Notes |
|---|---|---|---|
| ioquake3 (Q3 demo, OpenArena) | build-q3.sh | **already on** (CMake IPO) | in both images |
| QuakeSpasm | build-games.sh (plain make) | `CC="… -flto=auto"` | **built as proof**: no change needed, 5.5 s vs 4.3 s, text 703 676 → 702 045 (−0.2 %), one warning fewer. Not in any image |
| Yamagi Quake II | build-games.sh (CMake) | `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` | renderer and game `.so` modules are dlopened; per-DSO LTO is fine |
| vkQuake | build-vkquake.sh (meson) | `-Db_lto=true` | the project sets `werror=true`: new `-Wlto-type-mismatch`/`-Wodr` would fail it (`-Dwerror=false`) |
| SuperTuxKart | build-stk.sh (CMake, STKRelease) | `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` | bundles static deps (FreeType, HarfBuzz, Irrlicht, Bullet): gcc-ar mandatory; keep the script's libgcc_s/unwinder checks |
| SDL2 | build-packages.sh / build-games.sh (CMake) | `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` | shared only |
| ffmpeg6 | build-ffmpeg.sh (configure via cross-port.sh) | `--enable-lto`, `--ar=…gcc-ar --ranlib=…gcc-ranlib --nm=…gcc-nm` | shared only; NEON asm and the libav* version scripts are usually fine with GCC LTO |
| Python 3.14 | build-python.sh | `--with-lto` (not `--enable-optimizations`: PGO would run the target python) | its bundled `liblzma.a` needs gcc-ar or stays non-LTO; check that the `_sysconfigdata` rewrite also cleans `-flto`/`gcc-ar` |
| Mesa | build-gl-stack.sh (meson) | `-Db_lto=true -Dallow-broken-lto=true` | **Mesa refuses LTO by default** (`meson.build`: error unless `allow-broken-lto`, "may break your driver randomly"); last, if at all. libdrm/libglvnd/GLU/loader are easy |
| Firefox, SpiderMonkey | build-firefox.sh, build-spidermonkey.sh | `--disable-lto` today | Mozilla's LTO is built around clang/lld (cross-language); leave |

Suggested order, if the Pi A/B favours LTO: the toolchain files' gcc-ar → the Quakes, SDL2 → ffmpeg, Python, STK →
libdrm/libglvnd/GLU → Mesa last. Each port then needs its own A/B (Quake timedemos, Python benchmark), since the
system A/B above does not cover them.

## Shipped static libraries are slim LTO archives

`haiku_devel` ships 11 static libraries (`libshared.a`, `liblocalestub.a`, `libnetservices.a`, `libnetservices2.a`,
`libcolumnlistview.a`, `libprint.a`, `libprintutils.a`, `libposix_error_mapper.a`, and the `libc.a`/`libm.a`/
`libpthread.a` stubs). In the LTO build their members are **slim GCC 16.2 IR** (e.g. `liblocalestub.a`'s
`CatalogStub.o`: empty `.text`, 16 `.gnu.lto_*` sections). The regular image does not contain `haiku_devel` and our
ports' sysroot comes from the non-LTO `generated.arm64`, so the A/B is unaffected; but for adoption: a program linked
against them needs the plugin of the **same** GCC (the dev images' on-device `gcc-13.3.0` package could not link them
at all), and anything that calls `ld` or `ar x` directly fails. So the shipped archives need `-ffat-lto-objects` (or
`-fno-lto`) — and, as for runtime_loader, not as a directory config variable (`StaticLibrary` sets `C++FLAGS` on its
objects), but in the post-parse hook or the rule itself. Distributions ship fat objects for this reason.

## Decisions needed

- None to finish part 1. For adoption: the per-directory workarounds (#3–#6) are fine for an experiment; a main-build
  LTO option should become proper jam rules on a `lto` branch (and `__attribute__((symver))` for the four libraries)
  rather than a UserBuildConfig that redefines two rules.
- If adopted: fat (or non-LTO) objects for the static libraries `haiku_devel` ships (section above).
- The +17 % clean-build time and the dropped weak exports (safe for C++ ABI, checked against everything we ship) are
  the costs; whether they are worth it is the Pi A/B's answer.

Files of the study (gcc16 tree, not in git): `artifacts/lto/` (build logs `pi-gl-lto.buildlog`,
`pi-gl-nolto.buildlog`, timings `*.time`/`*.mem`, the export and size check scripts `exports.sh`, `imports.py`,
`sizes.py`), `sources/haiku/generated.arm64-lto/` (the LTO build, 769 MB of objects).

## Pi A/B results (2026-11-02 19:33–23:18)

gb-gcc16-fix.img vs gb-gcc16-lto-fix.img (both GCC 16.2 with the secondary-CPU fix eb4bdd0ea4/132765eed5; only
Haiku's userland differs), three alternating rounds, network boots, no throttling (61.8–71 °C). Raw:
artifacts/lto-ab/ (results.txt, games-table.md).

| Workload | GCC 16.2 | 16.2 + LTO | Δ |
|---|---|---|---|
| Quakes, OpenArena, Half-Life (all settings) | — | — | within ±1 % |
| SuperTuxKart 720p | 41.8 (2 runs) | 37.5 (31.2–43.3) | noise (its spread) |
| Wine gltest arm64 | 186.6 (183.9–190.0) | 178.9 (177.8–179.7) | **−4 %, in all three rounds** |
| Wine gltest x86 / d3dtest | — | — | within ±1 % |
| glmark2 window / full screen | 329–331 / 88 | 330 / 88 | 0 % |
| App first launch (Terminal, StyledEdit, MediaPlayer, ShowImage, DeskCalc, Debugger) | — | — | within noise (±10 %, both ways) |
| Python cold start | 0.330–0.363 s | 0.315–0.332 s | −4 % |
| Python warm start, sum, loop, sort | — | — | within ±2 % |

**Verdict: LTO of Haiku's userland brings no measurable gain on this system**, one small consistent loss (Wine's
arm64 GL test, −4 %), against +17 % clean build time and libroot +5.9 % text. Not adopted. Worth revisiting
per port (Mesa, ffmpeg, SDL2, Python with PGO) where the hot code is the port's own; the core result is
the same as GCC 13.3 → 16.2: this workload is bound by the GPU, memory and the display path, not by
the userland's code generation.

Side result: 24 network boots of the two fixed images, **0 early panics** (the unfixed gb-gcc16.img: 3 in
~14) — the loader fix eb4bdd0ea4 holds (Fisher p ≈ 0.04).

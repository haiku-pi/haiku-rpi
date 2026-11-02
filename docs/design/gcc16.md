# Toolchain to GCC 16.2 (H17)

Goal (PLAN.md backlog item 3, owner 11-01): build Haiku arm64, the kernel, the GL stack and our packages with
GCC 16.2.0 (the newest release) instead of 13.3.0, which we and upstream Haiku use today; then compare the two
on the Pi. This note covers step 1 (host only: the cross compiler and a first compile of Haiku with it) and the
plan for the rest.

## What Haiku changes in GCC

Haiku carries GCC as a vendored tree in `buildtools/gcc/` (with gmp, mpfr, mpc and isl inside it). Pristine
releases are imported on the branch `vendor-gcc` and merged into `master`; the Haiku changes are the difference
between the two. Against 15.3.0 that is 59 files, about 4000 lines, most of them new files:

| Area | Files | What |
|---|---|---|
| Target definition | `gcc/config.gcc`, `gcc/config/haiku.h`, `haiku.opt` (+ `.opt.urls`, needed since GCC 14), `haiku.c`, `haiku-protos.h`, `haiku-stdint.h`, `t-haiku`, per-CPU `*/haiku*.h`, `t-*haiku*` (aarch64, arm, x86, x86-64, m68k, mips, ppc, ppc64, riscv64, sparc) | the `*-*-haiku*` targets: `-lroot` as libc, `-fPIC` and frame pointers by default, `-Wno-multichar`, Haiku's type sizes, specs for crt files, libgcc_s, `--hash-style` |
| Host/build | `gcc/config.host`, `gcc/configure.ac`, `gcc/Makefile.in`, `include/filenames.h`, `config.rpath`, `libtool.m4`, top-level `configure.ac` | Haiku as a host (no `-lm`, `--with-hybrid-secondary` for the x86 hybrid's secondary compiler), Haiku's library search paths in libtool |
| Runtime libraries | `libgcc/config.host`, `libgcc/config/t-haiku`, `libgcc/config/aarch64/haiku-unwind.h`, `libgcc/crtstuff.c`; `libstdc++-v3/config/os/haiku/*` (ctype, error codes, os_defines), `crossconfig.m4`, `configure.host`, `libsupc++/tinfo.cc`; `libatomic`, `libgomp`, `libbacktrace` configure | which libgcc pieces are built; libstdc++'s OS layer; libatomic links without `-pthread` when it can (pthreads are in libroot) |
| Headers | `ginclude/stddef.h`, `stdarg.h` | Haiku's `size_t`/`wchar_t`/`va_list` conventions |
| Misc | `zlib/zutil.h`, `c++tools` (link with libnetwork), `libcody/configure` | build fixes for Haiku as a host |

Generated `configure` scripts carry the matching hunks. (The 15.3 delta also had `zlib/zutil.h`, removing
zlib's macOS `fdopen` define, d8207e22d2; GCC 16 bundles zlib 1.3.1, which dropped it itself, so the 16.2 delta
is one file shorter.) Ours (haiku-pi fork) adds four arm64 commits on top:
libgcc_s linked as needed (85273c9ba6), `REAL_LIBGCC_SPEC` for a `--disable-shared` compiler (393b4ec7a4),
`--hash-style=both` by default (fc2ad25b8b), and in binutils `-z pack-relative-relocs` (1cad3a62fa).

## How it was ported

Upstream already did half of it: Jérôme Duval imported **GCC 15.3.0** onto `vendor-gcc` (8465a824ae, 10-11) and
proposed the merge with Haiku's changes as Gerrit change **12070** (a69c732e, merge of master 33d46bf5c3 and
vendor-gcc d7a7951064) plus **12071** (662fd8ac, `haiku.opt.urls`); both still under review on 11-01.
HaikuPorts' `sys-devel/gcc` 15.3.0 recipe (pinned haikuports c17ec5a8d2f0) carries the same change as the first
patch of its patchset ("Modifications for GCC 15.3.0 for Haiku (from buildtools repository)") plus seven
libsanitizer/c++tools patches for the native compiler package; it confirmed the delta but the buildtools merge
itself was the better base (it has history). Upstream has no GCC 16 work; a 14.1.0 import (35be7241cf, 2024)
sits on `vendor-gcc` and was never merged.

Branch **`gcc16`** of haiku-pi/buildtools (from our `master` fc2ad25b8b), three commits on the first-parent line:

| Commit | What |
|---|---|
| 8e22ad83b6 | merge of Gerrit 12071 (and so 12070): GCC 15.3.0 with Haiku's changes. Our four commits merged without conflicts |
| 6227c9db48 | merge of branch **`vendor-gcc16`** = 057a6fc10a "import gcc 16.2.0" on top of upstream's vendor-gcc (d7a7951064): the release tarball (sha256 e6738e29…085c3e, GPG signature checked), added the way the earlier imports were (gitignored files such as new `.info` files stay out). Five conflicts: `gcc/configure.ac` (whitespace only on Haiku's side; take 16's), `libatomic/configure.ac` (keep Haiku's "try without `-pthread`" check, adapted to 16 renaming `save_CFLAGS`), `libstdc++-v3/configure.host` (amdgcn case moved), and `gcc/configure`, `libatomic/configure` regenerated with Autoconf 2.69 — the version GCC uses; it reproduces 16.2's pristine scripts byte for byte |
| 4883922086 | libgcc: the arm64 Haiku target now sets `md_unwind_def_header=aarch64/aarch64-unwind-def.h`, as every other AArch64 target: GCC 16's unwinder keeps the pointer-authentication key in an arch-specific frame state that only exists with it (unwind-dw2.c failed to build); the stub fallback-frame handler's unused parameters marked |

The bundled gmp 6.2.1, mpfr 4.1.0, mpc 1.2.1 and isl 0.24 stay: they meet GCC 16's minimums, and the earlier
imports never updated them either.

**Binutils stays at 2.46.1** for this step. 2.47 exists, but GCC 16.2 does not need it, our
`-z pack-relative-relocs` commit sits on 2.46.1, and changing the compiler and the linker in one step would make
any regression on the Pi unattributable. Moving to 2.47 is a separate, later step (PLAN.md asks for binutils' newest
release; it gets its own A/B).

## Build status (host, 11-01)

- Cross tools: `configure --build-cross-tools arm64 --cross-tools-source <gcc16 worktree>` in a separate output
  directory builds binutils 2.46.1 + `aarch64-unknown-haiku-gcc (GCC) 16.2.0` with libgcc, libstdc++ and libsupc++
  (~6 min under heavy-build.sh). No Haiku-specific warnings in the build.
- libstdc++ tries to build the C++ module `std` (`import std;`); for Haiku it fails on 24 long double functions
  (`acosl` …) that `<cmath>` does not declare (libstdc++'s cross configuration for Haiku has no `HAVE_*L` math
  macros; the same with 13.3) and is left out — harmless today, needs `crossconfig.m4` work before `import std`.
- `c++config.h` against 13.3: six more features detected (`fwrite_unlocked`, `lseek`, `O_NONBLOCK`,
  `<sys/mman.h>`, `<stacktrace>`, C99 `float_t`), all present in Haiku.
- New defaults: C is **gnu23** (was gnu17 in 13; already so in GCC 15, which upstream Haiku has been fixing for
  since October), **C++ is gnu++20** (was gnu++17 in 13 and 15 — this is GCC 16's own change, and the source of
  most of the fallout below). Haiku's jam passes no `-std=` for either.

## Compiling Haiku with it (`@minimum-mmc`, haiku rpi4 9cb5647ea4)

An A/B over the same tree and packages: a baseline output directory configured with today's 13.3 tools
(`--cross-tools-prefix`), and the 16.2 one. For a fair 16.2 run the extracted `gcc_syslibs_devel` headers in its
output directory were swapped for 16.2's (`c++`, `gcc/include`): Haiku compiles with `-nostdinc` against the
**package's** gcc and libstdc++ headers, which are 13.3's until gcc_syslibs is rebuilt. Static libraries (libgcc,
libgcc-kernel, libsupc++) stay 13.3's in this step.

- 13.3 baseline: 9929 targets, image built, 2529 warnings.
- **16.2 as is: 430 compiles fail** (416 C++, 14 C), 1090 targets skipped behind them. Errors, all in
  `-Werror` directories (warnings elsewhere):

| New diagnostic | Count / where | Cause | Simplest fix |
|---|---|---|---|
| `-Wnon-c-typedef-for-linkage` | `headers/os/kernel/elf.h` (8 structs with member functions, included by libroot and the kernel: most failures), `headers/os/drivers/usb/USB_video.h`, `mmc_disk.h` | new in GCC 16, on by default in every C++ mode: `typedef struct { … member functions … } X;` | name the structs (`typedef struct Elf32_Ehdr {`: same mangled name, ABI-neutral), or `-Wno-non-c-typedef-for-linkage` for GCC as jam already does for Clang |
| `-Wdeprecated-enum-float-conversion`, `-Wdeprecated-enum-enum-conversion` | agg headers (app_server, Icon-O-Matic), tracker, package kit, `ProtocolUtilities.h`, `find_directory.cpp`, kernel | C++20 | pin `-std=gnu++17` |
| `-Wvolatile` | `bfs.h`, `yarrow_rng.cpp`, `VirtioDevice.cpp` | C++20 (`++`/`--` on volatile) | C++17 or rewrite |
| `-Wdeprecated` | `VMSAv8TranslationMap.cpp` (arm64 kernel, 6×) | C++20 implicit `this` capture by `[=]` | C++17, or `[=, this]` |
| "C++20 says that these are ambiguous" (`-Werror`) | nfs4 `RPCServer.cpp`, debugger `SourceView.cpp`, network prefs `InterfaceView.cpp` | C++20 rewritten comparison operators | C++17 or const `operator==` |
| hard errors | pci `pci_device.cpp`/`pci_module.cpp`, `usb_rndis/Driver.cpp` (mixed designated initialisers), debugger `VariablesView.cpp` (ambiguous `operator==`), libsolv (`requires` is a C++20 keyword) | C++20 | C++17 |
| `-Wold-style-definition` | the boot loader's zlib 1.2.13 (`zlib_source` build package, K&R definitions, 14 objects) | C23 default (as GCC 15) | `-std=gnu17` for that zlib, or a newer zlib_source |
| `-Wmaybe-uninitialized` | filetypes `ApplicationTypeWindow`, `ApplicationTypesWindow`, `FileTypesWindow` | calling the const member `_Frame()` in the base-class initialiser, before `*this` exists | make `_Frame()` static |

- **With `-std=gnu++17` for C++** (a compiler wrapper, no source change) all C++20 errors disappear; left are
  only the linkage typedefs, the loader's zlib and the three filetypes windows. With those three made non-fatal as
  well, **`@minimum-mmc` builds completely** (kernel, loader, libroot, servers, kits, apps) and that image **boots to
  the Tracker/Deskbar desktop in QEMU virt** (`scripts/qemu-virt.sh`, 120 s; the only runtime_loader complaint,
  desklink's missing libmedia, is the minimum profile's, seen since 10-17). Not yet on the Pi.
- New warnings (non-fatal): `-Wunused-local-typedefs` ×372 and a `-Wsign-compare`/`-Woverloaded-virtual` from
  libstdc++ 16's own headers (Haiku includes them with `-I`, not `-isystem`, so their warnings show);
  `-Wold-style-definition` in C files outside `-Werror` (pcnet, ftpd/iflib md5c, telnet, `fbsd_if_media.c`, libsolv
  `qsort_r.c`); `'SIZE_MAX'`/`'UINT8_MAX'` … redefined (headers/posix/stdint.h after flex's `rc` lexer); one
  `-Warray-bounds` in `headers/private/kernel/string.h`. `-Wunused-but-set-variable` became
  `-Wunused-but-set-variable=` (levels) — same findings under a new name. Several older warnings disappeared
  (sign-compare −144, missing-prototypes −76 …), but that run built only 6952 + 430 of 9929 targets, so the
  warning counts are not comparable; only the error rows are.

So the source work for 16.2 is small: decide C++17-vs-C++20 for Haiku (recommended: pin `-std=gnu++17` in
`build/jam/ArchitectureRules` for GCC now, like 13/15 behaved, and move to C++20 deliberately later), name the
`elf.h`/`USB_video.h`/`mmc_disk.h` structs, `-std=gnu17` for the loader's zlib, a static `_Frame()`.

## Step 2 (11-01): Haiku fixes, gcc_syslibs 16.2.0, the regular GL image

All on side branches; the main build (`sources/haiku` `rpi4`, `generated.arm64`, 13.3) is untouched.

**Haiku, branch `gcc16`** of haiku-pi/haiku (pushed; from `rpi4` 7c2be9652e, a worktree, not the shared checkout):

| Commit | What |
|---|---|
| 3c641a2b01 | build: `-std=gnu++17` for GCC C++ in `ArchitectureRules` (`HAIKU_C++FLAGS_<arch>`, so kernel and boot loader too; not Clang, not gcc2). Per-directory `-std=gnu++11` (libroot arch, libsolv) still wins where set |
| 2d0aac976e | headers: tags for the typedef'd structs with member functions (`Elf32/64_Ehdr/Phdr/Sym/Rel`, four `USB_video.h` descriptors, `mmc_disk_driver_info`), as `Elf32_Rela` had; same linkage name, ABI unchanged |
| f21e11d138 | kernel, boot: zlib 1.2.13 (K&R definitions) as `-std=gnu17` — the **kernel's** `kernel_libz.a` failed too, not only the boot loader's (step 1's `-Wno-error` hid it) |
| 29a820de6e | FileTypes: the three windows' `_Frame()` static (it was called in the `BWindow` initialiser on an unconstructed object) |
| d2fd8ddf8b | arm64 repository: `gcc_syslibs` / `gcc_syslibs_devel` `16.2.0_2026_11_01-1` |

All build with GCC 13.3 as well (nothing GCC-16-specific in them). With them, strict (`-Werror` as configured)
`@minimum-mmc` and then `-sHAIKU_PI_GL=1 @pi-mmc` build with 16.2, **no compiler wrappers**.

**buildtools `gcc16`** one more commit, c2213226f9 (pushed): GCC 16's `<bitset>` lost the `_GLIBCXX_HOSTED` guard around
the null check in `bitset(const CharT*)`, which calls `__throw_logic_error` — not declared freestanding; Haiku's
userlandfs **kernel** add-on (`-ffreestanding`, includes `<bitset>`) failed with `-Wtemplate-body`. Guard restored as
in 13.3's header. (The cross tools in the scratch output directory were built before it; only the package's headers,
which jam uses, have the fix — the next cross-tools build picks it up.)

**gcc_syslibs 16.2.0**: `scripts/build-gcc-syslibs.sh --full` (the 13.3 relink mode stays the default):
`--rev c2213226f9 --version 16.2.0_2026_11_01 --buildtools <gcc16 worktree> --cross-tools <16.2 cross tools>
--generated <16.2 output dir>`; ~15 min. The recipe's Canadian cross (its patchset ported:
`patches/gcc_syslibs/gcc-16.2.0_2026_11_01.patchset`, the same two one-liners), building libgcc (+ `libgcc_s`),
libstdc++, libsupc++, libatomic, libgomp, libssp, then the kernel (`-D_KERNEL_MODE`) and boot variants of
libgcc/libgcc_eh/libsupc++ (gthr-single, no TLS: 0 TLS symbols, 0 pthread references, as 13.3's), GCC's
`include`/`include-fixed` and the C++ headers; libstdc++ relinked with `-Bsymbolic-functions` as our 13.3 one, both
`.hash` and `.gnu.hash`. Two GCC 16 traps in the native-compiler part it must build first: gcc's configure picked
`-fno-PIE`/`-no-pie` for the host programs, which cannot link on Haiku (every executable is linked `-shared`) —
`gcc_cv_c_no_fpie=no gcc_cv_no_pie=no`; and GCC 16's diagnostics code calls `socket()` (SARIF sink), which on Haiku is
in libnetwork — `LDFLAGS=-lnetwork`. Both matter again for the native compiler package (H18).

- **libstdc++.so.6.0.36** (not .35): 6085 exports, all 6003 of 13.3's 6.0.32 still there (name@version); libgcc_s
  170 ⊇ 152; SONAME and NEEDED unchanged.
- Packages (also in `artifacts/gcc-syslibs/16.2/` with the logs): `gcc_syslibs-16.2.0_2026_11_01-1-arm64.hpkg`
  (6.3 MB), `gcc_syslibs_devel-16.2.0_2026_11_01-1-arm64.hpkg` (9.0 MB), the same file list and provides as
  13.3's. Not in `artifacts/packages`, not published.

**Image** (`-sHAIKU_PI_GL=1 @pi-mmc`, clean `objects/haiku`, 16.2 + the new packages): builds, rc 0; the same
`AddHaikuImagePackages ... not available` list as a 13.3 build. Every kit/app is 16.2-compiled (`GCC: (GNU) 16.2.0`);
none of the 510 ELF files in haiku.hpkg needs a symbol version newer than 13.3's (`GLIBCXX_3.4.32`); 13.3-built
packages (Mesa, Firefox, …) run against 6.0.36, a superset. Warnings, unique file:line:warning on target code, against the 13.3 build
of the same profile on 10-28: **1582 → 1865** (+450 new, −167 gone): `-Wold-style-definition` +304 (K&R C: 252 in
libroot's POSIX layer, 31 in kernel drivers, the FreeBSD compat, ftpd, telnet, netresolv — C23 default; warnings
only), `-Wunused-but-set-variable=` +84 / −29 (renamed, and finds more), the rest a wash (line drift between the trees); plus `-Wunused-local-typedefs` from libstdc++ 16's
`stl_algo.h` on every includer (Haiku passes the C++ headers with `-I`, not `-isystem`).

**QEMU virt** (that image + `tools/pi-tests/gcc-syslibs.sh` as UserBootscript, `cxxrt`/`launchtime` built with 16.2):
gcc_syslibs 16.2 active; `cxxrt` and `cxxrt-rootfirst` ok; Tracker, Deskbar, Terminal load libstdc++.so.6.0.36;
Terminal, StyledEdit, MediaPlayer, ShowImage, DeskCalc, Debugger each open 3 windows; **GLTeapot runs 30 s**
(13.3-built Mesa/GLU against the 16.2 libstdc++); desktop on the screenshot; 3 debugger syslog lines, as the 13.3
A run on 10-28.

## Step 3 (11-02): a complete 16.2 build in a parallel tree

So that the main build (13.3) keeps working while the packages are rebuilt, step 3 ran in a **second checkout**,
`/home/houp/haiku-rpi-gcc16` on the build host (every script finds its paths from its own location, so nothing in
them changed for that):

| Path | What |
|---|---|
| `.` | worktree of this repository, branch **`gcc16-build`** (pushed); `local.conf` copied (the shared heavy-build lock, the game data) |
| `sources/haiku` | worktree, branch **`gcc16-build`** (pushed) = `origin/rpi4` f593b2ae43 (the release-image-2026-11-02 commit, which has the four source fixes) + de1a4a439d, the cherry-picked repository bump (gcc_syslibs 16.2.0) — all `gcc16` has that `rpi4` lacks |
| `sources/buildtools` | the step 1–2 `gcc16` worktree moved here (c2213226f9) |
| `sources/{mesa,libdrm,libglvnd}` | worktrees, branches `gcc16-build` at the main tree's commits (f64c84cae9, bd858a245b, 7cc03c3236); not changed, not pushed |
| `sources/haikuports`, `sources/u-boot` | detached worktrees at c17ec5a8d2 / 8d534cec; the recipes' `download/` tarballs copied; `u-boot.bin` copied from the main tree (built there with patches 0001–0004) |
| `generated.arm64` | new: `configure --build-cross-tools arm64 --cross-tools-source ../../buildtools` (so the cross tools have the `<bitset>` fix); `download/` copied from the main tree with the 13.3 gcc_syslibs removed and the two 16.2 hpkgs added |
| `artifacts/` | `packages/` copied (and rebuilt in place, same names and revisions); `downloads/`, `cross-ports/dl/` hard-linked; `pi-firmware`, `wifi-firmware`, `wine-11.20`, `wine-games` symbolic links (read-only inputs of the image scripts) |

Nothing was written into the main tree's `sources/` or `artifacts/`. The step 1–2 scratch output directory's build output was deleted (its logs stay in the agent job's scratch directory) and its buildtools worktree moved here: for a later `build-gcc-syslibs.sh --full`, use `--buildtools`, `--cross-tools` and `--generated` of this tree instead. Packages keep their names and revisions
(e.g. `mesa-26.2.6-1`): they are never published from this tree, and which compiler built a file is in its
`.comment` (`GCC: (GNU) 16.2.0`), checked for every package below. The bumps belong to the switch of the main build.

**Rebuilt with 16.2** (all ELF files of each package `GCC: (GNU) 16.2.0`; packages in `artifacts/packages/` of that
tree, staged in its `download/`):

- Haiku itself, `-sHAIKU_PI_GL=1 @pi-mmc`: clean `objects`, rc 0, the same `not available` list as 13.3 (11
  packages), 3834 warning lines. A clean build prints 11 `fatal error: jpeglib.h/png.h/avif.h/webp/encode.h: No such
  file` lines from the translators' catalog-key extraction (step 2's first clean build had the same; incremental
  builds none): not compiles, no `...failed`.
- `build-packages.sh --no-webkit` (new option, below), then `build-webkit.sh webkit_source`: the GL stack (libdrm,
  libglvnd, Mesa 26.2.6 with V3D/V3DV, the Vulkan loader, the GL tests; mesa/mesa_devel 26.2.6-1, glu/glu_devel
  9.0.3-6 via `package-gl-stack.sh --glu-revision 6`), libogg, libvorbis, fluidlite, libsdl2 2.32.10-5, ffmpeg6 6.1.6-3,
  zstd, gzip, tar, bzip2, unzip, the NetSurf set (libiconv, libpng16, libjpeg_turbo, libutf8proc, OpenSSL 3.5.9, curl,
  the ns* libraries, netsurf), ICU 74.1, the WebKit libraries (libexecinfo, sqlite 3.53.4, libxml2, libxslt, lcms,
  brotli, woff2, libwebp, dav1d, libavif, libpsl), **HaikuWebKit 1.10.0** (~45 min, 1556 warning lines), ncurses6,
  libedit, **python3.14 3.14.8-2**, nano, libpcre2, wget, lz4, xxhash, rsync, vim, openssh, git, htop_rivoreo.
- Games: `build-games.sh` (SDL2, QuakeSpasm, Yamagi Quake II, vkQuake, ioquake3 for OpenArena and the Quake III demo,
  sdlvk), `build-stk.sh` and `build-stk.sh --no-data --gles`, `package-games.sh` (supertuxkart 1.5-2 and openarena
  0.8.8-4, their data packages kept), `build-glmark2.sh --package` (glmark2 2023.01-2). No game needed a change.
- Compiler warnings per port about as with 13.3 (ffmpeg 140 → 176, QuakeSpasm 2 → 4, ioquake3 14 → 12, Python 10 →
  6, NetSurf 614 → 628, ICU 4171 → 4134; SDL2, vkQuake, STK's own 0).

**Per-port fixes** (coordination repository, branch `gcc16-build`; all harmless with 13.3):

| Commit | Port | GCC 16 change | Fix |
|---|---|---|---|
| 37a7416, 5c5b129 | unzip 6.10c23 | C23 default: `struct tm *gmtime(), *localtime();` conflicts with `<time.h>`; implicit `utime()` (an error since GCC 14) | `-std=gnu17`, `-DHAVE_UTIME_H` |
| acbd335 | NetSurf 3.11 (BeOS front end) | C++20 default: `(char *)&nsbeos_find_app_path < …` parses as a template argument list | the front end as `-std=gnu++17` |
| 840f9fa | rsync 3.2.7, htop_rivoreo 2.3.1 | C23: K&R comparators / a key-handler table declared with `()` are `(void)` prototypes; qsort and calls with arguments rejected | `-std=gnu17` |

Not GCC-specific, found because the tree was new: `haiku-sysroot.sh` failed on a fresh sysroot (ec310ca: the ncurses6
bootstrap package's `form.pc` … are symbolic links that dangle in the sysroot and `sed -i` stopped on them);
`build-webkit.sh`'s `icu74` step extracted the ICU bootstrap packages, which `download/` no longer has since our
`build-icu.sh` replaced them (4e1bc6d: it takes ours, and `build-packages.sh` builds ICU before WebKit);
`build-packages.sh` builds correctly only on a fresh sysroot (`--sysroot`): a second run finds the first run's
libiconv and tar's configure takes its `iconv.h` without linking it. New options (14993fd): `build-packages.sh
--no-webkit` (the WebKit libraries, not WebKit) and `build-webkit.sh [STEP [LAST]]`. The main tree's copies of these
scripts are unchanged (another session builds with them); merge `gcc16-build` when the main build switches.

**Not rebuilt** (13.3-built packages copied from the main tree; they run on the 16.2 runtime, which keeps every
6.0.32 symbol): Firefox 157.0.1-5 (needs the Rust toolchain and ~22 GB), Wine 11.21-2 with wine_data/directx/x86/
x86_64 and wine_mono (5.5 GB tree), wayland, wayland_server, libxkbcommon, photocraft, the Python extension modules
(`build-python-modules.sh`). The **mega image** was not made: `build-mega-image.sh --size 12000` needs 24 GB free next
to its output, and the host had 25 GB with 12 GB to keep.

**Images** (that tree's `artifacts/images/`):

- `haiku-pi4-regular.img` — the regular GL image, everything above inside (WebKit included), 1 086 324 736 bytes, sha256
  cc535e84…
- `gb-gcc16.img` — the comparison image: the regular GL image at `-sHAIKU_IMAGE_SIZE=3500` (the 1.09 GB one has no room
  for the games, Wine and a Wine prefix), then `games-bench-image.sh` (the 16.2 game trees, supertuxkart 1.5-2, Wine
  11.21-2, the Half-Life Uplink tree, UserBootscript `games-bench.sh`) plus glmark2 2023.01-2 and step 2's `launchtime`,
  `cxxrt`, `cxxrt-rootfirst` in `/boot/home`; 3 707 764 736 bytes (sparse, 1.3 GB on disk), sha256 596dc6b9…

**QEMU virt** (`qemu-virt.sh`): the regular image with the games tree and a smoke UserBootscript: desktop up, Tracker
and Deskbar on libstdc++.so.6.0.36, **GLTeapot runs 30 s** (16.2 Mesa/GLU), **QuakeSpasm** plays demo1 (softpipe),
`python3.14` 3.14.8 with sqlite 3.53.4 and OpenSSL 3.5.9 imports and queries, glmark2/glmark2-es2 (16.2) score
scenes on softpipe (with `--data-path` for the test tree: without it the 13.3 build fails the same way), no
debugger entries. `gb-gcc16.img` boots to the desktop and games-bench.sh starts QuakeSpasm. Not on the Pi (the
main session runs the bench).

## Next steps

1. ~~Haiku source fixes~~ — done (step 2), branch `gcc16`.
2. ~~gcc_syslibs and gcc_syslibs_devel 16.2.0~~ — done (step 2).
3. **Switch the main build** (one session, when the bench and the main build allow; ~1 h of builds; step 3 above did
   all of it in a parallel tree, with the per-port fixes on the coordination branch `gcc16-build` to merge first). Order
   matters: haiku d2fd8ddf8b makes the build need the 16.2 packages and tools, so **do not merge `gcc16` into
   `rpi4` before (1) and (2) are done** (the four source fixes, 3c641a2b01..29a820de6e, are safe on their own and
   can be cherry-picked any time):
   1. both 16.2 hpkgs into `generated.arm64/download/` (and into `artifacts/packages/`, moving 13.3's
      `gcc_syslibs-…bootstrap-2` out: publish-repo.sh allows one revision);
   2. `sources/buildtools` → branch `gcc16` (c2213226f9 or later), keeping the 13.3 tools: rename
      `generated.arm64/cross-tools-arm64` → `cross-tools-arm64-gcc13` (or tag `gcc13-baseline`), then
      `configure --build-cross-tools arm64 --cross-tools-source ../../buildtools -j12` in `generated.arm64`
      (~10 min; these cross tools then also have the `<bitset>` fix — the scratch ones of step 1 do not);
   3. merge haiku `gcc16` into `rpi4`, push; a clean `objects/haiku`; `scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc`;
      grep the log for `not available` (only the 13.3 list);
   4. `scripts/haiku-sysroot.sh` — it takes the newest `gcc_syslibs*` in the download directory, so the sysroot
      gets 16.2's libstdc++ and headers; recreate it before any port build.
4. **Rebuild our packages** with 16.2 against that sysroot, each a revision bump (three parts): the GL stack first
   (`scripts/build-gl-stack.sh --sysroot` + `package-gl-stack.sh`: libdrm, libglvnd, Mesa, GLU), then
   `scripts/build-packages.sh` (SDL2, ffmpeg6, libogg/vorbis, fluidlite, zstd, base ports, NetSurf + OpenSSL/curl,
   libedit, Python, ICU, ncurses, the pkgman ports), `build-webkit.sh` (hours), `build-firefox.sh`,
   `build-games.sh` + `build-stk.sh` + `build-vkquake.sh` + `build-q3.sh` + `package-games.sh`, `build-wine.sh`,
   `build-python-modules.sh`, `build-rust.sh`, `build-photocraft.sh`,
   `build-spidermonkey.sh`, `build-llama2.sh`; then `build-mega-image.sh`. Mesa and WebKit/Firefox are where C++20/
   GCC 16 source breakage is likely (they choose their own `-std`); fix per port in its patches/.
5. **Pi gates** equal to 13.3's: boot bench, gpu-it, mega-smoke (scripts/sd-cycle.sh, the bench lock), plus
   `tools/pi-tests/gcc-syslibs.sh` (now version-independent, with a GLTeapot check) on the regular image.
6. **Native compiler package** (H18): the HaikuPorts gcc recipe ported to 16.2 (its libsanitizer patches) — so
   the native compiler is built once, on the new version. It needs the two host traps above
   (`gcc_cv_*_pie=no`, `-lnetwork`) and replaces the `gcc-13.3.0…bootstrap-1` the dev images (`HAIKU_PI_DEV`)
   carry: it requires only `haiku` and has its own 13.3 C++ headers, so on a 16.2 image it keeps working (its
   programs link against libstdc++ 6.0.36, a superset), but the on-device compiler stays 13.3 until then.
7. **Binutils 2.47**, its own A/B, after 5.
8. **Performance comparison** (below; its images exist since step 3, the Pi runs are the main session's).

### The weekly upstream merge from now on

`gcc16` shares its history with upstream: the vendor imports (8465a824ae, d7a7951064) and Gerrit 12070's merge
(a69c732e). The weekly sync merges `upstream/master` into our `master` as today and then `master` into `gcc16`.
While upstream stays on 13.3/15.3, upstream changes outside `gcc/` merge cleanly. When upstream lands 12070 with the
same SHA, nothing re-conflicts; if Gerrit lands another patch set (a rebase), only the files that set touches in
`gcc/` re-conflict — resolve them to `gcc16`'s side. When upstream imports a GCC 16 release, we merge its
`vendor-gcc` and keep ours where the imports agree. Our `vendor-gcc16` branch is separate from `origin/vendor-gcc`,
which keeps mirroring upstream (fast-forward only). Once `gcc16` is the build's toolchain it becomes the fork's
working branch and `master` keeps mirroring upstream plus our four commits.

### The 13.3 baseline stays reproducible

Do not delete or overwrite it. The 13.3 toolchain is `sources/haiku/generated.arm64/cross-tools-arm64`, built from
buildtools `fc2ad25b8b` (branch `master`); the image that goes with it is release 2026-10-31
(`manifests/2026-10-31-release-image-2026-10-31.md`: haiku 821aaf239d, every repository's SHA) and its packages in
`artifacts/packages/`. To rebuild it: check out the manifest's SHAs (there is no restore script yet),
`configure --build-cross-tools arm64 --cross-tools-source <buildtools at fc2ad25b8b>`, and the 13.3 gcc_syslibs
packages kept in the download directory and `artifacts/gcc-syslibs/`. When switching the main build to 16.2, keep a
`generated.arm64-gcc13` (or the tag `gcc13-baseline` in buildtools and haiku) so step 8 can rebuild both fresh.

## Performance comparison (last step)

Owner, 11-01: the migration ends, once the image, the packages and the games are rebuilt with 16.2 and pass the
gates, with a GCC 13.3 vs 16.2 comparison on the same Pi and the same scenes. **Both builds are measured fresh in
one series** (alternating, same card, same cooling, same firmware and settings; three runs each, median reported),
not against old numbers.

**The two images** (same Haiku commit f593b2ae43, same profile, size and test content; only the compiler differs):

- 16.2: `/home/houp/haiku-rpi-gcc16/artifacts/images/gb-gcc16.img` (step 3).
- 13.3: made in the main tree, at haiku `rpi4` f593b2ae43 (release-image-2026-11-02; if `rpi4` has moved on, build the
  16.2 image again from the same commit instead), with the same commands:

  ```
  PI_IMAGE_OUT=artifacts/images/gcc13-regular-3500.img scripts/build.sh -sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=3500 @pi-mmc
  S=artifacts/gcc-syslibs/16.2
  scripts/games-bench-image.sh artifacts/images/gcc13-regular-3500.img artifacts/images/gb-gcc13.img \
      artifacts/packages/glmark2-2023.01-2-arm64.hpkg:/boot/system/packages/glmark2-2023.01-2-arm64.hpkg \
      $S/launchtime:/boot/home/launchtime $S/cxxrt:/boot/home/cxxrt $S/cxxrt-rootfirst:/boot/home/cxxrt-rootfirst
  rm artifacts/images/gcc13-regular-3500.img
  ```

  (the main tree's game trees (10-29) and SuperTuxKart package (10-21) were built from the scripts and patches as they are now — no commit to `build-games.sh`, `build-q3.sh`, `build-vkquake.sh`, `build-stk.sh`, `patches/libsdl2`, `patches/yquake2` since — so both sides have the same game sources; the same `launchtime` binary on both; Wine is 11.21-2 on both — if the main tree's Wine changes, copy the new
  packages into the gcc16 tree's `artifacts/packages` and remake `gb-gcc16.img` the same way).

**Runs**, from the main tree, alternating 13 → 16 → 13 → 16 → 13 → 16 (thermal drift cancels), network boot (each boot
a fresh copy of the image: cold shader cache and a new Wine prefix every time, on both):

| Workload | Command (IMG = either image; one label per run) | Read with |
|---|---|---|
| Games: QuakeSpasm, vkQuake, Yamagi Quake II (timedemos), Quake III demo, OpenArena (timedemo), SuperTuxKart (60 s race), Wine gltest/d3dtest, Half-Life Uplink | `scripts/netboot-cycle.sh --image IMG --secs 2400 --until 'GB end' --retry-wedge --label gb13-1` (~25 min) | `scripts/games-bench-table.py --a gcc13 <gb13 logs> --b gcc16 <gb16 logs>` |
| glmark2-es2 (window + full screen) | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/glmark2.sh --secs 1200 --until 'GM2 end' --label gm2-13-1` | the `GM2 … Score` lines |
| App launch times (Terminal, StyledEdit, MediaPlayer, ShowImage, DeskCalc, Debugger, 3 each), the C++ runtime, GLTeapot | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/gcc-syslibs.sh --secs 600 --until 'CXXRT end' --label lt13-1` | `CXXRT launch …: window N ms` |
| Python 3.14 + sqlite: start-up, `benchmark` (sum, loop, sort), sqlite3, hashlib, zlib … | `scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/python.sh --secs 600 --until 'PY end' --label py13-1` | `PY startup-*`, `PY benchmark` |
| Boot time (SD, the real path) | `scripts/sd-cycle.sh --flash IMG --secs 120 --label boot13-1`, then twice `scripts/sd-cycle.sh --secs 120 --label boot13-2` (warm) per image | `scripts/boot-times.sh artifacts/uart/*-boot13-*.log` (loader → kernel → boot volume → cursor) |

Afterwards restore the card's usual image (the SD card holds what the main session last put on it).

| Workload | Measure | GCC 13.3 | GCC 16.2 | Δ |
|---|---|---|---|---|
| QuakeSpasm timedemo (demo1) | fps | | | |
| Yamagi Quake II timedemo | fps | | | |
| vkQuake timedemo | fps | | | |
| OpenArena timedemo | fps | | | |
| SuperTuxKart (fixed race / benchmark mode) | fps | | | |
| glmark2 | score | | | |
| Boot time (power-on → desktop) | s | | | |
| Firefox start (cold, to first page) | s | | | |
| A Wine game (same scene) | fps | | | |
| CPU microbenchmarks (string/memory routines, a compile, compression, sorting) | time / MB/s | | | |

Results go here and into [HARDWARE-SUPPORT.md](../HARDWARE-SUPPORT.md).

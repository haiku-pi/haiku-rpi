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

Generated `configure` scripts carry the matching hunks. Ours (haiku-pi fork) adds four arm64 commits on top:
libgcc_s linked as needed (85273c9ba6), `REAL_LIBGCC_SPEC` for a `--disable-shared` compiler (393b4ec7a4),
`--hash-style=both` by default (fc2ad25b8b), and in binutils `-z pack-relative-relocs` (1cad3a62fa).

## How it was ported

Upstream already did half of it: Jérôme Duval imported **GCC 15.3.0** onto `vendor-gcc` (8465a824ae, 10-11) and
proposed the merge with Haiku's changes as Gerrit change **12070** (a69c732e, merge of master 33d46bf5c3 and
vendor-gcc d7a7951064) plus **12071** (662fd8ac, `haiku.opt.urls`); both still under review on 11-01.
HaikuPorts' `sys-devel/gcc` 15.3.0 recipe (pinned haikuports c17ec5a8d2f0) carries the same change as the first
patch of its patchset ("Modifications for GCC 15.3.0 for Haiku (from buildtools repository)") plus seven
libsanitizer/c++tools patches for the native compiler package; it confirmed the delta but the buildtools merge
itself was the better base (it has history). No GCC 14/16 work exists upstream.

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
  (sign-compare −144, missing-prototypes −76 …), partly because the failed objects never compiled.

So the source work for 16.2 is small: decide C++17-vs-C++20 for Haiku (recommended: pin `-std=gnu++17` in
`build/jam/ArchitectureRules` for GCC now, like 13/15 behaved, and move to C++20 deliberately later), name the
`elf.h`/`USB_video.h`/`mmc_disk.h` structs, `-std=gnu17` for the loader's zlib, a static `_Frame()`.

## Next steps

1. **Haiku source fixes** (sources/haiku `rpi4`, small commits in Haiku style): the four items above. Upstream may
   want the same once it reaches GCC 16; keep them upstreamable.
2. **gcc_syslibs and gcc_syslibs_devel 16.2.0** — blocking for any image meant to run: Haiku links against the
   package's libstdc++.so/libgcc_s.so and compiles against its headers, and binaries built with 16.2's headers need
   its newer `GLIBCXX_*`/`CXXABI_*` symbols at run time (libstdc++.so.6.0.32 → 6.0.35). Extend
   `scripts/build-gcc-syslibs.sh` (today: a 13.3 rebuild of only two libraries) to a full Canadian cross of the
   gcc16 branch, as haikuports.cross's `gcc_bootstrap` recipe does, producing both packages including the kernel and
   boot variants of libgcc/libsupc++ (`libgcc-kernel.a`, `libsupc++-boot.a` …); version e.g. `16.2.0_2026_11_01`.
   Then update `build/jam/repositories/HaikuPorts/arm64` and the download directory (AGENTS.md: three-part bump).
3. **Switch the main build**: `scripts/bootstrap.sh` builds from `sources/buildtools` — move that clone (or the fork's
   default branch) to `gcc16` once 1-2 work; reconfigure `generated.arm64` (one-time, ~10 min). Full `@pi-mmc` /
   mega image build; record the warning delta.
4. **Rebuild our packages** with 16.2 (Mesa + GL stack, libdrm, libglvnd, SDL2, ffmpeg, the games, Firefox,
   WebKit, Wine, Python, …: `scripts/build-packages.sh` and friends), each a revision bump.
5. **Pi gates** equal to 13.3's: boot bench, gpu-it, mega-smoke (scripts/sd-cycle.sh, the bench lock).
6. **Native compiler package** (H18): the HaikuPorts gcc recipe ported to 16.2 (its libsanitizer patches) — so
   the native compiler is built once, on the new version.
7. **Binutils 2.47**, its own A/B, after 5.
8. **Performance comparison** (below).

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

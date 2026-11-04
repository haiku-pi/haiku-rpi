# Native GCC 16.2 for Haiku arm64 (H18, part 2)

The compiler that runs **on** the Pi and compiles for it: `gcc`, `g++`, `gfortran` 16.2.0, the same release and the
same source tree (buildtools `gcc16` c2213226f9) as the cross tools of the main build and the `gcc_syslibs` 16.2.0
runtime. Part 1 (make, CMake, Ninja, binutils 2.46.1, meson, pip …) is [dev-tools.md](dev-tools.md); the toolchain
switch is [gcc16.md](gcc16.md) ("Next steps" 6 is this). It replaces the `gcc-13.3.0_2026_03_29_bootstrap-1`
package of the development image.

## Result (2026-11-03)

| package (artifacts/packages/) | size | what |
|---|---|---|
| `gcc-16.2.0_2026_11_01-1-arm64.hpkg` | 88.2 MB | drivers (`gcc`, `g++`, `c++`, `cc`, `cpp`, `gcc-ar/nm/ranlib`, `gcov`, `gcov-dump`, `gcov-tool`, `lto-dump`, `aarch64-unknown-haiku-*`), `cc1`, `cc1plus`, `lto1`, `collect2`, `lto-wrapper`, the LTO plugin, `g++-mapper-server` (C++ modules); GCC's headers and libstdc++'s C++ headers, crt files, `libgcc.a`, `libgcc_eh.a`, `libgcov.a`, `libatomic.a`, `libstdc++exp.a`, `libgomp.spec`; man pages |
| `gcc_fortran-16.2.0_2026_11_01-1-arm64.hpkg` | 21.3 MB | `gfortran`, `f951`, the intrinsic modules (`finclude`), `libgfortran.so.5.0.0` (+ static), `libcaf_single.a`, `libcaf_shmem.a` |

**Published 2026-11-03** in our package repository (Pi check below: 24 of 24); not in an image. Build: `scripts/build-native-gcc.sh` (~20 min on the host; its last step `clean` deletes the work directory: the cross gfortran ~5,
configure ~3, the build ~7 under heavy-build.sh at 13 jobs, packaging and checks ~3; work directory 3.6 GB,
`artifacts/native-gcc-build`; the logs are kept in `artifacts/native-gcc/`). 45 compiler warning lines in the build, none Haiku-specific.

**provides** (as HaikuPorts' `sys-devel/gcc`): `gcc`, `cmd:c++`, `cmd:cc`, `cmd:cpp`, `cmd:g++`, `cmd:gcc`, `cmd:gcc_ar`,
`cmd:gcc_nm`, `cmd:gcc_ranlib`, `cmd:gcov`, `cmd:gcov_dump`, `cmd:gcov_tool`, `cmd:lto_dump` (`= 16.2.0_2026_11_01
compat >= 7`), `cmd:aarch64_unknown_haiku_gcc_16.2.0`; gcc_fortran: `gcc_fortran`, `cmd:gfortran`, `lib:libgfortran =
5.0.0`, `devel:libgfortran`, `devel:libcaf_single`.
**requires**: gcc — `haiku`, `gcc_syslibs == 16.2.0_2026_11_01` (its base package), `gcc_syslibs_devel ==
16.2.0_2026_11_01`, `binutils >= 2.46.1`; gcc_fortran — `haiku`, `gcc == 16.2.0_2026_11_01` (base), `gcc_syslibs ==
16.2.0_2026_11_01`. No `lib:libgmp`/`libmpfr`/`libmpc`/`libz`: those are linked statically (below).

## How it is built

`scripts/build-native-gcc.sh` (steps `source sysroot xfortran configure build install package check`, each resumable):

- **Source**: `git archive` of buildtools at c2213226f9 (`gcc/`, read-only; `sources/buildtools`' object store has the
  commit, its checkout is not touched) + `patches/gcc_syslibs/gcc-16.2.0_2026_11_01.patchset` (the limits.h test and
  libstdc++'s shared libgcc: the two one-liners the gcc_syslibs 16.2 build used), the recipe's `config.sub` copies.
  HaikuPorts' 15.3 patchset is the same Haiku delta (buildtools has it) plus libsanitizer and c++tools patches; this
  build has no libsanitizer, and c++tools links with `-lnetwork` from the global LDFLAGS.
- **Canadian cross** as `build-gcc-syslibs.sh --full`: build = x86_64 Linux, host = target = `aarch64-unknown-haiku`,
  the main build's 16.2 cross tools (wrappers with `--sysroot`, a plain `-lgcc` libgcc spec, the cross compiler's static
  libstdc++), a build sysroot of jam's `haiku` and `haiku_devel`. The compiler's own programs link libstdc++ and
  libgcc statically: their only NEEDED libraries are `libroot.so` and `libnetwork.so`.
- **Configure** as the recipe: `--prefix=/boot/system/develop/tools --libexecdir=…/lib --enable-threads=posix
  --enable-shared --enable-version-specific-runtime-libs --enable-lto --enable-frame-pointer --enable-__cxa-atexit
  --enable-checking=release --with-default-libstdcxx-abi=gcc4-compatible --enable-libssp --with-pkgversion=2026_11_01`,
  `--enable-languages=c,c++,fortran`. Different from the recipe, on purpose:
  - gmp 6.2.1, mpfr 4.1.0, mpc 1.2.1, isl 0.24 and zlib are the copies in the buildtools tree, static (no
    `--with-system-zlib`): no new dependency packages;
  - `--disable-libsanitizer` (the recipe's Haiku arm64 libsanitizer patches are not ported), `--disable-plugin`
    (cc1 would export every symbol), no jit, no Objective-C, `--disable-libstdcxx-pch` (libstdc++'s own `stdc++.h.gch`;
    user PCHs work);
  - GCC 16's host traps from gcc16.md step 2: `gcc_cv_c_no_fpie=no gcc_cv_no_pie=no` and `LDFLAGS=-lnetwork`.
- **Fortran**: libgfortran is compiled by a gfortran that runs on the build host; the cross tools have none, so step
  `xfortran` builds `aarch64-unknown-haiku-gfortran` (driver + f951, `make all-gcc` of the same tree; libgcc and the crt
  files are the cross tools'). It printed the first instance of a known wart (below).
- **No build-host paths**: `-ffile-prefix-map` for `__FILE__`; configure is run with a *relative* source directory, because
  gfortran's run-time error messages ("At line 59 of file …random_init.f90" in libgfortran) take the file name as given
  and ignore `-ffile-prefix-map`; `gcc -v`'s "Configured with" line (`gcc/configargs.h`) is rewritten after
  `configure-gcc` (`gcc-16.2.0/configure …`, `--with-build-sysroot=/build/sysroot/`). Programs stripped
  (`--strip-unneeded`), archives and objects `--strip-debug`.
- **Layout** as the recipe's INSTALL(): everything in `develop/tools` (the tool directory `develop/tools/aarch64-unknown-
  haiku/bin` is the binutils package's, where the driver finds `as` and `ld`), links in `/boot/system/bin`, `cc -> gcc`.
  The compiler's lib directory links the runtime's shared libraries (`libstdc++.so*`, `libgcc_s.so*`, `libatomic`,
  `libgomp`, `libssp`) to `/boot/system/lib` (gcc_syslibs 16.2), as the recipe's does; the libraries this build made
  are not shipped. GCC 16's new linker scripts `libatomic_asneeded.so`, `libgcc_s_asneeded.so` stay (and `libatomic.a`,
  which `libatomic_asneeded.a` links to). The static libraries the recipe moves to gcc_syslibs_devel (libsupc++,
  libssp_nonshared, …) are left out — gcc_syslibs_devel has them; `libstdc++exp.a` (`<stacktrace>`, contracts) stays in
  gcc, because our gcc_syslibs_devel does not have it.
- **libgfortran** is in gcc_fortran (`lib/libgfortran.so.5.0.0`, `provides lib:libgfortran`), not in gcc_syslibs as in
  HaikuPorts: our gcc_syslibs 16.2 is already published-ready without it, and a runtime rebuild for Fortran alone was
  not worth it. If gcc_syslibs ever carries it, gcc_fortran must drop it in the same step (file conflict).
- **DISABLE_ASLR**: as the recipe, `SYS:ENV DISABLE_ASLR=1` on the drivers, cc1, cc1plus, f951, lto1, collect2,
  lto-wrapper, g++-mapper-server (precompiled headers are mapped at a fixed address), set with the build tools'
  `addattr`; the stage tree is removed with `rm_attrs` afterwards, because the build's attribute emulation keys its
  entries by inode (the 10-24 stale-attribute trap, WEEK-2026-W43). The same holds for every package *extracted* on
  the host (the build sysroot, the check tree): the script deletes those with `rm_attrs -rf`, not `rm`. The first runs
  on 11-03 still used `rm` there; their 20 949 orphaned attribute directories (04:30–05:01) were moved to
  `artifacts/attributes-stale-20261103-native-gcc`. (`build-dev-tools.sh` and `build-gcc-syslibs.sh` still `rm -rf`
  their extracted trees: same leak, not fixed here.)

## Checks (host, step `check`)

The two packages extracted, with `haiku` and `gcc_syslibs` 16.2 as the system:
- all 30 programs and shared libraries (DYN): every NEEDED library is on the system (29 × `libroot.so libnetwork.so`,
  libgfortran `libroot.so`), and every undefined dynamic symbol is defined in the file's own NEEDED closure (not just
  somewhere on the system). libgfortran's two unwinder calls (`_Unwind_Backtrace`, `_Unwind_GetIPInfo`, for
  backtraces) resolve in `libgcc_s.so.1` through `libroot.so`, which needs it — as gcc_syslibs' libstdc++;
- no build-host path in any packaged file (also archives and objects);
- `cc1`/`cc1plus` present; the driver's built-in library paths `/boot/system/develop/lib/` and
  `/boot/system/non-packaged/develop/lib/`, cc1's include paths `/boot/system/develop/headers/posix` … and the C++
  headers in the compiler's directory, no sysroot;
- every requirement has a provider (our packages, the image build's download directory, haiku).

## QEMU (2026-11-03, no Pi)

`scripts/image-add.sh` on a copy of the 16.2 regular image (`artifacts/images/haiku-pi4-regular.img`, hrev60299+245):
both packages, binutils-2.46.1-1, make-4.4.1-1, cmake-4.4.5-1, ninja-1.13.2-1, jam's `haiku_devel`,
`gcc_syslibs_devel-16.2.0_2026_11_01-1` in `/boot/system/packages`, `tools/pi-tests/native-gcc.sh` as UserBootscript;
`scripts/qemu-virt.sh` (virt, cortex-a72 ×4, TCG). Result: **NGCC end 22/23** on the first run — versions (`gcc (2026_11_01)
16.2.0`), `as`/`ld` from the binutils package, library and include paths, no sysroot; C hello (`__STDC_VERSION__`
202311); C++ (gnu++20: iostream, exceptions across libgcc_s, `std::thread`, `<format>`), C++23 `std::println`; the Haiku
API (`BString`, `find_directory`, `get_system_info`, `-lbe`); **LTO** (`-flto`, the linker plugin in ld 2.46.1); OpenMP
(4 threads); a **precompiled header** used (`-H` shows `! pch.h.gch`); `-static-libgcc`; **Fortran** (gfortran program,
and C calling a `bind(c)` Fortran routine with `-lgfortran`); CMake with make and with Ninja (C + C++ project, compiler
`/bin/c++`). The failure was the test's: GCC ≥ 11 names the notes file of a one-step `--coverage` compile+link
`cov-hello.gcno`; the test now compiles separately. Second run, with the Fortran-warning check added: **NGCC end 24/24** (log `artifacts/qemu/20261103-050217-virt.log`, the image
`artifacts/images/native-gcc-qemu.img`); no debugger or crash lines in the log.

## Pi results (2026-11-03)

On the 16.2 test image (`haiku-pi4-16rc.img`, hrev60299+259) in a network session (`artifacts/native-gcc-pi/run.sh`):
`pkgman install` of both packages, gcc_syslibs_devel 16.2, the image's `haiku_devel`, binutils, make, CMake, Ninja and
the part 1 Python tools, then `native-gcc.sh`: **NGCC end 24/24** (the QEMU set: versions, paths, C, C++ 20/23, the Haiku
API, LTO, OpenMP, PCH, gcov, `-static-libgcc`, Fortran, C calling Fortran, CMake with make and Ninja) and
`dev-tools.sh` with this compiler: **DEV end 23/23**, `DEV gcc 16.2.0` (make, CMake + Ninja and Meson builds of C++
projects, `pip install` of a pure and of a Cython package compiled by gcc 16.2). Logs in `artifacts/native-gcc-pi/`.

## haikuporter on the Pi with gcc 16.2 (2026-11-04)

The last check of H18: HaikuPorts recipes built **natively on the Pi by haikuporter with the gcc 16.2 package**, not the
bootstrap 13.3 of the 10-21 runs (hoedown 37 s, gperf 52 s).

- **Image**: `PI_IMAGE_OUT=… scripts/build.sh -sHAIKU_PI_DEV=1 @minimum-mmc` (haiku b59f1c957f + `build/jam/repositories/
  HaikuPorts/arm64`: gcc 16.2.0_2026_11_01, gcc_syslibs and `_devel` 16.2, binutils 2.46.1, make 4.4.1, haikuporter 0_bootstrap,
  python3.10 bootstrap, hrev60314_261), built incrementally in about 4 min; the build log's only `not available` lines: **bc and
  wget**, as before. (`build.sh` writes an `@minimum-mmc` image as `artifacts/images/haiku-pi4.img`; `PI_IMAGE_OUT` only applies
  to `@pi-mmc`: the file was renamed to `haiku-pi4-dev16b.img`.)
- **Pi**: a network session (`scripts/pi-session.sh`, then `scripts/pi-ssh.sh`) on that image: `gcc (2026_11_01) 16.2.0`, `GNU
  assembler (GNU Binutils) 2.46.1`. Staged by `scp`: the bootstrap tools (patch, tar, gzip, xz, bzip2, diff: `build-bootstrap-tools.sh`),
  the python compression modules (`build-python-modules.sh`) and the trimmed HaikuPorts tree `artifacts/haikuports-min` (hoedown
  and gperf with their sources; the whole tree costs ~9 min of recipe parsing per port); the clock set from the host (no NTP in
  the 1970 state of a network boot); `tools/pi-tests/haikuporter-test.sh` run by hand (`HPT_OUT=- HPT_CLOCK=<epoch> sh
  haikuporter-test.sh [PORT...]`), `haikuporter -G -y -j4 --no-source-packages PORT` in haikuporter's chroot, then `pkgman install FILE`.
  Logs and packages: `artifacts/haikuporter-gcc16/`.

| recipe | result | time | package | run |
|---|---|---|---|---|
| hoedown 3.0.7 (C) | built | **53 s** | `hoedown-3.0.7-4-arm64.hpkg` 164 kB + `hoedown_devel` 4.9 kB | `echo '# Hello *Haiku* on the Pi' \| hoedown` -> `<h1>Hello <em>Haiku</em> on the Pi</h1>`; `hoedown --version` "Built with Hoedown 3.0.7" |
| gperf 3.1 (C++, one patch), recipe as HaikuPorts has it | **failed** | 32 s | none | see below |
| gperf 3.1, recipe revision 2 (`CFLAGS="-O2 -std=gnu17"`) | built | **45 s** | `gperf-3.1-2-arm64.hpkg` 204 kB | `gperf --version` "GNU gperf 3.1"; generates the C hash function for `haiku`/`pi` |

Both binaries carry `GCC: (2026_11_01) 16.2.0` in `.comment` (`readelf -p .comment`), so they were made by the new compiler. The
times are not comparable one to one with 10-21 (there an SD boot, here a network boot and ssh; hoedown +16 s, gperf -7 s): same
order, nothing slower in kind.

**GCC 16 issue, the recipe's (not ours)**: gperf 3.1's old gnulib copy `lib/getopt.c` declares `extern int strncmp ();` and
`extern int getopt ();`. GCC 15 and later compile C as **C23** (`-std=gnu23`), where an empty parameter list means `(void)`:

```
./getopt.c:611:14: error: too many arguments to function 'strncmp'; expected 0, have 3
./getopt.c:198:12: note: declared here
  198 | extern int strncmp ();
./getopt.c:927:1: error: conflicting types for 'getopt'; have 'int(int,  char * const*, const char *)'
./getopt.h:105:12: note: previous declaration of 'getopt' with type 'int(void)'
```

Any build of the unchanged recipe with GCC 15+ hits it (HaikuPorts will when its default compiler moves up); the gperf 3.1 source
is simply pre-C23. The fix is in the recipe: build the C part as C17 (`export CFLAGS="-O2 -std=gnu17"`
before `runConfigure`, revision 2). Other gcc 16 output, all warnings and none fatal: hoedown 4 (`-Wenum-int-mismatch` x3,
`-Wmisleading-indentation`), gperf 3 (`-Wregister` for the C++ `register` keyword, `-Wbuiltin-declaration-mismatch`); no C++20 default
problem (gperf compiles as gnu++20).

**Two traps found on the way (ours, fixed in the scripts)**:
- A `LIBRARY_PATH` that holds only `/boot/system/develop/lib` (what `haikuporter-test.sh` set for the bootstrap python3.10) **replaces** the
  loader's default for add-ons: once icu74 is on the image (`libroot-addon-icu.so`), every `package` command run by haikuporter
  dies with `Cannot open file libicudata.so.74 (needed by …)`, and haikuporter exits 1 after 2 s. The test now sets
  `/boot/system/develop/lib:/boot/system/lib`.
- The minimum/development image has one login, **`baron`**, not `user` (the regular images): `pi-session.sh` waited its 300 + 900 s
  for an ssh that was refused (publickey) while the Pi was up with sshd. `PI_SSH_USER=baron` now selects it in `pi-ssh.sh` and
  `pi-session.sh`.

**Result: H18's last check is met** (gcc 16.2.0 natively on the Pi builds a C and a C++ HaikuPorts recipe with haikuporter into
installable packages whose programs run). Not covered: building recipes against the full HaikuPorts tree (recipe parsing time),
recipes needing more build dependencies than the bootstrap set (cmake, ninja, meson are not in this chroot's set).

## Not done yet

- **Replacing the bootstrap gcc 13.3 in the dev profile** (`HAIKU_PI_DEV`): `build/jam/repositories/HaikuPorts/arm64`
  now lists `gcc-16.2.0_2026_11_01-1`, `binutils-2.46.1-1`, `make-4.4.1-1` (the hpkgs in `generated.arm64/download/`);
  haiku b59f1c957f. The dev image built with them (no new `not available` line: bc and wget, as before) boots in
  QEMU and passes native-gcc.sh **19/19** (the Fortran and CMake checks skip: no gcc_fortran/cmake in that image;
  log artifacts/qemu/20261103-074747-virt.log) (2026-11-03). On the Pi (2026-11-04): gcc 16.2.0 from the dev image builds hoedown and gperf with haikuporter (section above).
- **haiku_devel in the repository**: programs that use Haiku's headers and libraries (`libroot`, `libbe`, every C program's
  `<stdio.h>`) need the `haiku_devel` package of the same build as the running system (`haiku_devel` requires `haiku ==`
  its own version). Published with each release from image-2026-11-03b on, the newest release's only
  (a repository holds one version per package; docs/RELEASING.md); the development image has it built in.

## Known gaps

- **gfortran warns on every compile**: `f951: Warning: command-line option '-Wno-multichar' is valid for C/C++/ObjC/ObjC++
  but not for Fortran` — Haiku's `CC1_SPEC` (gcc/config/haiku.h) adds `-Wno-multichar` for every cc1-like program and the
  Fortran spec includes it. Harmless (HaikuPorts' gfortran has the same spec); a configure or meson check that fails on
  *any* compiler output would trip on it. Fix belongs in buildtools (a C-family-only spec).
- No libsanitizer (`-fsanitize=address/undefined`), no libgccjit, no Objective-C, no GCC plugins.
- C++ `import std;`: libstdc++'s `std.cc` and `libstdc++.modules.json` are shipped, but the module needs the long double
  math declarations Haiku's `<cmath>` lacks (gcc16.md, step 1) — not tried.
- libgfortran is in gcc_fortran, not gcc_syslibs (above).
- Debug-info packages: none (everything stripped); HaikuPorts makes `gcc_debuginfo`.

## On the Pi

Not run (the bench runs the main session's queue). Copy the packages and the test scripts (e.g. `scripts/pi-ssh.sh put`),
then on an image with gcc_syslibs 16.2 (every image since the switch; the dev image's bootstrap gcc 13.3 package is
replaced by `pkgman install` of the file, same package name, newer version):

```
cd /boot/home
pkgman install -y ./gcc-16.2.0_2026_11_01-1-arm64.hpkg ./gcc_fortran-16.2.0_2026_11_01-1-arm64.hpkg \
  ./gcc_syslibs_devel-16.2.0_2026_11_01-1-arm64.hpkg ./haiku_devel.hpkg ./binutils-2.46.1-1-arm64.hpkg \
  ./make-4.4.1-1-arm64.hpkg ./cmake-4.4.5-1-arm64.hpkg ./ninja-1.13.2-1-arm64.hpkg
gcc --version                      # gcc (2026_11_01) 16.2.0
sh native-gcc.sh                   # NGCC ... PASS|FAIL, NGCC end n/m
```

`tools/pi-tests/dev-tools.sh` (make, CMake + Ninja, Meson, the Cython extension through pip/meson-python) uses
whatever `gcc` is installed: with the part 1 packages of dev-tools.md installed as there, but **instead of** its
"a compiler for the build checks" line (bootstrap gcc 13.3 + 13.3 gcc_syslibs_devel) the `pkgman install` above, then
`sh dev-tools.sh`; its line `DEV gcc 16.2.0 as=… ld=…` shows which compiler ran. As a boot test without ssh (the
main session's bench), the same packages into a copy of the image with `scripts/image-add.sh … <hpkg>:/boot/system/
packages/<hpkg> … tools/pi-tests/native-gcc.sh:/boot/home/config/settings/boot/UserBootscript` (the QEMU set above),
then `scripts/sd-cycle.sh --flash IMG --secs 900 --label native-gcc` and `grep NGCC` in the UART log (QEMU's TCG run took
under 3 min after the desktop; the Pi is faster).

By hand, the essentials:

```
printf '#include <stdio.h>\nint main(void){puts("hello");}\n' > h.c && gcc -O2 -o h h.c && ./h
printf '#include <iostream>\nint main(){std::cout << "hello c++\\n";}\n' > h.cpp && g++ -O2 -o hx h.cpp && ./hx
gfortran --version && printf 'print *, "hello fortran"\nend\n' > h.f90 && gfortran -o hf h.f90 && ./hf
gcc -flto -O2 -o hl h.c && ./hl    # LTO through ld's plugin
```

NumPy from source (dev-tools.md) now has a Fortran compiler for f2py's tests; NumPy's own build needs none.

# Developer tools on the Pi (H18, part 1)

Backlog item 4 (PLAN.md): software compiled inside Haiku on the Pi. Part 1, this note: the tools that do
**not** depend on the GCC 16.2 switch, cross-built on the host as arm64 Haiku packages. Part 2, the native
`gcc` package, is built once, on 16.2, after the main build switches (design/gcc16.md, "Next steps" 6);
until then the on-device compiler is the `gcc-13.3.0…bootstrap-1` package of the development image
(`-sHAIKU_PI_DEV=1`).

## Result (2026-11-02)

| package (artifacts/packages/) | version | from | Haiku patches |
|---|---|---|---|
| `make-4.4.1-1-arm64` | 4.4.1 (newest) | HaikuPorts `sys-devel/make` | the recipe's patchset (3: ar scan, dir.c, findprog) |
| `ninja-1.13.2-1-arm64` | 1.13.2 (newest) | HaikuPorts `dev-build/ninja` | the recipe's patchset (`--platform haiku`, getloadavg from libbsd, CPU count) |
| `pkgconf-3.0.10-1-arm64`, `pkgconf_devel` | 3.0.10 (newest; recipe 1.5.3) | `tools/recipes/dev-util/pkgconf` (HaikuPorts' recipe, bumped) | none needed: pkgconf has Haiku support upstream |
| `cmake-4.4.5-1-arm64` | 4.4.5 (newest; recipe 4.4.4) | `tools/recipes/dev-build/cmake` (HaikuPorts' recipe, bumped) | the recipe's patchset (10, applies to 4.4.5 unchanged) + `patches/cmake-4.4.5/0001` (ours) |
| `binutils-2.46.1-1-arm64` | 2.46.1 | `sources/buildtools` binutils (the cross tools' source) | Haiku's buildtools changes (incl. `-z pack-relative-relocs` on arm64, 1cad3a62fa) |
| `meson-1.12.1-1-any` | 1.12.1 (newest) | HaikuPorts `dev-build/meson` (its sdist) | the recipe's patchset (boost include path, gcc2, pkgconfig revert, python PATH) |
| `setuptools_python3.14-84.2.1-1-any` | 84.2.1 (newest; recipe 82.0.1) | PyPI sdist | the recipe's patch (distutils' Haiku install schemes; 82.0.1's applies with offsets) |
| `pip_python3.14-26.2.2-1-any` | 26.2.2 (newest) | PyPI wheel | — |
| `wheel_python3.14-0.48.0-1-any` | 0.48.0 (newest; recipe 0.47.0) | PyPI wheel | — |
| `cython_python3.14-3.3.1-1-any` | 3.3.1 (newest; recipe 3.3.0) | PyPI wheel (pure Python) | — |
| `meson_python_python3.14-0.22.1-1-any` | 0.22.1 (newest; recipe 0.22.0) | PyPI wheel | — |
| `pyproject_metadata_python3.14-0.12.1-1-any` | 0.12.1 (newest) | PyPI wheel | — |

(`packaging_python3.14` 26.3, which wheel, meson-python and pyproject-metadata require, is already in the
repository: scripts/build-numpy.sh.) Not published, not in an image yet.

Build: `scripts/build-dev-tools.sh` (all of it ~15 min on the host; `--only make|ninja|pkgconf|cmake|binutils|
python|check`). It needs scripts/haiku-sysroot.sh's sysroot with our curl and ncurses6 packages
(scripts/build-packages.sh), scripts/build-python.sh's build python and uv. CMake and binutils run under
scripts/heavy-build.sh.

## How each is built

**make.** The recipe runs `configure` + `build.sh` natively; here `configure --host=aarch64-unknown-haiku` and
make. Two things the cross build would otherwise get wrong: make bakes the C++ compiler that configure used into
its built-in `$(CXX)` (`MAKE_CXX` in config.h: the cross compiler's host path) — set back to `g++`; and its
default `include`/`-l` search directories are Haiku's `develop/headers` and `develop/lib` (the recipe gets them
from runConfigure). `gnumake.h` is in the package (`develop/headers`), as in HaikuPorts' make.

**ninja.** The recipe's `configure.py` (its patch adds `--platform=haiku`) generating build.ninja for the cross
compiler (`--host=linux --platform=haiku`, not `--bootstrap`), then the host's ninja builds `ninja`.

**pkgconf.** Upstream has Haiku support: the default search path is `find_paths(B_FIND_PATH_DEVELOP_LIB_DIRECTORY,
"pkgconfig")` + `B_FIND_PATH_DATA_DIRECTORY` (every installation location: system, non-packaged, home), so no
`--with-pkg-config-dir` is needed. Given: the directories it filters out of `--cflags`/`--libs`
(`--with-system-libdir=/boot/system/develop/lib`, `--with-system-includedir=/boot/system/develop/headers`, which
configure would otherwise take from the build prefix) and the personality directory. `pkg-config -> pkgconf` as
the recipe. The library is `libpkgconf.so.8` (3.x; the 1.5.3 recipe's `libVersion` 3.0.0 changed to 8.0.0). New
in 3.x and packaged: `bomtool`, `pccritic`, `spdxtool`. The recipe states no reason for staying on 1.5.3 (our
haikuports clone is shallow, so its history was not checked), and 3.x has the Haiku search path upstream, so the
newest release is built.

**cmake.** Cross-compiled with CMake itself (the recipe's `./configure` bootstrap compiles and runs programs on
the build host) and the recipe's choices: system curl (our curl 8.22.0 package), expat and zlib; the recipe's
install directories (`data/cmake`: CMake finds its modules relative to `bin/cmake`, `documentation/…`);
`-lbsd`; ccmake on ncurses6. Unlike the recipe, libuv and librhash are the bundled copies (no packages of them in
our repository); CMake's own CMakeLists for its bundled libuv has no Haiku branch although the sources have
`src/unix/haiku.c` — `patches/cmake-4.4.5/0001-cmlibuv-build-the-Haiku-platform-sources.patch` adds the branch
upstream libuv has (link failed before: `uv__hrtime`, `uv__platform_invalidate_fd`). No RPATH (the link path named
`/boot/system/non-packaged/lib`, where curl was in the sysroot). The four programs are ~17 MB each (libarchive,
libuv, the debugger's cppdap, … statically inside); the package is 30 MB. Requires `lib:libcurl`, `libexpat`,
`libz`, `libncursesw`, `libiconv`, `libcharset`, `libexecinfo`, `libstdc++`, `libgcc_s` — all in the
release images. (libbsd and libnetwork are in the `haiku` package, which provides no `lib:` resolvables: a
`lib:libbsd` requirement would make `pkgman install` fail, so none is written.)

**binutils.** `git archive` of `sources/buildtools` HEAD (`binutils/`, 2.46.1 + Haiku's changes; fc2ad25b8b at
the time), a Canadian cross (build x86_64-linux, host = target = aarch64-unknown-haiku) with the recipe's options:
`--enable-plugins --enable-64-bit-bfd --enable-ld=default --with-sysroot=/ --enable-default-execstack=no`,
no NLS, no gold, no gprofng, the bundled zlib (no extra requirement), no zstd, static libbfd/libopcodes (the
recipe deletes the libraries and headers anyway). Layout as HaikuPorts' binutils (and the bootstrap package the
dev image carries): the programs in `bin/`, the tool directory `develop/tools/aarch64-unknown-haiku/` with
`bin/` links to them (where the gcc driver looks for `as` and `ld`) and `lib/ldscripts`. 13 compiler warnings,
none new to Haiku except libctf's `integer overflow in expression '-2147483648'` (an `ECTF_*` error code built
on Haiku's negative errno base: harmless, same in the cross tools). The package provides `cmd:as`, `cmd:ld`,
`cmd:c++filt`, … (package-port.py now keeps `+` in resolvables, as HaikuPorts does).

**Python packages.** As in design/numpy.md: `scripts/package-python-wheel.py` installs a wheel into the
`haiku_vendor` layout (`/boot/system/lib/python3.14/vendor-packages`), compiles the bytecode, scripts as
`<name>-3.14` + `<name>`. New options for this work: `--name meson` (HaikuPorts packages meson as `meson`, arch
any, scripts unsuffixed, requires `cmd:ninja >= 1.6`), `--map meson cmd:meson` (meson-python's `Requires-Dist:
meson` becomes `cmd:meson`, as HaikuPorts' meson_python recipe has it); a wheel's `share/man` goes to
`documentation/man`, the rest of `share/` to `data/`. Meson and setuptools are built from their sdists with the
recipes' patches (`python -m build --wheel` in the build venv); the others are the PyPI `py3-none-any` wheels.
Cython is its pure-Python wheel (HaikuPorts compiles Cython's own modules: ~2-3× faster cythonize; the pure
build is functionally the same — compiling it is a possible follow-up with the numpy cross setup).
pip: python3.14 also has `ensurepip` with a bundled pip 26.2.1 (`python3.14 -m ensurepip`, what HaikuPorts tells
users to do); the package gives pip without that step. pip installs to `/boot/system/non-packaged/lib/python3.14/
site-packages` (python3.14's Haiku `sysconfig` scheme), `--user` to `~/config/non-packaged/…`.

## Checks (host, `--only check`)

All 13 packages extracted together:
- every ELF file (26: programs and libpkgconf): each `NEEDED` is a library of the image (libroot, libbsd,
  libnetwork, libbe, libstdc++, libgcc_s, libz, libexpat, libcurl, libncursesw, libiconv, libcharset,
  libexecinfo) or libpkgconf, and every undefined dynamic symbol is defined by one of them;
- no build-host path in any file (`__FILE__` in bfd's and CPack's assertions needed `-ffile-prefix-map`), no
  `/boot/system/non-packaged` in a program or library (make's `MAKE_CXX`, pkgconf's system directories, CMake's
  RPATH were the cases found and fixed); Python modules mention `non-packaged` on purpose (setuptools' scheme);
- every `requires:` has a provider among our packages, the image build's download directory or `haiku`
  (names only; this caught a hand-written `lib:libbsd` that nothing provides);
- the provides/requires of each package are printed (summary in the table above).

## QEMU smoke run (2026-11-02, no Pi)

`scripts/image-add.sh` on a copy of release image-2026-11-02b: the 13 packages, packaging_python3.14,
python3.14_devel, the dev image's `gcc-13.3.0…bootstrap-1` + `gcc_syslibs_devel` and jam's `haiku_devel` in
`/boot/system/packages`, `tools/pi-tests/dev-tools.sh` as UserBootscript; `scripts/qemu-virt.sh` (virt,
cortex-a72 ×4, TCG). **`DEV end 23/23`**, all PASS: every version check; `pkg-config --modversion libpkgconf`
3.0.10 (Haiku search path); `cmake -P` ("on Haiku"); `as` + `ld` + `objdump` on a hand-written object; gcc 13.3
runs **our** assembler and linker (`gcc -print-prog-name=as` →
`/boot/system/develop/tools/aarch64-unknown-haiku/bin/as`, the package's link to `bin/as`); C hello with make;
C and C++ with CMake + Ninja and with Meson; `pip install --no-index --no-build-isolation` of a pure project
(setuptools backend → `/boot/system/non-packaged/lib/python3.14/site-packages`); and a Cython extension module
built by pip through meson-python (meson, ninja, cython, gcc), imported and run (`fib(90)` right).

## Pi test plan

`tools/pi-tests/dev-tools.sh` runs every check below in one go (`DEV <check> PASS|FAIL`, `DEV end n/m`); as a
UserBootscript it writes to the serial console. Copy the packages and the script to the Pi (e.g. with
`scripts/pi-ssh.sh put`), then:

```
cd /boot/home
pkgman install -y ./make-4.4.1-1-arm64.hpkg ./ninja-1.13.2-1-arm64.hpkg ./pkgconf-3.0.10-1-arm64.hpkg \
  ./pkgconf_devel-3.0.10-1-arm64.hpkg ./cmake-4.4.5-1-arm64.hpkg ./binutils-2.46.1-1-arm64.hpkg \
  ./meson-1.12.1-1-any.hpkg ./pip_python3.14-26.2.2-1-any.hpkg ./setuptools_python3.14-84.2.1-1-any.hpkg \
  ./wheel_python3.14-0.48.0-1-any.hpkg ./cython_python3.14-3.3.1-1-any.hpkg \
  ./meson_python_python3.14-0.22.1-1-any.hpkg ./pyproject_metadata_python3.14-0.12.1-1-any.hpkg \
  ./packaging_python3.14-26.3-1-any.hpkg
# a compiler for the build checks (until the native gcc package): on a release image
pkgman install -y ./gcc-13.3.0_2026_03_29_bootstrap-1-arm64.hpkg ./haiku_devel.hpkg \
  ./gcc_syslibs_devel-13.3.0_2026_03_29_bootstrap-1-arm64.hpkg ./python3.14_devel-3.14.8-2-arm64.hpkg
sh dev-tools.sh
```

(`pkgman install` of a file replaces the dev image's `make-4.4.1_bootstrap` and `binutils-2.41…bootstrap`
packages of the same names. With the packages in our repository: `pkgman install make ninja pkgconf cmake
binutils meson pip_python3.14 cython_python3.14 meson_python_python3.14`.)

What it does, by hand:

```
make --version; ninja --version; cmake --version; ctest --version; cpack --version
pkg-config --version; pkg-config --modversion libpkgconf      # 3.0.10: the search path is Haiku's
meson --version; python3.14 -m pip --version; cython --version; as --version; ld --version
gcc -print-prog-name=as                                       # which assembler gcc runs

mkdir -p /tmp/t/src && cd /tmp/t
printf '#include <stdio.h>\nint main(void) { printf("hello\\n"); return 0; }\n' > src/hello.c
printf 'hello: src/hello.c\n\t$(CC) -O2 -o $@ $<\n' > Makefile
make && ./hello                                               # make
printf 'cmake_minimum_required(VERSION 3.20)\nproject(t C)\nadd_executable(hello src/hello.c)\n' > CMakeLists.txt
cmake -G Ninja -B build-cmake && ninja -C build-cmake && ./build-cmake/hello     # CMake + Ninja
printf "project('t', 'c')\nexecutable('hello', 'src/hello.c')\n" > meson.build
meson setup build-meson && meson compile -C build-meson && ./build-meson/hello  # Meson
python3.14 -m pip install --user six                          # pip, from PyPI (needs the network)
python3.14 -c "import six; print(six.__version__, six.__file__)"
```

dev-tools.sh also builds a C++ program with each build system, installs a pure-Python pyproject project
offline (`pip install --no-index --no-build-isolation`, setuptools backend) and a **Cython extension module
through meson-python** (pip → mesonpy → meson → ninja → cython → gcc): the path of a native NumPy build.

**NumPy from source** (H19's other half), once the native gcc is there (or now with the bootstrap gcc 13.3):

```
pkgman install -y python3.14_devel        # Python.h, python-3.14.pc
python3.14 -m pip download --no-deps --no-binary :all: numpy==2.5.4     # or copy numpy-2.5.4.tar.gz over
tar xzf numpy-2.5.4.tar.gz && cd numpy-2.5.4
patch -p1 < 0001-string_buffer-undef-Haiku-ctype-macros.patch       # patches/numpy-2.5.4/
python3.14 -m pip install --user --no-build-isolation -Csetup-args=-Dblas=none \
  -Csetup-args=-Dlapack=none -Csetup-args=-Dallow-noblas=true .
cd /tmp && python3.14 -c "import numpy; numpy.show_config(); numpy.show_runtime()"
```

(One A72 core per compile job; expect tens of minutes. `pip install numpy` straight from PyPI does the same
without the ctype patch and fails in `string_buffer.h` until Haiku's `<ctype.h>` stops defining function-like
macros under C++.)

## Open

- The native **gcc** package (16.2, after the switch) — then the dev image carries make/binutils from here plus
  that gcc, and `pkgman install gcc make cmake` works on a fresh image (PLAN H18 exit criterion).
- Publishing (scripts/publish-repo.sh) and putting them into the dev image (`HAIKU_PI_DEV`: the repository file
  lists `make-4.4.1_bootstrap`, `binutils-…bootstrap`), after the Pi run.
- Compiled Cython (its own modules cross-compiled: faster cythonize); libuv/librhash packages, so CMake can use
  the system copies as the recipe does.
- `_devel` packages of other ports (H18's "the `_devel` packages"): most of ours exist (scripts/package-port.py
  makes them); a list of what a fresh image misses for common builds is part 2.

## Pi result (2026-11-02)

`tools/pi-tests/dev-tools.sh` on image-2026-11-03 candidate + the 13 packages + the bootstrap gcc 13.3: **DEV end 23/23** (artifacts/dev-tools-pi/dev-tools.txt).

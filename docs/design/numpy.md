# NumPy on Haiku arm64 (H19)

Backlog item 5 (PLAN.md): NumPy for our Python 3.14, built two ways — natively with pip on the Pi
(needs H18's compiler packages) and as a cross-built `numpy_python3.14` package. This note covers
the **cross-built package** (host side, 2026-11-02) and the Pi test plan; the native pip build is
still open (end of this note).

## Result

| what | version | package (artifacts/packages/) |
|---|---|---|
| NumPy (newest release) | 2.5.4 | `numpy_python3.14-2.5.4-1-arm64.hpkg` (11.6 MB) |
| pytest | 9.2.0 | `pytest_python3.14-9.2.0-1-any.hpkg` |
| pluggy, iniconfig, packaging, Pygments (pytest's requirements) | 1.7.0, 2.3.1, 26.3, 2.21.0 | `<name>_python3.14-<version>-1-any.hpkg` |
| hypothesis (NumPy's conftest imports it unconditionally) | 6.155.7 | `hypothesis_python3.14-6.155.7-1-any.hpkg` |
| sortedcontainers (hypothesis' requirement) | 2.4.0 | `sortedcontainers_python3.14-2.4.0-1-any.hpkg` |

Package names and provides follow HaikuPorts' dev-python recipes: `numpy_python3.14` provides
`numpy_python3.14`, `numpy_python314`, `cmd:f2py[_3.14]`, `cmd:numpy_config[_3.14]` and requires
`haiku`, `cmd:python3.14`, `lib:libstdc++`, `lib:libgcc_s`; the modules are in
`/boot/system/lib/python3.14/vendor-packages` (the `haiku_vendor` scheme), the scripts are
`f2py-3.14`/`numpy-config-3.14` with unsuffixed symlinks, as the recipes' INSTALL() makes them.

The build: `scripts/build-numpy.sh` (about a minute on the host at 16 jobs; `--no-test-deps` for NumPy alone).
It needs `scripts/build-python.sh` done (the build python `artifacts/python-host` and python3.14 +
python3.14_devel in the sysroot) and `uv` on the host.

## How it is built

**Build tools.** A uv venv, `artifacts/python-build-venv`, on the build python (CPython 3.14.8, the
target's version) with meson-python 0.22.1, Cython 3.3.1, build and installer from PyPI. NumPy
builds with its own vendored meson (`vendored-meson/meson/meson.py`, from pyproject.toml).

**Cross compiling with meson-python.** `python -m build --wheel --no-isolation` with two cross files:
`tools/meson/haiku-arm64.cross` (the project's) and one the script generates:

- `c`/`cpp` entries that carry `--sysroot` themselves. NumPy's CPU feature probes (the vendored
  meson's `features` module) run the compiler **without** the cross file's `c_args`; without the
  sysroot every probe fails (`arm_neon.h: stdint.h: No such file or directory`), and the build goes on
  without any SIMD code — the configure summary then shows an empty baseline. The script now fails
  if the baseline is not `NEON NEON_FP16 NEON_VFPV4 ASIMD`.
- `python` = the venv's python, which introspects as the target: `_PYTHON_SYSCONFIGDATA_NAME=
  _sysconfigdata__haiku_` with `PYTHONPATH` on a copy of the sysroot's `_sysconfigdata__haiku_.py`
  (EXT_SUFFIX `.cpython-314.so`, the module tag); the include directory comes from the sysroot's
  `python-3.14.pc` through pkg-config. `_PYTHON_HOST_PLATFORM=haiku-1-arm64` names the wheel
  (`numpy-2.5.4-cp314-cp314-haiku_1_arm64.whl`).
- `longdouble_format = 'IEEE_QUAD_LE'`, which NumPy cannot find out without running a program
  (128-bit IEEE quad, as on every AArch64 ELF target; `__LDBL_MANT_DIG__` 113).

**Options.** `-Dblas=none -Dlapack=none -Dallow-noblas=true`: NumPy's bundled `lapack_lite`, no
OpenBLAS (none in our repository; `numpy.linalg` works, slower on large matrices). CPU baseline
NumPy's `min` (NEON/ASIMD), dispatch `max`: ASIMDHP, ASIMDDP, ASIMDFHM and SVE variants are compiled
in but never chosen on Haiku — `npy_cpu_features.c` reads the CPU features only from Linux/BSD HWCAP
(`getauxval`, `elf_aux_info`) and otherwise falls back to the compile-time baseline. That is right for
the Cortex-A72 (Armv8.0: none of those extensions), so the fallback costs nothing on the Pi 4.
(Highway's own runtime dispatch, `hwy/targets.cc`, is not compiled; NumPy dispatches its sorts.)

**Checks before packaging.**
- every undefined dynamic symbol of the 19 extension modules is defined by `libroot.so`,
  `libstdc++.so.6`, `libgcc_s.so.1` or `libpython3.14.so.1.0` (a missing one links fine and fails
  only at `import` on the Pi); all resolved. The modules do not link libpython (LIBPYTHON is empty,
  as on Linux): its symbols come from the running python3.14.
- no host path in any packaged file: `numpy/__config__.py` (what `numpy.show_config()` prints) names
  the cross compiler, its `--sysroot` and the venv's python; the packager rewrites them to `gcc`,
  `g++` and `/boot/system/bin/python3.14`.
- one compiler warning (`dts.month may be used uninitialized`, NumPy's datetime code, also on Linux).

**Packaging.** `scripts/package-python-wheel.py` (new; reuses package-port.py's `.PackageInfo` and
`package create`) installs a wheel with the `installer` API under the packaged prefix (scripts with
`#!/boot/system/bin/python3.14`), compiles the bytecode with the paths on Haiku and
`--invalidation-mode unchecked-hash` (packagefs is read-only: a stale `.pyc` cannot happen, and
Python does not stat every source to check), strips the ELF objects, turns `NEEDED` and the wheel's
`Requires-Dist` (markers evaluated for Haiku) into requires, and writes the package; pure-Python
wheels become `any` packages. Licenses Haiku has no text of (NumPy's `0BSD`, `CC0-1.0`) get a
`data/licenses/<id>` pointing at the wheel's license files, which are in the package.

## Patches (patches/numpy-2.5.4/)

| patch | why |
|---|---|
| `0001-string_buffer-undef-Haiku-ctype-macros.patch` | Haiku's `<ctype.h>` defines `isalpha()` and friends as function-like macros in C++ too (glibc: C only), which break `string_buffer.h`'s `Buffer::isalpha()` etc. (`expected primary-expression before ')'`). Same change as HaikuPorts' numpy-2.5.3.patchset; checked still needed on 2.5.4. |

The proper fix is in Haiku: no function-like `<ctype.h>` macros under `__cplusplus` (not made here;
`sources/haiku` untouched). With it the patch can go.

## Pi test plan

Install the packages (copy the eight `.hpkg` files to the Pi, then either `pkgman install` them or put
them into `/boot/system/packages`, where the package daemon activates them; python3.14-3.14.8-2 and
gcc_syslibs must be installed, as in the release image):

```
pkgman install -y ./numpy_python3.14-2.5.4-1-arm64.hpkg ./pytest_python3.14-9.2.0-1-any.hpkg \
  ./pluggy_python3.14-1.7.0-1-any.hpkg ./iniconfig_python3.14-2.3.1-1-any.hpkg \
  ./packaging_python3.14-26.3-1-any.hpkg ./pygments_python3.14-2.21.0-1-any.hpkg \
  ./hypothesis_python3.14-6.155.7-1-any.hpkg ./sortedcontainers_python3.14-2.4.0-1-any.hpkg
```

Then, from a writable directory (pytest and hypothesis write caches; NumPy's conftest puts
hypothesis' in `/tmp/.hypothesis`), cheapest first:

```
cd /tmp
python3.14 -c "import numpy; print(numpy.__version__, numpy.__file__)"
python3.14 -c "import numpy; numpy.show_config(); numpy.show_runtime()"
python3.14 -c "import numpy as np; r = np.random.default_rng(0); a = r.random((300, 300)); \
print(np.linalg.norm(a @ a), np.linalg.det(a[:40, :40]), np.linalg.solve(a, a.sum(1))[:3], np.fft.fft(np.arange(8.)).round(3))"
# a subset (minutes): core arrays, ufuncs, linalg, fft, random
python3.14 -c "import numpy, sys; sys.exit(not numpy.test(label='fast', verbose=1, durations=20, \
extra_argv=['-p', 'no:cacheprovider', '-rfE'], tests=['numpy._core.tests.test_multiarray', \
'numpy._core.tests.test_umath', 'numpy.linalg.tests.test_linalg', 'numpy.fft', 'numpy.random']))"
# the whole fast suite (long on one A72 core: tens of minutes)
python3.14 -c "import numpy, sys; sys.exit(not numpy.test(label='fast', durations=20, \
extra_argv=['-p', 'no:cacheprovider', '-rfE']))"
```

(`pytest-3.14 --pyargs numpy -m "not slow" -p no:cacheprovider -rfE` is the same as the last one.)

What to look for:
- `show_runtime()`: `found` NEON, NEON_FP16, NEON_VFPV4, ASIMD; `not found` ASIMDHP, ASIMDDP,
  ASIMDFHM, SVE (the Haiku fallback above); `show_config()`: `blas`/`lapack` none, `cross-compiled:
  True`, compilers `gcc`/`g++`.
- No pytest-xdist or pytest-timeout: single process, no per-test time limit. A hang is a hang: note
  the test (`-v` prints names).
- Areas likely to show Haiku differences, to triage rather than to fix in NumPy: long double
  printing and parsing (no `strtold_l` on Haiku: NumPy's fallback), floating-point exception flags
  (`np.errstate` warnings depend on `fetestexcept` in Haiku's arm64 libroot), `np.memmap` and
  file/`mmap` tests, locale-dependent tests, threading tests, and tests that build C/Cython/f2py
  code (they need a compiler, meson and Cython on the Pi: skipped or slow-marked).

## Pi results (2026-11-02)

Network sessions of image-2026-11-02b (+ the setrlimit fix below), the 8 packages installed with `pkgman install`:

- `import numpy` → 2.5.4 from `vendor-packages`; `show_runtime()`: baseline NEON, NEON_FP16, NEON_VFPV4, ASIMD
  (as expected on the Cortex-A72); a 300×300 matmul, `det`, `solve`, `fft` give the right numbers.
- `numpy.test(label='fast')` without f2py: **11 min 38 s** on the Pi; **6 failed, 8 errors**, everything else passed
  or skipped:
  - 6 failures, all `longdouble`: `test_str_roundtrip`, `test_locale_longdouble`, two `dragon4_*[longdouble]`,
    two `quantile` cases with longdouble. Cause: Haiku's `strtold()` is `strtod()` on every architecture (a 1999
    glibc stub, "there is no long double type"), so `np.longdouble('1.2')` is the double 1.2. Fix in progress in
    libroot (the glibc strtod template built for ldbl-128, as glibc's own sysdeps do).
  - 8 errors, `test_mem_policy.py`: it compiles a C extension with meson at run time (no meson on the Pi; H18).
  - The f2py tests need meson and a Fortran compiler: excluded (`--ignore=…/numpy/f2py`); without it pytest stops at
    collection.
- `test_xerbla_override` failed in the first run: `setrlimit(RLIMIT_CORE, (0, 0))` returned EINVAL ("current limit
  exceeds maximum limit"); Haiku accepted no change of its fixed limits, even to the same value. Fixed in the kernel,
  haiku `f0a1d5f5cf` (a request equal to the current limits succeeds); passes since.
- Test commands: as above, plus `extra_argv=["-p","no:cacheprovider","-rfE","-q",
  "--ignore=/boot/system/lib/python3.14/vendor-packages/numpy/f2py","--continue-on-collection-errors"]`.

## Open

- **Native build on the Pi** (the other half of H19): needs H18's packages (gcc, ninja, meson,
  pkgconfig) plus Cython and meson-python as `_python3.14` packages, and **pip**: our python3.14
  is built `--with-ensurepip=no`, so there is no pip on the Pi yet. pip, meson-python, Cython (has a
  pure-Python wheel) and pyproject-metadata can be packaged with `scripts/package-python-wheel.py`
  the same way as pytest. NumPy's sdist builds natively with `pip install --no-build-isolation numpy`
  once they are there (`numpy-2.5.4.tar.gz`; the Haiku patch above is needed natively too).
- **OpenBLAS**: not attempted (a sizeable port: its own build system, Fortran-free LAPACK needs
  `NOFORTRAN`/C LAPACK); `numpy.linalg` uses lapack_lite meanwhile.
- **Runtime CPU detection on Haiku**: on a CPU with ASIMDHP/DotProd/SVE (not the Pi 4) NumPy would
  still use only the baseline. A Haiku branch in `npy_cpu_features.c` reading `ID_AA64ISAR0_EL1`
  (EL0 ID-register reads work on our kernel since the Wine work) would fix that; irrelevant on the
  Cortex-A72.
- Published in our repository (11-02): `pkgman install numpy_python3.14` (pytest_python3.14 and hypothesis_python3.14 for the tests); not in an image.

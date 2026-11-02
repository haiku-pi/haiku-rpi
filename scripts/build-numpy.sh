#!/usr/bin/env bash
# build-numpy.sh — cross-build NumPy for Haiku arm64 against our Python 3.14 and package it as
# numpy_python3.14 (HaikuPorts' dev-python/numpy recipe's package), with the pure-Python packages
# numpy.test() needs: pytest (+ pluggy, iniconfig, packaging, pygments) and hypothesis
# (+ sortedcontainers), each as <module>_python3.14. See docs/design/numpy.md.
#
#   scripts/build-numpy.sh [--no-test-deps]   (--no-test-deps: numpy only)
#
# Steps:
#   1. the build tools: a uv venv (artifacts/python-build-venv) on the build python
#      (artifacts/python-host, scripts/build-python.sh: the same 3.14.8 as the target) with
#      meson-python, Cython, build and installer from PyPI. Never the system pip.
#   2. NumPy's sdist (PyPI, sha256 checked) and patches/numpy-<version>/*.patch.
#   3. the wheel: `python -m build --wheel --no-isolation` (meson-python with NumPy's vendored
#      meson), cross: tools/meson/haiku-arm64.cross plus a generated cross file that
#        - puts --sysroot into the compiler entries themselves: NumPy's CPU feature probes
#          (vendored meson's `features` module) compile without the c_args, so without it every
#          probe fails (arm_neon.h finds no stdint.h) and the build silently drops all SIMD code
#        - names the build python, which introspects as the target: _PYTHON_SYSCONFIGDATA_NAME
#          and PYTHONPATH give it the sysroot's _sysconfigdata__haiku_ (EXT_SUFFIX .cpython-314.so,
#          the extension tag; the headers come from the sysroot's python-3.14.pc)
#        - longdouble_format: the long double format NumPy cannot run a program to find out
#          (IEEE quad, little endian, as on every AArch64 ELF target)
#      -Dblas=none -Dlapack=none: NumPy's own lapack_lite (no OpenBLAS port yet); the CPU baseline
#      is NumPy's "min" (NEON/ASIMD), dispatched extras (ASIMDHP/DP/FHM, SVE) are compiled but never
#      chosen on Haiku (no HWCAP: npy_cpu_features.c falls back to the compile-time baseline;
#      correct for the Cortex-A72, which has none of them). Under scripts/heavy-build.sh.
#   4. checks: every undefined dynamic symbol of the extension modules defined by libroot,
#      libstdc++, libgcc_s or libpython3.14 (a missing one links fine and fails only at import on
#      the Pi); the configure summary has the NEON baseline.
#   5. packages: scripts/package-python-wheel.py → artifacts/packages/numpy_python3.14-<version>-
#      <revision>-arm64.hpkg (numpy/__config__.py's cross compiler and build python renamed as on
#      Haiku) and, unless --no-test-deps, the test packages (arch any).
#
# Needs scripts/build-python.sh's python3.14 (build python + the sysroot's python3.14_devel) and
# the jam-built cross compiler.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
testDeps=1
revision=2
while [ $# -gt 0 ]; do
	case "$1" in
	--no-test-deps) testDeps=0; shift ;;
	*) echo "build-numpy: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
heavy="$root/scripts/heavy-build.sh"
hostPython="$root/artifacts/python-host/bin/python3.14"
sysconfigdata="$sysroot/boot/system/lib/python3.14/_sysconfigdata__haiku_.py"
[ -x "$tools-gcc" ] || { echo "build-numpy: no cross compiler at $tools-gcc" >&2; exit 1; }
[ -f "$sysconfigdata" ] && [ -f "$sysroot/boot/system/develop/headers/python3.14/Python.h" ] \
	|| { echo "build-numpy: no python3.14 in the sysroot: run scripts/build-python.sh" >&2; exit 1; }
"$hostPython" -c "import sys; sys.exit(sys.version_info[:2] != (3, 14))" 2>/dev/null \
	|| { echo "build-numpy: no build python 3.14 at $hostPython: run scripts/build-python.sh" >&2; exit 1; }
command -v uv > /dev/null || { echo "build-numpy: needs uv (https://docs.astral.sh/uv/)" >&2; exit 1; }

version=2.5.4
numpySdist="https://files.pythonhosted.org/packages/95/b0/c7453d0b6e2073c3264468b106ee1563750cecc910965e67357e3698c83e/numpy-$version.tar.gz|9a94cf751c9ad8ebaa835bcd3d40dacf8534ad086b88c38029b65123c7999d2a"
# url|sha256: the newest releases with a pure-Python wheel (hypothesis: later releases ship only
# compiled wheels; 6.155.7 is newer than the 6.152.1 NumPy pins in requirements/test_requirements.txt)
testWheels=(
	"https://files.pythonhosted.org/packages/40/9e/2b38731e0fc536806f16490e1a12d7f0dc2a1235aa8cc07bcc75416a7daa/pluggy-1.7.0-py3-none-any.whl|7dd7b0d8832ba3cb632c306926ded123429211b83641b35dc5c41ad2d34f9bec"
	"https://files.pythonhosted.org/packages/56/43/4ca9e49d27a1fcf6bece6f6aec0ea46bb9112489b93d4b688fb415457bdb/iniconfig-2.3.1-py3-none-any.whl|9121e2c1fdb355232495be3194c8dfe87ccc2d5dee45947b78e68f499790d7a7"
	"https://files.pythonhosted.org/packages/63/34/ba1c580383c9eada3711951fef0795c80b829a078d72188184bcab9dd527/packaging-26.3-py3-none-any.whl|d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c"
	"https://files.pythonhosted.org/packages/71/46/17f022dd3e953bf20a04a028a21ec746d942f8d2af30fa0f124fa0e6a684/pygments-2.21.0-py3-none-any.whl|2363c69b61c4a97c838da3b130dcd6468f4848992b21a82f2a63ec34377137d9"
	"https://files.pythonhosted.org/packages/51/39/1f5d8c8877a0fa327db959c19341d4be61660de1ab6b7391f9eb805bcd67/pytest-9.2.0-py3-none-any.whl|07acdcf88ec174f907dc01af70bf52d49b014bbab03faeeade31c96b18c2e588"
	"https://files.pythonhosted.org/packages/32/46/9cb0e58b2deb7f82b84065f37f3bffeb12413f947f9388e4cac22c4621ce/sortedcontainers-2.4.0-py2.py3-none-any.whl|a163dcaede0f1c021485e957a39245190e74249897e2ae4b2aa38595db237ee0"
	"https://files.pythonhosted.org/packages/01/f8/c151e196d4f397ed9436a071e52666c70a2f021138dea828b0a461e245db/hypothesis-6.155.7-py3-none-any.whl|9f634bdb1f9e9b8ab6ba09431cf2deedb750c96978125a6fb3c5a0f6c6db4131"
)
dl="$root/artifacts/cross-ports/dl"
mkdir -p "$dl"
fetch() {	# url|sha256 -> the file in $dl
	local url="${1%|*}" sum="${1##*|}" file="$dl/$(basename "${1%|*}")"
	[ -f "$file" ] || curl -sSfL -o "$file" "$url"
	echo "$sum  $file" | sha256sum -c --quiet || { echo "build-numpy: $file: bad checksum" >&2; exit 1; }
	echo "$file"
}

# 1. the build tools
venv="$root/artifacts/python-build-venv"
if ! "$venv/bin/python" -c "import mesonpy, Cython, build, installer" 2>/dev/null; then
	rm -rf "$venv"
	uv venv -q -p "$hostPython" "$venv"
	uv pip install -q --python "$venv/bin/python" 'meson-python>=0.18' 'Cython>=3.1' build installer
fi
echo "build-numpy: build tools: $(uv pip list -q --python "$venv/bin/python" 2>/dev/null \
	| sed -n 's/^\(meson-python\|cython\|meson\|installer\) *\([^ ]*\)$/\1 \2/p' | tr '\n' ' ')"

# 2. the source
work="$root/artifacts/cross-ports/numpy-$version"
rm -rf "$work/src" "$work/build" "$work/dist" "$work/sysconfig"
mkdir -p "$work/src" "$work/sysconfig"
sdist="$(fetch "$numpySdist")"
tar -xzf "$sdist" -C "$work/src" --strip-components=1
for p in "$root/patches/numpy-$version"/*.patch; do
	echo "build-numpy: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done

# 3. the wheel
cp "$sysconfigdata" "$work/sysconfig/"
cat > "$work/numpy.cross" <<EOF
# generated by scripts/build-numpy.sh: see there
[binaries]
c = ['$tools-gcc', '--sysroot=$sysroot']
cpp = ['$tools-g++', '--sysroot=$sysroot']
python = '$venv/bin/python'

[properties]
longdouble_format = 'IEEE_QUAD_LE'
EOF
df -BG --output=avail / | tail -n 1 | tr -d ' G' | { read -r free; [ "$free" -ge 17 ] \
	|| { echo "build-numpy: only ${free} GB free on /" >&2; exit 1; }; }
(cd "$work/src" && PATH="$venv/bin:$PATH" PYTHONPATH="$work/sysconfig" \
	_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__haiku_ _PYTHON_HOST_PLATFORM=haiku-1-arm64 \
	"$heavy" --mem-per-job 1 -- "$venv/bin/python" -m build --wheel --no-isolation \
	--skip-dependency-check --outdir "$work/dist" -Cbuilddir="$work/build" \
	-Csetup-args=--cross-file="$root/tools/meson/haiku-arm64.cross" \
	-Csetup-args=--cross-file="$work/numpy.cross" \
	-Csetup-args=-Dblas=none -Csetup-args=-Dlapack=none -Csetup-args=-Dallow-noblas=true \
	-Ccompile-args=-j'{JOBS}') > "$work/build.log" 2>&1 || { tail -n 40 "$work/build.log" >&2; exit 1; }
wheel="$(ls "$work/dist"/numpy-"$version"-cp314-cp314-*.whl)"
echo "build-numpy: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
sed -n '/^CPU Optimization Options/,/^$/p' "$work/build.log" | sed 's/^/build-numpy: /'

# 4. checks
grep -A2 '^  baseline:' "$work/build.log" | grep -q 'Enabled   : NEON NEON_FP16 NEON_VFPV4 ASIMD' \
	|| { echo "build-numpy: no NEON baseline: the SIMD probes failed (meson-log.txt)" >&2; exit 1; }
rm -rf "$work/check"
mkdir -p "$work/check"
(cd "$work/check" && "$venv/bin/python" -m zipfile -e "$wheel" .)
defined="$work/check/defined.txt"
for l in libroot.so libstdc++.so.6 libgcc_s.so.1 libpython3.14.so.1.0; do
	"$tools-nm" -D --defined-only "$sysroot/boot/system/lib/$l" | awk '{print $NF}'
done | sed 's/@.*//' | LC_ALL=C sort -u > "$defined"
missing="$(find "$work/check" -name '*.so' -exec "$tools-nm" -D --undefined-only {} + \
	| awk 'NF && $1 !~ /:$/ {print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$defined")"
[ -z "$missing" ] || { echo "build-numpy: undefined on Haiku: $missing" >&2; exit 1; }
echo "build-numpy: $(find "$work/check" -name '*.so' | wc -l) extension modules, every symbol resolved"
rm -rf "$work/check"

# 5. the packages
"$venv/bin/python" "$root/scripts/package-python-wheel.py" "$wheel" --revision "$revision" \
	--replace "$tools-gcc, --sysroot=$sysroot" gcc \
	--replace "$tools-g++, --sysroot=$sysroot" g++ \
	--replace "--sysroot=$root/tools/meson/../../artifacts/sysroot-arm64" "" \
	--replace "$venv/bin/python" /boot/system/bin/python3.14
if [ "$testDeps" = 1 ]; then
	for w in "${testWheels[@]}"; do
		file="$(fetch "$w")"
		"$venv/bin/python" "$root/scripts/package-python-wheel.py" "$file"
	done
fi

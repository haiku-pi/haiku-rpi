#!/bin/sh
# numpy-native.sh — on the Pi: build NumPy from its source with pip and the native GCC 16.2, then test it
# (H19, docs/design/numpy.md "Native build on the Pi"). Needs, installed: gcc, gcc_syslibs_devel, haiku_devel,
# binutils, ninja, meson, pkgconf, python3.14_devel, pip, Cython, meson-python, pyproject-metadata, packaging,
# and pytest + hypothesis for the tests; numpy-2.5.4-haiku.tar.gz (the sdist with patches/numpy-2.5.4 applied)
# in the current directory. Prints NPN lines; the last is "NPN end PASSED/CHECKS".
n=0 ok=0
check() {	# NAME RESULT(0 = pass) DETAIL
	n=$((n + 1))
	if [ "$2" = 0 ]; then ok=$((ok + 1)); echo "NPN $1 PASS $3"; else echo "NPN $1 FAIL $3"; fi
}
here=$(pwd)
rm -rf nb && mkdir nb && cd nb && tar xzf "$here/numpy-2.5.4-haiku.tar.gz"
echo "NPN gcc $(gcc -dumpversion) cython $(python3.14 -c 'import Cython; print(Cython.__version__)' 2>&1)"
t0=$(date +%s)
python3.14 -m pip install --no-build-isolation --no-deps -v ./numpy-2.5.4 > "$here/numpy-native-build.log" 2>&1
r=$?
t1=$(date +%s)
check build $r "$((t1 - t0)) s, log numpy-native-build.log ($(grep -c 'warning:' "$here/numpy-native-build.log") warning lines)"
cd /tmp
loc=$(python3.14 -c 'import numpy; print(numpy.__version__, numpy.__file__)' 2>&1)
case "$loc" in 2.5.4\ /boot/system/non-packaged/*) r=0 ;; *) r=1 ;; esac
check import $r "$loc"
cfg=$(python3.14 -c 'import numpy; c = numpy.show_config(mode="dicts"); print(c["Compilers"]["c"]["name"], c["Compilers"]["c"]["version"], "cross", c["Machine Information"]["cross-compiled"])' 2>&1)
case "$cfg" in gcc\ 16.2.0\ cross\ False) r=0 ;; *) r=1 ;; esac
check config $r "$cfg"
calc=$(python3.14 -c "import numpy as np; r = np.random.default_rng(0); a = r.random((300, 300)); \
print(round(float(np.linalg.norm(a @ a)), 3), np.fft.fft(np.arange(8.)).round(3)[1], np.finfo(np.longdouble).precision)" 2>&1)
case "$calc" in *\ 33) r=0 ;; *) r=1 ;; esac
check calc $r "$calc"
python3.14 -c "import numpy, sys; sys.exit(not numpy.test(label='fast', \
extra_argv=['-p', 'no:cacheprovider', '-rfE', '-q'], tests=['numpy._core.tests.test_multiarray', \
'numpy._core.tests.test_umath', 'numpy._core.tests.test_longdouble', 'numpy.linalg.tests.test_linalg', 'numpy.fft', \
'numpy.random']))" > "$here/numpy-native-subset.txt" 2>&1
r=$?
check subset $r "$(grep -a -E '[0-9]+ (passed|failed)' "$here/numpy-native-subset.txt" | tail -n 1)"
echo "NPN end $ok/$n"

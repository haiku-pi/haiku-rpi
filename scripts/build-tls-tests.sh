#!/usr/bin/env bash
# build-tls-tests.sh — cross-build the thread-local storage tests of tools/haiku-tests into one directory, as
# tools/pi-tests/tls-tests.sh runs them (copy the directory to /boot/home/tls):
#
#   scripts/build-tls-tests.sh [--arch x86_64] OUTDIR
#
# tlsstatic (+ libtlss, libtlsd, libtlsp): TLS in the program, a linked library, a dlopen()ed one, an add-on
# preloaded by LD_PRELOAD_ADDONS; tlsreload (+ libtlsr), tlsunload (+ libtlsa, libtlsb): unload/reload;
# tlsbench (+ libtlsbench, a copy libtlsbench2 to dlopen): ns per access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc"
sysroot="$root/artifacts/sysroot-arm64"
if [ "${1:-}" = --arch ]; then
	# x86_64 (H22): scripts/build-x86.sh's cross tools, scripts/haiku-sysroot.sh --arch x86_64
	[ "$2" = x86_64 ] || { echo "build-tls-tests: --arch x86_64" >&2; exit 2; }
	g="$root/sources/haiku-x86/generated.x86_64/cross-tools-x86_64/bin/x86_64-unknown-haiku-gcc"
	sysroot="$root/artifacts/sysroot-x86_64"
	shift 2
fi
[ $# -eq 1 ] || { sed -n '5p' "$0" >&2; exit 2; }
out="$1"
mkdir -p "$out"
cc() { "$g" "--sysroot=$sysroot" -O2 -Wall "$@"; }
t="$root/tools/haiku-tests"

cc -fPIC -shared -DTLSSTATIC_LIB=1 -o "$out/libtlss.so" "$t/tlsstatic.c"
cc -fPIC -shared -DTLSSTATIC_LIB=2 -o "$out/libtlsd.so" "$t/tlsstatic.c" -L"$out" -ltlss
cc -fPIC -shared -DTLSSTATIC_LIB=3 -o "$out/libtlsp.so" "$t/tlsstatic.c"
cc -o "$out/tlsstatic" "$t/tlsstatic.c" -L"$out" -ltlss

cc -fPIC -shared -o "$out/libtlsr.so" "$t/tlsreload/libtlsr.c"
cc -o "$out/tlsreload" "$t/tlsreload/tlsreload.c"

cc -fPIC -shared -DTLSUNLOAD_LIB=11 -o "$out/libtlsa.so" "$t/tlsunload.c"
cc -fPIC -shared -DTLSUNLOAD_LIB=22 -o "$out/libtlsb.so" "$t/tlsunload.c"
cc -o "$out/tlsunload" "$t/tlsunload.c"

cc -fPIC -shared -DTLSBENCH_LIB -o "$out/libtlsbench.so" "$t/tlsbench.c"
cp "$out/libtlsbench.so" "$out/libtlsbench2.so"
cc -o "$out/tlsbench" "$t/tlsbench.c" -L"$out" -ltlsbench

cp "$root/tools/pi-tests/tls-tests.sh" "$root/tools/pi-tests/n5-tls.sh" "$out/"
echo "build-tls-tests: $(ls "$out" | wc -l) files in $out"

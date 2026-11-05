#!/usr/bin/env bash
# build-x86-tests.sh — cross-build the H22 test programs (docs/design/x86-64-check.md §4.2, §4.3) for
# x86_64 into one directory, for both x86_64 images: scripts/build-x86.sh's cross tools (GCC 13.3) against
# the sysroot of our tree (scripts/haiku-sysroot.sh --arch x86_64). A program that needs something only our
# tree has (e.g. _kern_team_memory_barrier, DT_RELR) fails to load on upstream's image: "n/a upstream".
#
#   scripts/build-x86-tests.sh [--sysroot DIR] OUTDIR
#
# OUTDIR/<test> for the single programs; OUTDIR/tls (scripts/build-tls-tests.sh --arch x86_64), OUTDIR/relr
# (relrtest + its libraries, linked with -z pack-relative-relocs), OUTDIR/dbg (dbgtarget C -O0 and C++ -O2,
# each with DWARF 4 and 5), OUTDIR/rw_lock_interrupt_test (copied from sources/haiku-x86's jam build:
# scripts/build-x86.sh build rpi4 rw_lock_interrupt_test; it links libroot's private rw_lock, which upstream's
# libroot exports too). Every program is tried; the failed ones are listed at the end (exit 1).
# Not built for x86_64: armdbg.c, kernel-tests/id-regs.c (arm64 only).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sysroot="$root/artifacts/sysroot-x86_64"
[ "${1:-}" = --sysroot ] && { sysroot="$(realpath "$2")"; shift 2; }
[ $# -eq 1 ] || { sed -n '7p' "$0" >&2; exit 2; }
out="$1"
tp="$root/sources/haiku-x86/generated.x86_64/cross-tools-x86_64/bin/x86_64-unknown-haiku-"
[ -x "${tp}gcc" ] || { echo "build-x86-tests: ${tp}gcc missing (scripts/build-x86.sh configure)" >&2; exit 1; }
[ -f "$sysroot/boot/system/develop/lib/libroot.so" ] \
	|| { echo "build-x86-tests: no sysroot $sysroot (scripts/haiku-sysroot.sh --arch x86_64)" >&2; exit 1; }
t="$root/tools/haiku-tests" k="$root/tools/kernel-tests"
priv="$sysroot/boot/system/develop/headers/private"
mkdir -p "$out/relr" "$out/dbg"
failed=()
cc() { "${tp}gcc" "--sysroot=$sysroot" "$@"; }
cxx() { "${tp}g++" "--sysroot=$sysroot" "$@"; }
try() {	# NAME CMD...: run CMD, note NAME if it fails
	local name="$1"; shift
	"$@" || failed+=("$name")
}

# THR
try threadstress cc -O2 -o "$out/threadstress" "$t/threadstress.c"
try threadbench cc -O2 -o "$out/threadbench" "$t/threadbench.c"
try forkbench cc -O2 -o "$out/forkbench" "$t/forkbench.c"
try exitthread cc -O2 -o "$out/exitthread" "$t/exitthread.c"
rwl="$root/sources/haiku-x86/generated.x86_64/objects/haiku/x86_64/release/tests/system/libroot/os"
try rw_lock_interrupt_test cp "$rwl/rw_lock_interrupt_test" "$out/"
try kill_race2 cxx -O2 -o "$out/kill_race2" "$t/killrace.cpp"
try spread cc -O2 -o "$out/spread" "$t/spread.c"
# LIBC
try strtest cc -O1 -fno-builtin -o "$out/strtest" "$t/strtest.c"
try polltest cc -O2 -o "$out/polltest" "$t/polltest.c"
try usercopy cc -O2 -o "$out/usercopy" "$t/usercopy.c"
try membarrier cc -O2 -o "$out/membarrier" "$t/membarrier.c" -lgnu
try strtold cc -O2 -o "$out/strtold" "$t/strtold.c"
try setrlimit cc -O2 -o "$out/setrlimit" "$t/setrlimit.c"
try castest-header cc -O2 -DCASTEST_HEADER_ONLY -c -o "$out/castest-header.o" "$t/castest.c"
try castest cc -O2 -o "$out/castest" "$t/castest.c" "$out/castest-header.o"
rm -f "$out/castest-header.o"
relr=(-O2 -Wl,-z,pack-relative-relocs)
try librelr cc "${relr[@]}" -fPIC -shared -o "$out/relr/librelr.so" "$t/relrlib.c"
try librelrdl cc "${relr[@]}" -fPIC -shared -DCHECK=relrdl_check -o "$out/relr/librelrdl.so" "$t/relrlib.c"
try relrtest cc "${relr[@]}" -o "$out/relr/relrtest" "$t/relrtest.c" -L"$out/relr" -lrelr -Wl,-rpath,'$ORIGIN'
# VM
for p in mmap-shared-mprotect fault-signal-blocked mprotect-unprotect-retry; do
	try "$p" cc -O2 -o "$out/$p" "$k/$p.c"
done
# FS
try bfsmeta cc -O2 -o "$out/bfsmeta" "$t/bfsmeta.c"
try bfsbits cc -O2 -o "$out/bfsbits" "$t/bfsbits.c"
try kdl cc -O2 -o "$out/kdl" "$t/kdl.c"
# APP, MEDIA, NET, PERF
try launchtime cxx -O2 -I "$priv/interface" -o "$out/launchtime" "$t/launchtime.cpp" -lbe
try bitmapcheck cxx -O2 -o "$out/bitmapcheck" "$t/bitmapcheck.cpp" -lbe
try drawbench cxx -O2 -o "$out/drawbench" "$t/drawbench.cpp" -lbe
try pmexit cxx -O2 -I "$priv/storage" -o "$out/pmexit" "$t/pmexit.cpp" -lbe
try keyinject cxx -O2 -I "$priv/app" -o "$out/keyinject" "$t/keyinject.cpp" -lbe
try tswatch cxx -O2 -o "$out/tswatch" "$t/tswatch.cpp" -lmedia -lbe
try systime cc -O2 -o "$out/systime" "$t/systime.c"
try dlopentime cc -O2 -o "$out/dlopentime" "$t/dlopentime.c"
try mmapcat cc -O2 -o "$out/mmapcat" "$t/mmapcat.c"
try resolvetime cc -O2 -o "$out/resolvetime" "$t/resolvetime.c" -lnetwork
# DBG
for v in 4 5; do
	try "dbgtarget-dw$v" cc -Wall -O0 -g "-gdwarf-$v" -o "$out/dbg/c-dw$v" "$t/dbgtarget.c"
	try "dbgtarget-cxx-dw$v" cxx -Wall -O2 -g "-gdwarf-$v" -o "$out/dbg/cxx-dw$v" "$t/dbgtarget-cxx.cpp"
done
# TLS
try tls "$root/scripts/build-tls-tests.sh" --arch x86_64 "$out/tls" > /dev/null

n=$(find "$out" -type f | wc -l)
if [ ${#failed[@]} -gt 0 ]; then
	echo "build-x86-tests: $n files in $out; FAILED: ${failed[*]}"
	exit 1
fi
echo "build-x86-tests: $n files in $out"

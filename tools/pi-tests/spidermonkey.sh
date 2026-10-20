#!/bin/sh
# spidermonkey.sh — a UserBootscript for the SpiderMonkey shell (scripts/build-spidermonkey.sh): `js`
# from artifacts/spidermonkey-tests/non-packaged (scripts/mkimage-pi4.sh --add-tree) runs the scripts
# of tools/spidermonkey-tests/ on the Pi:
#   hello      js -e: the shell starts
#   misc       Intl + time zone, recursion limit, promises, GC, helper-thread compile
#   jit-*      which tiers run: default (Ion), --no-ion (Baseline), --no-jit-backend (interpreter)
#   wasm-*     wasm compile + run + out-of-bounds traps (the signal handler), per wasm compiler
#   bench-*    the same workload per JIT mode; bench-checksum: all modes give the same result
# Serial console lines: "SMJ "; per test "SMJ <name> PASS" or "SMJ <name> FAIL exit N"; then
# "SMJ summary: N failed" and "SMJ end". Network interfaces are left alone.
sleep 20
out=/dev/dprintf
say() { echo "SMJ $*" > $out; }
bin=/boot/system/non-packaged/bin
dir=/boot/system/non-packaged/data/spidermonkey-tests
cd /tmp || exit 1
limit=""
command -v timeout > /dev/null 2>&1 && limit="timeout 600"
fails=0
# run NAME EXPECT JS-ARGS...: PASS when js exits 0 and its output contains EXPECT
run() {
	name=$1
	expect=$2
	shift 2
	say "$name: js $*"
	$limit "$bin/js" "$@" > /tmp/smj-$name.txt 2>&1
	status=$?
	while IFS= read -r line; do say "$name: $line"; done < /tmp/smj-$name.txt
	if [ $status -eq 0 ] && grep -q -- "$expect" /tmp/smj-$name.txt; then
		say "$name PASS"
	else
		say "$name FAIL exit $status"
		fails=$((fails + 1))
	fi
}
say "start: $(uname -a)"
run hello "hello 3" -e 'print("hello " + (1 + 2))'
run misc "misc OK" "$dir/misc.js"
run jit-default "ion=true" "$dir/jit.js"
run jit-noion "baseline=true ion=false" --no-ion "$dir/jit.js"
run jit-interp "baseline=false ion=false" --no-jit-backend "$dir/jit.js"
run wasm-default "wasm OK" "$dir/wasm.js"
run wasm-baseline "wasm OK" --wasm-compiler=baseline "$dir/wasm.js"
run wasm-ion "wasm OK" --wasm-compiler=optimizing "$dir/wasm.js"
run bench-jit "bench checksum" "$dir/bench.js"
run bench-noion "bench checksum" --no-ion "$dir/bench.js"
run bench-interp "bench checksum" --no-jit-backend "$dir/bench.js"
sums=$(cat /tmp/smj-bench-jit.txt /tmp/smj-bench-noion.txt /tmp/smj-bench-interp.txt |
	sed -n 's/^bench checksum //p' | sort -u)
if [ -n "$sums" ] && [ "$(echo "$sums" | wc -l)" -eq 1 ]; then
	say "bench-checksum PASS $sums in all three modes"
else
	say "bench-checksum FAIL: $(echo $sums)"
	fails=$((fails + 1))
fi
say "summary: $fails failed"
say end

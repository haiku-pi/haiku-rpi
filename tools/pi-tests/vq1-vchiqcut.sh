#!/bin/sh
# vq1-vchiqcut.sh N LABEL — VQ1's deterministic VCHIQ case: N runs of vchiq_test_cut (scripts/build-vchiq-test.sh;
# tools/haiku-tests/vq1-cut.c) next to this script, each "-b KB ITERS" (ARGS, default "1024 400"): the firmware's
# echo bulk test with its buffers in an area another thread cuts below them. Before the kernel fix a run ends in
# a PANIC in vchiq_haiku_buffer_unlock() (read the serial log); with it every run completes and its cuts wait.
# KILL=1: each run is killed (kill -9) after 2 s instead, then checked (team gone, no kept buffer, a normal run works).
# Lines "VQ1 <label> ..." (also on the serial console), the last "VQ1 <label> result: F of N runs failed".
n=${1:?usage: vq1-vchiqcut.sh N LABEL}
label=${2:?usage: vq1-vchiqcut.sh N LABEL}
dir=$(cd "$(dirname "$0")" && pwd)
args=${ARGS:-1024 400}
say() { echo "VQ1 $label $*"; echo "VQ1 $label $*" > /dev/dprintf; }
failed=0
i=0
clones() { listarea 1 | grep -a -c "vchiq bulk buffer"; }
while [ $i -lt "$n" ]; do
	i=$((i + 1))
	if [ -n "${KILL:-}" ]; then
		# KILL=1: kill -9 after 2 s, while the cuts wait for the transfers; then the team must be gone, no buffer
		# kept by the rescue, and a short normal run must work
		say "$i/$n started vchiq_test_cut -b 1024 2000, kill -9 after 2 s"
		"$dir/vchiq_test_cut" -b 1024 2000 > /tmp/vq1-cut.txt 2>&1 &
		pid=$!
		sleep 2
		kill -9 $pid
		wait $pid 2> /dev/null
		sleep 1
		left=$(ps | grep -a -c "vchiq_test_c[u]t -b 1024 2000")
		"$dir/vchiq_test_cut" -b 64 50 > /tmp/vq1-cut2.txt 2>&1
		rc=$?
		[ "$left" = 0 ] && [ "$(clones)" = 0 ] && [ $rc = 0 ] || failed=$((failed + 1))
		say "$i/$n killed: teams left $left, kept buffers $(clones); then -b 64 50: exit $rc"
		continue
	fi
	say "$i/$n started vchiq_test_cut -b $args"
	"$dir/vchiq_test_cut" -b $args > /tmp/vq1-cut.txt 2>&1
	rc=$?
	[ $rc = 0 ] || failed=$((failed + 1))
	say "$i/$n exit $rc: $(grep -a -E 'VQ1CUT|Elapsed|\*' /tmp/vq1-cut.txt | head -n 3 | tr '\n' ' ')"
done
say "result: $failed of $n runs failed"

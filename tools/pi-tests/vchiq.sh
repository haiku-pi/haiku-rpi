#!/bin/bash
# vchiq.sh — the /dev/vchiq checks on the Pi (H21, docs/design/vchiq.md §5), from the directory holding
# scripts/build-vchiq-test.sh's vchiq-gcmd and vchiq_test (default /boot/home/vchiq):
#
#   vchiq.sh [DIR]
#
# 1. Broadcom's functional test (vchiq_test -f) — first, on a fresh connection;
# 2. vchiq-gcmd: the ioctls by hand, gencmd round trips;
# 3. bulk echo through the firmware's test service: sizes from 1 KiB to 1 MiB, buffers off cache-line and page
#    alignment, control messages, pings;
# 4. clients killed while transfers are queued or while blocked, each followed by a bulk test and a look for
#    leftover kernel clones of their buffers;
# 5. the driver's report (cat /dev/vchiq): services left, interrupts.
# Lines start with "VCHIQ "; the last one is "VCHIQ result: N problems".
dir=${1:-/boot/home/vchiq}
cd "$dir" || exit 1
problems=0
fail() { echo "VCHIQ FAIL: $*"; problems=$((problems + 1)); }

run() {	# LABEL CMD...: the command's last line, its exit status
	local label=$1; shift
	"$@" > out.txt 2>&1
	local rc=$?
	echo "VCHIQ $label: rc=$rc: $(tail -n 1 out.txt)"
	[ $rc = 0 ] || { fail "$label"; tail -n 5 out.txt | sed 's/^/VCHIQ   | /'; }
}

run "functional (-f 1)" ./vchiq_test -f 1
./vchiq-gcmd > out.txt 2>&1 || fail "vchiq-gcmd"
grep -E "dequeue|completion measure|end:" out.txt | sed 's/^VCHIQTEST /VCHIQ gcmd /'

for args in "-b 1 50" "-a 3 5 -b 1 50" "-A 100 7 -b 17 20" "-a 31 1 -b 300 10" "-b 64 200" "-b 1024 20" \
		"-c 1000 200" "-p 1"; do
	run "vchiq_test $args" ./vchiq_test $args
done

clones() { listarea 1 | grep -c "vchiq bulk buffer"; }
for args in "-b 1024 2000" "-b 1 50000" "-p 1" "-c 4000 100000"; do
	./vchiq_test $args > /dev/null 2>&1 &
	pid=$!
	sleep 2
	kill -9 $pid 2> /dev/null
	wait $pid 2> /dev/null
	sleep 1
	echo "VCHIQ killed during $args: $(clones) clones left"
	[ "$(clones)" = 0 ] || fail "clones left after the kill during $args"
	run "  then -b 64 20" ./vchiq_test -b 64 20
done

# a client blocked in AWAIT_COMPLETION / DEQUEUE_MESSAGE only
./vchiq-gcmd version > /dev/null 2>&1 &
pid=$!
kill -9 $pid 2> /dev/null
wait $pid 2> /dev/null
run "gencmd after a killed client" ./vchiq-gcmd

cat /dev/vchiq > report.txt 2>&1 || fail "reading /dev/vchiq"
grep -E "^vchiq:|^gencmd version|^State|Stats:" report.txt | sed 's/^/VCHIQ report: /'
services=$(grep -c "^Service" report.txt)
echo "VCHIQ report: $services services: $(grep "^Service" report.txt | cut -c1-60 | tr '\n' ';')"
[ "$services" -le 2 ] || fail "services left over"
echo "VCHIQ semaphores: $(listsem 1 | grep -ci vchiq)"

echo "VCHIQ result: $problems problems"

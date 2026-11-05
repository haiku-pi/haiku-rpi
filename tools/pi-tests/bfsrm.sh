#!/bin/sh
# bfsrm.sh — the BFS `rm -rf` hang probe on the Pi (docs/design/bfs-rmrf-hang.md; x86-64 version:
# tools/x86-tests/bfsrm.sh), a UserBootscript for a network boot (scripts/pi-bfsrm.sh): makes a fresh BFS volume on
# the USB disk (/dev/disk/usb/*/0/raw ONLY: never the SD card), mounts it at /scratch, then ROUNDS times: bfsmeta
# 4000 files, `rm -rf` of them in the background, `sync`. The network disk is a fresh copy of the image, so every
# run is a first boot: the first-login PostInstallScript's `sync` runs beside round 1, the race of the hang.
# When rm is not done after HANG_SECS (default 60) the kernel debugger is entered with "bfsrm hang team <id>"
# (kdl, tools/haiku-tests/kdl.c), and the host types its commands. Needs /boot/home/bfsrm/{bfsmeta,kdl}.
# Serial lines "BFSRM ...": "info round N: ... PIS=<0|1>..." says whether the first-login script was still running
# while rm ran (the overlap); "result bfsrm PASS|FAIL"; "end".
out=/dev/dprintf
say() { echo "BFSRM $*" > $out; }
ROUNDS=${ROUNDS:-5}
HANG_SECS=${HANG_SECS:-60}
D=/boot/home/bfsrm
cd $D || { say "result bfsrm FAIL rc=1 no $D"; exit 1; }
[ -f rounds ] && ROUNDS=$(cat rounds)
[ -f hang-secs ] && HANG_SECS=$(cat hang-secs)
dev=$(ls /dev/disk/usb/*/0/raw 2> /dev/null | head -n 1)
case "$dev" in
/dev/disk/usb/*/0/raw) ;;
*) say "result bfsrm FAIL rc=1 no USB disk"; say end; exit 1 ;;
esac
say "info dev=$dev up $(date +%T)"
# (the network boot mounts only /boot; a stick the mount server had mounted would be a reason to stop, not to guess)
df 2> /dev/null | grep -a -q -F "$dev" && { say "result bfsrm FAIL rc=1 $dev is mounted"; say end; exit 1; }
mkfs -t bfs -q "$dev" scratch > /dev/null 2>&1
say "info mkfs exit=$?"
mkdir -p /scratch
mount -t bfs "$dev" /scratch
say "info mount exit=$? $(date +%T)"
df /scratch 2> /dev/null | grep -a -q 'Volume Name: "scratch"' || { say "result bfsrm FAIL rc=1 no scratch volume"; say end; exit 1; }
pis() { ps 2> /dev/null | grep -a -c 'PostInstallScr[i]pt'; }
# the first-login script's life, seen once a second (a change is a line "info pis=N", N the number of its processes)
( prev=x; while sleep 1; do c=$(pis); [ "$c" != "$prev" ] && { say "info pis=$c"; prev=$c; }; done ) &
sampler=$!
i=1
while [ "$i" -le "$ROUNDS" ]; do
	p0=$(pis)
	./bfsmeta /scratch/meta$i 4000 2>&1 | grep -a '4000 files' | while IFS= read -r l; do say "info round $i: $l"; done
	say "info round $i: bfsmeta done (PIS=$p0 $(pis)), removing, $(date +%T)"
	start=$(date +%s)
	rm -rf /scratch/meta$i &
	rmpid=$!
	n=0 seen=0
	while kill -0 $rmpid 2> /dev/null && [ "$n" -lt "$HANG_SECS" ]; do
		[ "$(pis)" != 0 ] && seen=1
		sleep 1
		n=$((n + 1))
	done
	if kill -0 $rmpid 2> /dev/null; then
		say "info round $i: rm (team $rmpid) still running after ${HANG_SECS}s, PIS seen=$seen"
		say "result bfsrm FAIL rc=1 rm hung in round $i, team $rmpid"
		kill $sampler
		./kdl "bfsrm hang team $rmpid"
		say end
		exit 1
	fi
	wait $rmpid
	say "info round $i: removed in $(($(date +%s) - start))s, PIS seen=$seen (now $(pis)), syncing"
	sync
	say "info round $i: synced"
	i=$((i + 1))
done
kill $sampler
say "result bfsrm PASS rc=0 $ROUNDS rounds"
say "info checkfs: $(checkfs -c /scratch 2>&1 | tr '\n' ';' | cut -c1-300)"
say end

#!/bin/sh
# bfsrm.sh — the BFS `rm -rf` hang probe (docs/design/bfs-rmrf-hang.md): bfsmeta 4000 files on the scratch
# disk, then `rm -rf` of them, ROUNDS times (default 5; a file "rounds" next to the tests overrides it). The rm runs
# in the background; when it is not done after HANG_SECS (default 60, or the file "hang-secs") s and ./kdl exists (tools/haiku-tests/kdl.c),
# the kernel debugger is entered with "bfsrm hang team <id>", so the host can read the state through the serial
# socket (scripts/kdl-x86.py, scripts/x86-bfsrm.sh). Serial lines "X86T bfsrm ...". Every run is a first boot, so
# the first-login PostInstallScript's `sync` runs beside round 1: the race of the hang.
G=bfsrm
X86T_LINES=200
ROUNDS=${ROUNDS:-5}
HANG_SECS=${HANG_SECS:-60}
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
[ -f rounds ] && ROUNDS=$(cat rounds)
[ -f hang-secs ] && HANG_SECS=$(cat hang-secs)
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }
i=1
while [ "$i" -le "$ROUNDS" ]; do
	./bfsmeta /scratch/meta$i 4000 2>&1 | grep -a '4000 files' | while IFS= read -r l; do say "info round $i: $l"; done
	say "info round $i: bfsmeta done, removing"
	start=$(date +%s)
	rm -rf /scratch/meta$i &
	rmpid=$!
	n=0
	while kill -0 $rmpid 2> /dev/null && [ "$n" -lt "$HANG_SECS" ]; do
		sleep 1
		n=$((n + 1))
	done
	if kill -0 $rmpid 2> /dev/null; then
		say "info round $i: rm (team $rmpid) still running after ${HANG_SECS}s"
		say "result bfsrm FAIL rc=1 rm hung in round $i, team $rmpid"
		[ -x ./kdl ] && ./kdl "bfsrm hang team $rmpid"
		say end
		exit 1
	fi
	wait $rmpid
	say "info round $i: removed in $(($(date +%s) - start))s, syncing"
	sync
	say "info round $i: synced"
	i=$((i + 1))
done
say "result bfsrm PASS rc=0 $ROUNDS rounds"
finish

#!/bin/sh
# bfsrep.sh — bfsmeta 4000 files, five times in a row, on the scratch disk (a timing A/B between two images:
# scripts/x86-test.sh bfsrep IMAGE --scratch IMG). Serial lines "X86T bfsrep ...": the "4000 files" summary of
# each round (its us/file) is in the "out" lines.
G=bfsrep
X86T_LINES=200
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }
for i in 1 2 3 4 5; do
	./bfsmeta /scratch/meta$i 4000 2>&1 | grep -a '4000 files' | while IFS= read -r l; do say "info round $i: $l"; done
	say "info round $i: bfsmeta done, removing"
	rm -rf /scratch/meta$i
	say "info round $i: removed, syncing"
	sync
	say "info round $i: synced"
done
say "result bfsrep PASS rc=0"
finish

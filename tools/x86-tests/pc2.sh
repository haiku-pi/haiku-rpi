#!/bin/sh
# pc2.sh — H22 FS power cut, second half: mounts the scratch disk that pc1.sh's run left after its power cut
# (the BFS journal is replayed), checks it with checkfs -c and bfsbits, lists what bfsmeta left, and writes to
# it again. Serial lines "X86T pc2 ...".
G=pc2
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
mount_scratch
[ -n "$scratch_dev" ] && say "result mount PASS rc=0 $scratch_dev" || say "result mount FAIL rc=1"
say "info files left: $(ls /scratch/pc.* 2> /dev/null | wc -l)"
checkfs -c /scratch > /tmp/cf.txt 2>&1
rc=$?
while IFS= read -r l; do say "out checkfs: $l"; done < /tmp/cf.txt
zeros=$(grep -a -c -E '^[[:space:]]0 blocks (not allocated|already set)' /tmp/cf.txt)
freed=$(grep -a -o -E '[0-9]+ blocks could be freed' /tmp/cf.txt)
errs=$(grep -a -c -E 'could not be opened|has wrong type|names don.t match|invalid b\+tree' /tmp/cf.txt)
if [ $rc = 0 ] && [ "$zeros" = 2 ] && [ "$errs" = 0 ]; then
	say "result checkfs PASS rc=$rc ($freed)"
else
	say "result checkfs FAIL rc=$rc zero counts $zeros of 2 (not allocated, already set), $freed, $errs node errors"
fi
sync
t bfsbits 120 '\(S - U = 0\)' ./bfsbits "$scratch_dev"
t write-after 300 'bfsmeta: 500 files' ./bfsmeta /scratch/after-$$ 500
rm -rf /scratch/after-$$
finish

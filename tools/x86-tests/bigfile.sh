#!/bin/sh
# bigfile.sh — large-file write + read + MD5 through BFS (re-check of x86-64-check.md §10): scripts/x86-test.sh
# bigfile IMAGE --scratch IMG [--scratch-disk ahci|nvme|virtio-scsi|usb] (IMG: a fresh 2 GB BFS volume "scratch").
# A 3 MiB + 4097 byte chunk of /dev/urandom is written N (default 360: 1.06 GiB) times in a row into one file on
# the scratch volume, so every chunk starts at a different offset inside the file's blocks (partial-block writes
# through the disk driver's bounce path). The expected MD5 comes from the same chunks piped straight into md5sum,
# not through the disk. The file's MD5 is taken from the cache, then again after unmount + mount (read back from
# the disk), then checkfs -c and bfsbits. Serial lines "X86T bigfile ...".
G=bigfile
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }
N=${BIGFILE_N:-360}
csize=$((3 * 1024 * 1024 + 4097))
chunk=/tmp/bigfile.chunk
head -c $csize /dev/urandom > $chunk
total=$((csize * N))
say "info chunk $csize bytes x $N = $total bytes ($((total / 1048576)) MiB)"
emit() { i=0; while [ $i -lt $N ]; do cat $chunk; i=$((i + 1)); done; }

emit | md5sum | cut -d' ' -f1 > /tmp/bigfile.want
want=$(cat /tmp/bigfile.want)
t0=$(date +%s)
emit > /scratch/big
wrc=$?
sync
t1=$(date +%s)
size=$(stat -c %s /scratch/big)
say "info write rc=$wrc size $size in $((t1 - t0)) s"
if [ $wrc = 0 ] && [ "$size" = "$total" ]; then
	say "result write PASS rc=0 $size bytes in $((t1 - t0)) s"
else
	say "result write FAIL rc=$wrc size $size, expected $total"
fi
got=$(md5sum /scratch/big | cut -d' ' -f1)
if [ "$got" = "$want" ]; then say "result md5-cached PASS rc=0 $got"; else say "result md5-cached FAIL rc=1 got $got want $want"; fi

cd /
unmount /scratch
urc=$?
mount_scratch
cd $X86T_DIR
t2=$(date +%s)
got=$(md5sum /scratch/big | cut -d' ' -f1)
t3=$(date +%s)
size=$(stat -c %s /scratch/big)
if [ $urc = 0 ] && [ -n "$scratch_dev" ] && [ "$got" = "$want" ] && [ "$size" = "$total" ]; then
	say "result md5-remount PASS rc=0 $got, size $size, read in $((t3 - t2)) s"
else
	say "result md5-remount FAIL rc=$urc got $got want $want size $size"
fi
checkfs -c /scratch > /tmp/cf.txt 2>&1
rc=$?
while IFS= read -r l; do say "out checkfs: $l"; done < /tmp/cf.txt
zeros=$(grep -a -c -E '^[[:space:]]0 blocks (not allocated|already set)' /tmp/cf.txt)
errs=$(grep -a -c -E 'could not be opened|has wrong type|names don.t match|invalid b\+tree' /tmp/cf.txt)
if [ $rc = 0 ] && [ "$zeros" = 2 ] && [ "$errs" = 0 ]; then
	say "result checkfs PASS rc=$rc"
else
	say "result checkfs FAIL rc=$rc zero counts $zeros of 2, $errs node errors"
fi
t bfsbits 120 '\(S - U = 0\)' ./bfsbits "$scratch_dev"
rm -f /scratch/big $chunk
finish

#!/bin/sh
# pcbig.sh — power cut during a large data write (H20 C4b: the page writer's transfer sizes), on the scratch disk
# (scripts/x86-test.sh pcbig IMAGE --scratch IMG [--scratch-disk ahci|nvme]; IMG: a 2 GB BFS volume "scratch").
# Two boots on the same scratch volume:
#   1st (no /scratch/safe.bin): 64 MiB of random data written + synced (safe.bin, its MD5 in safe.md5), then a
#       file of one random 4 MiB chunk synced and grown by that chunk every 50 ms to 1.4 GiB, synced again at
#       512 MiB; cut the power during it with
#       --until 'X86T pcbig info big 1024 MiB' (QMP quit through qemu-x86.sh --until)
#   2nd: mount (journal replay), checkfs -c, safe.bin's MD5 (must be unchanged), the cut file's size and how
#       many of its 4 MiB chunks hold what was written (info: data is not journaled), the synced first 512 MiB
#       chunk by chunk (graded), bfsbits,
#       then a new 256 MiB file written, its MD5 after unmount + mount, checkfs again; everything removed (the next
#       cut starts from an empty volume). Serial lines "X86T pcbig ...".
G=pcbig
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }

check_volume() {	# TEST
	checkfs -c /scratch > /tmp/cf.txt 2>&1
	rc=$?
	while IFS= read -r l; do say "out $1: $l"; done < /tmp/cf.txt
	zeros=$(grep -a -c -E '^[[:space:]]0 blocks (not allocated|already set)' /tmp/cf.txt)
	freed=$(grep -a -o -E '[0-9]+ blocks could be freed' /tmp/cf.txt)
	errs=$(grep -a -c -E 'could not be opened|has wrong type|names don.t match|invalid b\+tree' /tmp/cf.txt)
	if [ $rc = 0 ] && [ "$zeros" = 2 ] && [ "$errs" = 0 ]; then
		say "result $1 PASS rc=$rc ($freed)"
	else
		say "result $1 FAIL rc=$rc zero counts $zeros of 2, $freed, $errs node errors"
	fi
}

if [ ! -f /scratch/safe.bin ]; then
	head -c $((64 * 1048576)) /dev/urandom > /scratch/safe.bin
	md5sum < /scratch/safe.bin | cut -d' ' -f1 > /scratch/safe.md5
	sync
	say "result armed PASS rc=0 safe $(cat /scratch/safe.md5) on $scratch_dev"
	say end
	head -c $((4 * 1048576)) /dev/urandom > /scratch/chunk
	cp /scratch/chunk /scratch/big
	sync	# the cut file exists on disk with its first chunk: the cut leaves it in some state of growth
	i=1
	while [ $i -lt 360 ]; do
		cat /scratch/chunk >> /scratch/big
		sleep 0.05	# ~13 s to the cut: page writer runs and journal flushes happen during the write
		i=$((i + 1))
		[ $((i % 16)) = 0 ] && say "info big $((i * 4)) MiB"
		[ $i = 128 ] && sync && say "info big synced 512 MiB"
	done
	say "info big done (no cut)"
	exit 0
fi

say "result mount PASS rc=0 $scratch_dev"
check_volume checkfs-after-cut
want=$(cat /scratch/safe.md5)
got=$(md5sum < /scratch/safe.bin | cut -d' ' -f1)
[ "$got" = "$want" ] && say "result safe-md5 PASS rc=0 $got" || say "result safe-md5 FAIL rc=1 got $got want $want"
size=$(stat -c %s /scratch/big 2> /dev/null)
# BFS journals metadata, not data: the file's size after the replay can be ahead of the data that reached the
# disk, so chunks that differ from the original are reported (info), not graded
c=$(md5sum < /scratch/chunk | cut -d' ' -f1) n=0 same=0
while [ $(((n + 1) * 4194304)) -le "${size:-0}" ]; do
	[ "$(dd if=/scratch/big bs=4M skip=$n count=1 2> /dev/null | md5sum | cut -d' ' -f1)" = "$c" ] && same=$((same + 1))
	n=$((n + 1))
done
say "info big after the cut: ${size:-no file} bytes, $same of $n whole 4 MiB chunks as written"
# the first 512 MiB were synced before the cut: they must be there, every chunk as written
n=0 same=0
while [ $n -lt 128 ]; do
	[ "$(dd if=/scratch/big bs=4M skip=$n count=1 2> /dev/null | md5sum | cut -d' ' -f1)" = "$c" ] && same=$((same + 1))
	n=$((n + 1))
done
[ $same = 128 ] && say "result synced-data PASS rc=0 128 of 128 chunks" \
	|| say "result synced-data FAIL rc=1 $same of 128 synced chunks as written, size ${size:-no file}"
sync
t bfsbits 120 '\(S - U = 0\)' ./bfsbits "$scratch_dev"
rm -f /scratch/big
head -c $((256 * 1048576)) /dev/urandom > /scratch/after
want=$(md5sum < /scratch/after | cut -d' ' -f1)
sync
cd /
unmount /scratch
mount_scratch
cd $X86T_DIR
got=$(md5sum < /scratch/after | cut -d' ' -f1)
[ "$got" = "$want" ] && say "result after-md5 PASS rc=0 $got" || say "result after-md5 FAIL rc=1 got $got want $want"
rm -f /scratch/after /scratch/safe.bin /scratch/safe.md5 /scratch/chunk
sync
check_volume checkfs-end
finish

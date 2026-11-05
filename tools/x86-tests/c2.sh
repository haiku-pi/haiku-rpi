#!/bin/sh
# c2.sh — perf-round-h20.md C2 (page faults on files read around the faulting page) on x86-64 under KVM, run by
# scripts/x86-test.sh c2 IMAGE --scratch IMG --file artifacts/c2/x86/c2data.tar:/boot/home/x86t/c2data.tar (IMG: a
# fresh BFS volume "scratch", as for the FS group; the boot volume has no room). Boot 1 puts the test files on the
# scratch volume: the C2 data files (c2data/ + c2data.md5) and a copy of the largest library of /boot/system/lib
# in c2big/, then restarts, so that boot 2 finds all of it uncached. Boot 2: WebPositive
# launched cold and warm (packaged: unchanged by C2), dlopentime of that library from its package (warms its
# dependencies) and then of the BFS copy (first = cold: its pages come by page faults on a BFS file), each mapped
# data file's pages touched in one of four orders (mmapcat) and its MD5 compared with the host's, the fault-in
# rate per order; then powers off. Serial lines "X86T c2 ...".
G=c2
X86T_LINES=60
. /boot/home/x86t/lib.sh
state=/boot/home/c2.state
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
waitfor -m application/x-vnd.Be-TRAK
mount_scratch
[ -n "$scratch_dev" ] || { say "result mount FAIL rc=1 no scratch volume"; finish; exit 1; }
d=/scratch/c2
if [ $n = 1 ]; then
	big=$(ls -SL /boot/system/lib/*.so* | head -n 1)
	mkdir -p $d/c2big
	cp -L "$big" $d/c2big/
	(cd $d && tar xf /boot/home/x86t/c2data.tar)
	say "info boot1 copied $big ($(du -k $d/c2big | awk '{print $1}') KiB) and $(ls $d/c2data | wc -l) data files"
	sync
	sleep 2
	shutdown -r
	exit 0
fi
sleep 10
cd $X86T_DIR || { finish; exit 1; }
for round in cold warm; do
	./launchtime -q /boot/system/apps/WebPositive 120 < /dev/null > /tmp/lt.txt 2>&1
	say "info launch WebPositive $round $(grep -a -o 'window after [0-9]* ms' /tmp/lt.txt)"
	sleep 1
done
copy=$(ls $d/c2big/* | head -n 1)
name=${copy##*/}
t dlopentime-package 120 - ./dlopentime /boot/system/lib/$name 5
t dlopentime-bfs 120 - ./dlopentime $copy 5

cd $d
ok=0 bad=0 k=0
rm -f /tmp/c2-mm.txt
while read sum file; do
	case $((k % 4)) in 0) o=forward ;; 1) o=reverse ;; 2) o=stride ;; *) o=random ;; esac
	s=$($X86T_DIR/mmapcat $o "c2data/$file" 2>> /tmp/c2-mm.txt | md5sum | cut -d' ' -f1)
	if [ "$s" = "$sum" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); say "info mmap BAD $file $o"; fi
	k=$((k + 1))
done < c2data.md5
verdict=PASS
[ $bad = 0 ] && [ $ok = 24 ] || verdict=FAIL
say "result mmap-md5 $verdict rc=0 ok $ok bad $bad"
for o in forward reverse stride random; do
	say "info mmap rate $o $(grep "mmapcat: $o " /tmp/c2-mm.txt | awk '{p += $3; t += $5} END {printf "%d pages %.0f ms %.1f MB/s", p, t, t ? p * 4.096 / t : 0}')"
done
finish

#!/bin/sh
# c2.sh — a UserBootscript for cold-start read-ahead (perf-round-h20.md C2), on a card boot; put on a copy
# of an image with scripts/c2-image.sh. Round 1 is cold, later rounds warm: Terminal, WebPositive, the
# packaged Firefox and the same Firefox from a plain BFS directory (/boot/home/ffx), each to its first
# window (launchtime); with /boot/home/c2.mode = catall, round 1 first reads all files of the packaged
# Firefox (before its launch) and of the BFS tree (before its launch) with cat, timed. Then the mapped-file
# check: every file of /boot/home/c2data (never read before) mapped and its pages touched in one of four
# orders (mmapcat), the mapping's MD5 compared with the host's sum (c2data.md5), the fault-in rate per
# order; the same files by read() (md5sum -c); and the card's raw read times by request size (disklat).
# Serial lines "C2 ...", the last "C2 end". C2_ROUNDS (default 3).
sleep 25
out=/dev/dprintf
say() { echo "C2 $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
cd /boot/home || exit 1
mode=$(cat c2.mode 2> /dev/null || echo launch)
n=${C2_ROUNDS:-3}
say "mode $mode rounds $n"

launch() {	# LABEL APP: window and quit times
	./launchtime -q "$2" 120 > /tmp/c2-lt.txt 2>&1 < /dev/null
	w=$(grep -o 'window after [0-9]*' /tmp/c2-lt.txt | grep -o '[0-9]*$')
	q=$(grep -o 'gone after [0-9]*' /tmp/c2-lt.txt | grep -o '[0-9]*$')
	say "launch $1: window ${w:-none} ms quit ${q:-none} ms"
	sleep 3
}
catall() {	# DIR LABEL
	t0=$(date +%s%N); find "$1" -type f -exec cat {} + > /dev/null; say "cat $2 $(ms $t0) ms"
}

i=1
while [ $i -le $n ]; do
	launch Terminal-$i /boot/system/apps/Terminal
	launch WebPositive-$i /boot/system/apps/WebPositive
	[ $i = 1 ] && [ "$mode" = catall ] && catall /boot/system/apps/Firefox firefox-pkg
	launch Firefox-$i /boot/system/apps/Firefox/Firefox
	[ $i = 1 ] && [ "$mode" = catall ] && catall /boot/home/ffx firefox-bfs
	launch Firefox-bfs-$i /boot/home/ffx/Firefox
	i=$((i + 1))
done

ok=0 bad=0 k=0
rm -f /tmp/c2-mm.txt
while read sum name; do
	case $((k % 4)) in 0) o=forward ;; 1) o=reverse ;; 2) o=stride ;; *) o=random ;; esac
	s=$(./mmapcat $o "c2data/$name" 2>> /tmp/c2-mm.txt | md5sum | cut -d' ' -f1)
	if [ "$s" = "$sum" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); say "mmap BAD $name $o"; fi
	k=$((k + 1))
done < c2data.md5
say "mmap ok $ok bad $bad"
for o in forward reverse stride random; do
	say "mmap rate $o $(grep "mmapcat: $o " /tmp/c2-mm.txt | awk '{p += $3; t += $5} END {printf "%d pages %.0f ms %.1f MB/s", p, t, t ? p * 4.096 / t : 0}')"
done
say "read check $(cd c2data && md5sum -c ../c2data.md5 2>&1 | grep -c ': OK$') ok of $(wc -l < c2data.md5)"
./disklat /dev/disk/mmc/0/raw 100 2>&1 | while read l; do say "$l"; done
say end

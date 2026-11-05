#!/bin/sh
# c4b.sh — H20 C4b in a bench session (scripts/pi-session.sh): large writes and reads through BFS and the file
# cache, by request size, with every written byte checked (tools/haiku-tests/fcfile.c: offset-dependent content).
# DESTROYS the card's data (raw writes from 1 GiB on, a new BFS on PARTITION): restore the card's image afterwards
# (scripts/sd-cycle.sh --flash). The card's partition is mounted by its own path at /sd, never by mountvolume.
#
#   sh c4b.sh ab [PARTITION]          one A/B round on the card (default /dev/disk/mmc/0/1)
#   sh c4b.sh usb [DEV]               the same files on a new BFS on the USB disk (default the first
#                                     /dev/disk/usb/*/0/raw): 512 MiB write + fsync, cold read, checkfs
#   sh c4b.sh cut-write [PARTITION]   a new BFS, a 128 MiB file written + fsynced (must survive), then a 2 GiB
#                                     write left running in the background: cut the power during it
#                                     (scripts/pi-session.sh stop --no-sync)
#   sh c4b.sh cut-check [PARTITION]   after the cut: mount (journal replay), checkfs -c, the synced file checked,
#                                     the cut file's size and content, a new file written and checked, checkfs again
#
# With fcfile, diskwrite and disklat (cross-built) in the current directory. Lines "C4B ...".
what=${1:-ab}
part=${2:-/dev/disk/mmc/0/1}
raw=/dev/disk/mmc/0/raw
mnt=/sd
say() { echo "C4B $*"; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }
rate() {	# MIB START_MS
	t=$(($(now_ms) - $2)); echo "$1 MiB in $t ms, $(awk -v b=$(($1 * 1048576)) -v t=$t 'BEGIN { printf "%.2f", b / t / 1000 }') MB/s"
}
remount() { sync; unmount $mnt || say "unmount FAILED"; mount -t bfs $part $mnt || { say "mount FAILED"; exit 1; }; }
fc() { r=$(./fcfile "$@" 2>&1); say "$r"; }
md5() { md5sum < "$1" | cut -d' ' -f1; }

case $what in
ab)
	# controls: the card's raw rates in this session (the raw path is not changed by C4b)
	say "$(./diskwrite $raw seq 1024 1024 256 2>&1)"
	./disklat $raw 50 2>&1 | grep -E '(4|128|1024) KiB' | while read l; do say "raw $l"; done

	mkfs -t bfs -q $part C4B > /dev/null || { say "no mkfs"; exit 1; }
	mkdir -p $mnt && mount -t bfs $part $mnt || { say "no mount"; exit 1; }
	mkdir -p $mnt/home
	# C4's test, comparable to its numbers: dd from /dev/zero in 1 MiB writes + fsync
	for mib in 128 128 128 1024 1024 1024; do
		sync; t0=$(now_ms)
		dd if=/dev/zero of=$mnt/home/zero.tmp bs=1M count=$mib conv=fsync 2> /dev/null
		say "bfs write $mib MiB + fsync: $(rate $mib $t0)"
		rm -f $mnt/home/zero.tmp
	done
	# files with checkable content, written in 4 KiB, 64 KiB, 128 KiB and 1 MiB requests (+ fsync)
	sync
	fc write $mnt/home/w4k.bin 64 4 4
	fc write $mnt/home/w64k.bin 64 64 64
	fc write $mnt/home/p128.bin 128 128 128
	fc write $mnt/home/p1g.bin 1024 1024 1024
	for f in w4k w64k p128 p1g; do eval "m_$f=$(md5 $mnt/home/$f.bin)"; say "md5 cached $f $(eval echo \$m_$f)"; done
	# cold reads (each after a remount: nothing of the volume stays cached), every byte checked
	remount; fc read $mnt/home/p1g.bin 1024 1024
	remount; fc read $mnt/home/p1g.bin 128 1024
	for bs in 4 64 128 512 1024; do remount; fc read $mnt/home/p128.bin $bs 128; done
	remount; fc read $mnt/home/w4k.bin 4 4
	remount; fc read $mnt/home/w64k.bin 64 64
	# the system's own tools, cold
	remount; t0=$(now_ms); cat $mnt/home/p128.bin > /dev/null; say "cat 128 MiB cold: $(rate 128 $t0)"
	remount; t0=$(now_ms); m=$(md5 $mnt/home/p1g.bin); say "md5sum 1 GiB cold: $(rate 1024 $t0)"
	[ "$m" = "$m_p1g" ] && say "md5 remount p1g same" || say "md5 remount p1g DIFFERENT"
	remount; t0=$(now_ms); cp $mnt/home/p128.bin $mnt/home/copy.bin && sync; say "cp 128 MiB cold + sync: $(rate 128 $t0)"
	remount
	for f in w4k w64k p128; do
		[ "$(md5 $mnt/home/$f.bin)" = "$(eval echo \$m_$f)" ] && say "md5 remount $f same" || say "md5 remount $f DIFFERENT"
	done
	[ "$(md5 $mnt/home/copy.bin)" = "$m_p128" ] && say "md5 remount copy same" || say "md5 remount copy DIFFERENT"
	fc check $mnt/home/copy.bin 128
	sync
	checkfs -c $mnt 2>&1 | while read l; do say "checkfs: $l"; done
	unmount $mnt
	;;
usb)
	dev=${2:-$(ls /dev/disk/usb/*/0/raw 2> /dev/null | head -n 1)}
	[ -n "$dev" ] && [ -e "$dev" ] || { say "usb: no USB disk"; exit 1; }
	part=$dev mnt=/usbc4b
	mkfs -t bfs -q $dev usbc4b > /dev/null || { say "usb: no mkfs"; exit 1; }
	mkdir -p $mnt && mount -t bfs $dev $mnt || { say "usb: no mount"; exit 1; }
	sync
	fc write $mnt/u512.bin 512 1024 512
	m=$(md5 $mnt/u512.bin)
	remount; fc read $mnt/u512.bin 1024 512
	remount; [ "$(md5 $mnt/u512.bin)" = "$m" ] && say "usb md5 remount same $m" || say "usb md5 remount DIFFERENT"
	checkfs -c $mnt 2>&1 | while read l; do say "usb checkfs: $l"; done
	unmount $mnt
	;;
cut-write)
	mkfs -t bfs -q $part C4B > /dev/null || { say "no mkfs"; exit 1; }
	mkdir -p $mnt && mount -t bfs $part $mnt || { say "no mount"; exit 1; }
	mkdir -p $mnt/home
	fc write $mnt/home/safe.bin 128 1024 77
	sync
	say "safe md5 $(md5 $mnt/home/safe.bin)"
	nohup ./fcfile write $mnt/home/cut.bin 2048 1024 99 > /tmp/c4b-cut.out 2>&1 &
	say "cut write started, pid $!"
	;;
cut-check)
	mkdir -p $mnt
	t0=$(now_ms); mount -t bfs $part $mnt || { say "no mount"; exit 1; }
	say "mount after the cut (journal replay): $(($(now_ms) - t0)) ms"
	checkfs -c $mnt 2>&1 | while read l; do say "checkfs after cut: $l"; done
	fc check $mnt/home/safe.bin 77
	say "safe md5 $(md5 $mnt/home/safe.bin)"
	say "cut.bin size $(stat -c %s $mnt/home/cut.bin 2> /dev/null)"
	fc check $mnt/home/cut.bin 99
	rm -f $mnt/home/cut.bin
	fc write $mnt/home/after.bin 256 1024 55
	remount; fc read $mnt/home/after.bin 1024 55
	sync
	checkfs -c $mnt 2>&1 | while read l; do say "checkfs after rewrite: $l"; done
	unmount $mnt
	;;
esac
say done

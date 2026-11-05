#!/bin/sh
# sdwrite.sh — the SD card's raw write speed, the same requests on Haiku and on Linux (H20 C4). DESTROYS the
# card's data from OFFSET MiB on (default 1024): restore the card's image afterwards (scripts/sd-cycle.sh --flash).
#
#   Haiku (a network session; the card is not mounted):  sh sdwrite.sh [OFFSET_MIB] [sweep | sizes | ab | write SLOT | read SLOT | bfs [PARTITION]]
#     with diskwrite, disklat (tools/haiku-tests, cross-built) and pattern.bin (64 MiB) in the current directory
#   Linux (the flash lane): a job script that fetches this one and runs it the same way, e.g.
#     scripts/sd-cycle.sh --script JOB --script-file tools/pi-tests/sdwrite.sh --script-file diskwrite-linux \
#       --script-file pattern.bin --script-secs 2400
#   (the flash lane makes the card read-only for a script: undone here; the queue limits, the bus mode and
#   /sys/block/mmcblk0/stat — the average request size — are printed too)
#
# sweep: dd and diskwrite (tools/haiku-tests/diskwrite.c) sequential writes of 4 KiB … 1 MiB requests (64 MiB each,
# 16 MiB for 4 KiB), 1 MiB requests for 64 MiB, 256 MiB and 1 GiB (three times each), 4 KiB random writes within
# 1 GiB, and dd reads of 1 MiB for the read rate of the same session. sizes: three rounds of 128 MiB in 128 KiB …
# 4 MiB requests. write SLOT: pattern.bin (64 MiB; next to this script, or served by the flash lane) written at
# OFFSET + 4096 + 64 * SLOT MiB, then its SHA-256 read back; read SLOT: only the read-back (for the other system's
# write). bfs: a new BFS on the card's partition (Haiku), mounted at /sd by its own path (never mountvolume -all),
# 128 MiB (3×) and 1 GiB files written + fsync, pattern.bin copied there and its SHA-256 read after a remount.
# ab: sizes, 1 GiB three times, disklat (raw reads by size) and bfs — one A/B round.
# Lines "SDW ...".
off=${1:-1024}
what=${2:-sweep}
if [ "$(uname)" = Haiku ]; then
	dev=/dev/disk/mmc/0/raw
	dw=./diskwrite
	pat=./pattern.bin
	oflag="conv=fsync"
	iflag=""
else
	dev=/dev/mmcblk0
	cd /tmp || exit 1
	host=$(sed 's/.*hfl.host=\([^ ]*\).*/\1/' /proc/cmdline)
	port=$(sed 's/.*hfl.port=\([^ ]*\).*/\1/' /proc/cmdline)
	for f in diskwrite-linux pattern.bin; do [ -f $f ] || wget -q -O $f "http://$host:$port/$f" || rm -f $f; done
	chmod +x diskwrite-linux 2> /dev/null
	dw=./diskwrite-linux
	pat=./pattern.bin
	oflag="oflag=direct"
	iflag="iflag=direct"
	for b in $dev ${dev}p*; do [ -b $b ] && blockdev --setrw $b; done
	echo "SDW ro=$(blockdev --getro $dev) size=$(blockdev --getsize64 $dev)"
	[ $what = sweep ] && {
	mount -t debugfs debugfs /sys/kernel/debug 2> /dev/null
	cat /sys/kernel/debug/mmc0/ios 2> /dev/null | sed 's/^/SDW ios /'
	dmesg | grep -i 'mmc0' | sed 's/^/SDW /'
	q=/sys/block/mmcblk0/queue
	echo "SDW queue max_sectors_kb=$(cat $q/max_sectors_kb) max_hw_sectors_kb=$(cat $q/max_hw_sectors_kb) max_segments=$(cat $q/max_segments) max_segment_size=$(cat $q/max_segment_size)"
	}
fi
say() { echo "SDW $*"; }
now_ms() {	# busybox has no date +%N, and its dd prints no rate
	if [ -r /proc/uptime ]; then awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime; else echo $(($(date +%s%N) / 1000000)); fi
}
rate() {	# MIB START_MS
	t=$(($(now_ms) - $2)); echo "$1 MiB in $t ms, $(awk -v b=$(($1 * 1048576)) -v t=$t 'BEGIN { printf "%.2f", b / t / 1000 }') MB/s"
}
ddw() {	# BS_KIB COUNT
	t0=$(now_ms)
	dd if=$pat of=$dev bs=$(($1 * 1024)) count=$2 seek=$((off * 1024 / $1)) $oflag 2> /dev/null
	say "dd write $1 KiB x $2: $(rate $(($1 * $2 / 1024)) $t0)"
}
stat_line() { [ -f /sys/block/mmcblk0/stat ] && say "stat $1 $(cat /sys/block/mmcblk0/stat)"; }

case $what in
sweep)
	[ -f $pat ] || dd if=/dev/urandom of=$pat bs=1M count=64 2> /dev/null
	for bs in 4 64 128 256 512 1024; do
		mib=64; [ $bs = 4 ] && mib=16
		stat_line "before-$bs"
		say "$($dw $dev seq $off $bs $mib 2>&1)"
		stat_line "after-$bs"
		ddw $bs $((mib * 1024 / bs))
	done
	for mib in 64 256 1024; do
		for n in 1 2 3; do say "$($dw $dev seq $off 1024 $mib 2>&1)"; done
	done
	say "$($dw $dev rand $off 4 2000 1024 2>&1)"
	say "$($dw $dev rand $off 64 500 1024 2>&1)"
	for n in 1 2; do
		t0=$(now_ms)
		dd if=$dev of=/dev/null bs=1M count=256 skip=$off $iflag 2> /dev/null
		say "dd read 1 MiB x 256: $(rate 256 $t0)"
	done
	;;
sizes)	# three rounds of 128 MiB written in 128 KiB, 512 KiB, 1 MiB and 4 MiB requests (the command size A/B)
	for round in 1 2 3; do
		for bs in 128 512 1024 4096; do say "round $round $($dw $dev seq $off $bs 128 2>&1)"; done
	done
	;;
write)	# pattern.bin into slot $3 (64 MiB each, from OFFSET + 4096 MiB), then read back
	say "pattern $(sha256sum < $pat | cut -d' ' -f1)"
	t0=$(now_ms)
	dd if=$pat of=$dev bs=1M seek=$((off + 4096 + ${3:-0} * 64)) $oflag 2> /dev/null
	say "pattern write slot ${3:-0}: $(rate 64 $t0)"
	[ -f /proc/sys/vm/drop_caches ] && { sync; echo 3 > /proc/sys/vm/drop_caches; }
	say "card slot ${3:-0} $(dd if=$dev bs=1M skip=$((off + 4096 + ${3:-0} * 64)) count=64 $iflag 2> /dev/null | sha256sum | cut -d' ' -f1)"
	;;
bfs)	# Haiku: the card's BFS partition ($3, default /dev/disk/mmc/0/1) mounted at /sd; 128 MiB written + synced
	# three times (iocheck.sh's test), 1 GiB once, each file removed again; unmounted
	# freshly initialized each time (the same state for every run; the raw tests overwrite it anyway)
	mkfs -t bfs -q ${3:-/dev/disk/mmc/0/1} SDWrite > /dev/null || { say "bfs: no mkfs"; exit 1; }
	mkdir -p /sd && mount -t bfs ${3:-/dev/disk/mmc/0/1} /sd || { say "bfs: no mount"; exit 1; }
	mkdir -p /sd/home
	for mib in 128 128 128 1024; do
		sync; t0=$(now_ms)
		dd if=/dev/zero of=/sd/home/sdwrite.tmp bs=1M count=$mib conv=fsync 2> /dev/null
		say "bfs write $mib MiB + fsync: $(rate $mib $t0)"
		rm -f /sd/home/sdwrite.tmp
	done
	# a file through the file cache and BFS, read back after a remount (not from the cache)
	cp $pat /sd/home/pattern.bin && sync && unmount /sd && mount -t bfs ${3:-/dev/disk/mmc/0/1} /sd \
		&& say "bfs file $(sha256sum < /sd/home/pattern.bin | cut -d' ' -f1)"
	sync; unmount /sd
	;;
ab)	# one A/B round (Haiku): sizes, 1 GiB three times, raw reads by size (disklat), the BFS tests
	sh $0 $off sizes | grep -v 'SDW done'
	for n in 1 2 3; do say "$($dw $dev seq $off 1024 1024 2>&1)"; done
	./disklat $dev 100 2>&1 | while read l; do say "$l"; done
	sh $0 $off bfs | grep -v 'SDW done'
	;;
read)	# slot $3 only
	say "card slot ${3:-0} $(dd if=$dev bs=1M skip=$((off + 4096 + ${3:-0} * 64)) count=64 $iflag 2> /dev/null | sha256sum | cut -d' ' -f1)"
	;;
esac
say done

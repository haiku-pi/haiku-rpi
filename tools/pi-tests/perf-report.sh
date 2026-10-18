#!/bin/sh
# perf-report.sh — UserBootscript for test images: raw sequential read rates of the SD card and
# the first USB disk, reported to the serial console as "PERF ..." lines (no grep/sed in the
# minimum image: shell builtins and coreutils only).
sleep 20
out=/dev/dprintf
say() { echo "PERF $*" > $out; }
say begin
for dev in /dev/disk/mmc/0/raw /dev/disk/usb/0/0/raw; do
	[ -e "$dev" ] || continue
	for spec in "4k 8192" "64k 1024" "1M 64"; do
		set -- $spec
		dd if="$dev" of=/dev/null bs=$1 count=$2 2>&1 | while read -r line; do say "$dev bs=$1 $line"; done
	done
done
say end

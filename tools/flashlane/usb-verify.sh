#!/bin/sh
# usb-verify.sh — a flash-lane script (scripts/sd-cycle.sh --script tools/flashlane/usb-verify.sh
# --script-file usb-verify.txt --script-file PATTERN...): what is on the first USB disk, as Linux reads it.
# usb-verify.txt, one command per line:
#   check MIB FILE   read 64 MiB at MIB (twice, O_DIRECT) and compare with FILE (served next to it, e.g. a
#                    tools/flashlane/usb-pattern.py pattern that Haiku wrote there): sha256, differing bytes,
#                    64-byte lines and 512-byte sectors
#   sum MIB          the sha256 of the 64 MiB at MIB (O_DIRECT), to compare with what Haiku read there
#   dump KIB         hexdump the first KIB KiB of the disk
#   wipe MIB         write zeros over the first MIB MiB of the disk (e.g. a broken file system that Haiku
#                    would otherwise try to mount) and read them back
# The SD card is read-only during flash-lane scripts; this one only ever writes the USB disk.
host=$(sed -n 's/.*hfl\.host=\([0-9.]*\).*/\1/p' /proc/cmdline); port=$(sed -n 's/.*hfl\.port=\([0-9]*\).*/\1/p' /proc/cmdline)
get() { wget -q -O "/tmp/$1" "http://$host:$port/$1"; }
dev=
i=0
while [ $i -lt 60 ]; do
	for b in /sys/block/sd*; do [ -e "$b/device/vendor" ] && dev=/dev/${b##*/}; done
	[ -n "$dev" ] && [ -b "$dev" ] && break
	i=$((i + 1)); sleep 1
done
[ -n "$dev" ] && [ "$dev" != /dev/mmcblk0 ] || { echo "UV no USB disk"; exit 1; }
b=${dev##*/}
echo "UV dev=$dev $(cat /sys/block/$b/device/vendor) $(cat /sys/block/$b/device/model)"
uncache() { sync; echo 3 > /proc/sys/vm/drop_caches; blockdev --flushbufs "$dev"; }
get usb-verify.txt || { echo "UV no usb-verify.txt"; exit 1; }

while read cmd a1 a2; do
	case "$cmd" in
	check)
		get "$a2" || { echo "UV no $a2"; continue; }
		want=$(sha256sum "/tmp/$a2" | cut -c1-16)
		for n in 1 2; do
			uncache
			dd if="$dev" of=/tmp/got bs=1M skip="$a1" count=64 iflag=direct 2>/dev/null
			got=$(sha256sum /tmp/got | cut -c1-16)
			# cmp -l: the 1-based offset of each differing byte
			d=$(cmp -l "/tmp/$a2" /tmp/got 2>/dev/null | awk '{ o = $1 - 1; n++
				if (int(o / 64) != l) { l = int(o / 64); nl++ }
				if (int(o / 512) != s) { s = int(o / 512); ns++ } }
				END { printf "differing bytes %d, 64-byte lines %d, sectors %d of 131072", n, nl, ns }' l=-1 s=-1)
			echo "UV check $a1+64MiB #$n vs $a2: sha $got want $want; $d"
		done
		rm -f "/tmp/$a2" /tmp/got ;;
	sum)
		uncache
		echo "UV sum $a1+64MiB: $(dd if="$dev" bs=1M skip="$a1" count=64 iflag=direct 2>/dev/null | sha256sum | cut -c1-16)" ;;
	dump)
		uncache
		echo "UV first $a1 KiB:"
		dd if="$dev" bs=1024 count="$a1" iflag=direct 2>/dev/null | hexdump -C | head -n 200 ;;
	wipe)
		uncache
		dd if=/dev/zero of="$dev" bs=1M count="$a1" oflag=direct conv=fsync 2>/dev/null
		uncache
		z=$(dd if=/dev/zero bs=1M count="$a1" 2>/dev/null | sha256sum | cut -c1-16)
		echo "UV wipe first $a1 MiB: read back $(dd if="$dev" bs=1M count="$a1" iflag=direct 2>/dev/null | sha256sum | cut -c1-16), zeros $z" ;;
	esac
done < /tmp/usb-verify.txt
echo "UV kernel messages (errors):"
dmesg | grep -i -E 'error|reset|fail|timeout' | grep -i -E 'usb|xhci|sd[a-z]|scsi' | tail -n 30
echo "UV done"

#!/bin/sh
# usb-check.sh — a flash-lane script (scripts/sd-cycle.sh --script tools/flashlane/usb-check.sh):
# the Linux reference for the first USB disk on the Pi (KNOWN-ISSUES C13). It reads the same regions
# several times with O_DIRECT and the page cache dropped (equal checksums = the device delivers its data
# consistently), writes a 64 MiB test pattern at 1 GiB into the disk (scratch: the disk's content is
# not kept there; the pattern is tools/flashlane/usb-pattern.py gen usb-pattern.bin 1024 64, served by
# sd-cycle.sh --script-file, and it stays on the disk as the ground truth for the same reads under
# Haiku), reads it back three times, measures sequential reads, and prints the kernel's USB messages.
# The SD card is read-only during flash-lane scripts; this one only ever writes the USB disk.
host=$(sed -n 's/.*hfl\.host=\([0-9.]*\).*/\1/p' /proc/cmdline); port=$(sed -n 's/.*hfl\.port=\([0-9]*\).*/\1/p' /proc/cmdline)
dev=
i=0
while [ $i -lt 60 ]; do
	for b in /sys/block/sd*; do [ -e "$b/device/vendor" ] && dev=/dev/${b##*/}; done
	[ -n "$dev" ] && [ -b "$dev" ] && break
	i=$((i + 1)); sleep 1
done
echo "UC dev=$dev after ${i}s"
for d in /sys/bus/usb/devices/*; do
	[ -f "$d/idVendor" ] && echo "UC usb ${d##*/} $(cat $d/idVendor):$(cat $d/idProduct) speed=$(cat $d/speed) $(cat $d/manufacturer 2>/dev/null) $(cat $d/product 2>/dev/null)"
done
for d in /sys/bus/usb/devices/*:*; do
	[ -L "$d/driver" ] && echo "UC intf ${d##*/} driver=$(basename "$(readlink "$d/driver")")"
done
[ -n "$dev" ] || { echo "UC no USB disk"; dmesg | tail -n 60; exit 1; }
b=${dev##*/}
echo "UC $b: $(cat /sys/block/$b/device/vendor) $(cat /sys/block/$b/device/model) rev $(cat /sys/block/$b/device/rev) sectors=$(cat /sys/block/$b/size) max_sectors_kb=$(cat /sys/block/$b/queue/max_sectors_kb)"
[ "$dev" != /dev/mmcblk0 ] || exit 1

uncache() { sync; echo 3 > /proc/sys/vm/drop_caches; blockdev --flushbufs "$dev"; }
now() { cut -d' ' -f1 /proc/uptime; }
# rd OFFSET_MIB COUNT_MIB: sha256 of that region read with O_DIRECT (1 MiB requests), and the rate
rd() {
	uncache
	t0=$(now)
	s=$(dd if="$dev" bs=1M skip="$1" count="$2" iflag=direct 2> /tmp/dd.err | sha256sum | cut -c1-16)
	t1=$(now)
	echo "$s $(tail -n 1 /tmp/dd.err) $(awk "BEGIN { printf \"%.1f MB/s\", $2 * 1.048576 / ($t1 - $t0) }")"
}

echo "UC first 4 KiB (as on the disk now):"
uncache; dd if="$dev" bs=4096 count=1 iflag=direct 2>/dev/null | hexdump -C | head -n 120
for n in 1 2 3 4 5; do echo "UC read 0+1MiB #$n: $(rd 0 1)"; done
for n in 1 2 3 4 5; do echo "UC read 0+64MiB #$n: $(rd 0 64)"; done
for n in 1 2 3; do echo "UC read 3000+64MiB #$n: $(rd 3000 64)"; done

echo "UC write test: the 64 MiB pattern at 1024 MiB"
wget -q -O /tmp/pat "http://$host:$port/usb-pattern.bin" || { echo "UC no usb-pattern.bin"; exit 1; }
want=$(sha256sum /tmp/pat | cut -c1-16)
uncache
dd if=/tmp/pat of="$dev" bs=1M seek=1024 oflag=direct conv=fsync 2> /tmp/dd.err
echo "UC wrote exit=$? $(tail -n 1 /tmp/dd.err) pattern=$want"
for n in 1 2 3; do echo "UC read 1024+64MiB #$n: $(rd 1024 64) want=$want"; done

echo "UC speed: 512 MiB sequential at 0"
for n in 1 2; do echo "UC read 0+512MiB #$n: $(rd 0 512)"; done

echo "UC kernel messages (USB, SCSI, disk):"
dmesg | grep -i -E 'usb|xhci|scsi|sd[a-z]|uas|reset|error|fail' | tail -n 80
echo "UC done"

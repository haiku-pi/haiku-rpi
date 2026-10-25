#!/bin/sh
# usbcheck.sh — a UserBootscript for USB mass-storage speed: raw sequential reads of the first USB disk
# (/dev/disk/usb/0/0/raw) with 64 KiB, 1 MiB and 4 MiB requests, raw reads by size (disklat), all after
# the boot settles. Serial lines "USB ...". Needs /boot/home/disklat (tools/haiku-tests/disklat.c).
out=/dev/dprintf
say() { echo "USB $*" > $out; }
dev=/dev/disk/usb/0/0/raw
sleep 25
[ -e $dev ] || { say "no $dev"; say done; exit 0; }
say "dd 64k: $(dd if=$dev of=/dev/null bs=64k count=4096 skip=1000 2>&1 | tail -1)"
say "dd 1M: $(dd if=$dev of=/dev/null bs=1M count=256 skip=600 2>&1 | tail -1)"
say "dd 4M: $(dd if=$dev of=/dev/null bs=4M count=64 skip=300 2>&1 | tail -1)"
/boot/home/disklat $dev 100 2>&1 | while read l; do say "$l"; done
say done

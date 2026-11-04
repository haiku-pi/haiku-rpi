#!/bin/sh
# usb-integrity.sh [read [DEV] | write MIB [DEV] | sum MIB [DEV]] — run on Haiku in a bench session (scripts/pi-ssh.sh): the Haiku half of
# docs/design/usb-storage-integrity.md (KNOWN-ISSUES C13). Default DEV: the first /dev/disk/usb/*/0/raw.
#   read:  the same regions read several times with dd (sha256 of each), the region at 1024 MiB saved to
#          /boot/home/usbint/pat-*.bin for tools/flashlane/usb-pattern.py cmp (tools/flashlane/usb-check.sh
#          writes the pattern there under Linux), with 1 MiB, 128 KiB and 4 KiB requests; the syslog's USB lines
#   write: /boot/home/usbint/patMIB.bin (usb-pattern.py gen ... MIB 64, copied over first) written at
#          MIB MiB, then read back three times (Linux reads it back afterwards: tools/flashlane/usb-verify.sh)
#   sum:   the sha256 of the 64 MiB at MIB MiB, read three times (to compare with what Linux reads there)
mode=${1:-read}
[ "$mode" = read ] || { mib=$2; shift; }
dev=${2:-$(ls /dev/disk/usb/*/0/raw 2>/dev/null | head -n 1)}
out=/boot/home/usbint
mkdir -p $out
[ -n "$dev" ] && [ -e "$dev" ] || { echo "UI no USB disk"; exit 1; }
echo "UI dev=$dev"
sum() { sha256sum | cut -c1-16; }
now() { date +%s.%N; }

if [ "$mode" = write ]; then
	[ -f $out/pat$mib.bin ] || { echo "UI no $out/pat$mib.bin"; exit 1; }
	echo "UI pattern $(sum < $out/pat$mib.bin)"
	dd if=$out/pat$mib.bin of=$dev bs=1M seek=$mib conv=notrunc 2>&1 | tail -n 1 | sed 's/^/UI wrote: /'
	sync
	for n in 1 2 3; do echo "UI read $mib+64MiB #$n: $(dd if=$dev bs=1M skip=$mib count=64 2>/dev/null | sum)"; done
	exit 0
fi
if [ "$mode" = sum ]; then
	for n in 1 2 3; do echo "UI read $mib+64MiB #$n: $(dd if=$dev bs=1M skip=$mib count=64 2>/dev/null | sum)"; done
	exit 0
fi

for n in 1 2 3; do echo "UI read 0+4KiB #$n: $(dd if=$dev bs=4k count=1 2>/dev/null | sum)"; done
dd if=$dev of=$out/head.bin bs=4k count=1 2>/dev/null
for n in 1 2 3 4 5; do echo "UI read 0+1MiB #$n: $(dd if=$dev bs=1M count=1 2>/dev/null | sum)"; done
for n in 1 2 3; do echo "UI read 0+64MiB #$n: $(dd if=$dev bs=1M count=64 2>/dev/null | sum)"; done
for n in 1 2 3; do
	t0=$(now)
	dd if=$dev of=$out/pat-1m-$n.bin bs=1M skip=1024 count=64 2>/dev/null
	t1=$(now)
	echo "UI read 1024+64MiB bs=1M #$n: $(sum < $out/pat-1m-$n.bin) $(echo "$t0 $t1" | awk '{ printf "%.1f MB/s", 64 * 1.048576 / ($2 - $1) }')"
done
dd if=$dev of=$out/pat-128k.bin bs=128k skip=8192 count=512 2>/dev/null
echo "UI read 1024+64MiB bs=128k: $(sum < $out/pat-128k.bin)"
dd if=$dev of=$out/pat-4k.bin bs=4k skip=262144 count=2048 2>/dev/null
echo "UI read 1024+8MiB bs=4k: $(sum < $out/pat-4k.bin) (8 MiB only)"
echo "UI syslog USB lines:"
grep -a -i -E 'usb_disk|xhci|usb error' /var/log/syslog | tail -n 40
echo "UI done"

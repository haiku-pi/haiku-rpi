#!/bin/sh
# hw-report.sh — a UserBootscript for test images (scripts/mkimage-pi4.sh --bootscript): waits
# for the desktop to settle, then reports hardware state to the serial console (/dev/dprintf).
# Every line starts with "HWR " so the capture can be graded.
sleep 20
out=/dev/dprintf
say() { echo "HWR $*" > $out; }
say "begin $(uname -a)"
for f in /dev/power/bcm2835_thermal/*; do
	[ -e "$f" ] && cat "$f" | while read -r line; do say "thermal $line"; done
done
listusb 2>/dev/null | while read -r line; do say "usb $line"; done
ls /dev/disk/usb/*/*/raw 2>/dev/null | while read -r line; do say "usbdisk $line"; done
ls /dev/net 2>/dev/null | while read -r line; do say "net $line"; done
ifconfig 2>/dev/null | while read -r line; do say "ifconfig $line"; done
sysinfo -cpu 2>/dev/null | head -n 12 | while read -r line; do say "cpu $line"; done
say end

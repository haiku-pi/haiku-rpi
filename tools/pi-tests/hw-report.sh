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
for g in /dev/gpio/bcm2835/*; do
	[ -e "$g" ] || continue
	head -n 16 "$g" | while read -r line; do say "gpio $line"; done
	# (the minimum image has no grep)
	pin() { while read -r n f l p; do [ "$n" = "$1" ] && echo "$f $l $p"; done < "$g"; }
	echo "out 21 1" > "$g"; say "gpio21 high: $(pin 21)"
	echo "out 21 0" > "$g"; say "gpio21 low: $(pin 21)"
	echo "in 21" > "$g"; say "gpio21 input: $(pin 21)"
done
listusb 2>/dev/null | while read -r line; do say "usb $line"; done
ls /dev/disk/usb/*/*/raw 2>/dev/null | while read -r line; do say "usbdisk $line"; done
ls /dev/net 2>/dev/null | while read -r line; do say "net $line"; done
# Ethernet: a static address on the bench's Pi LAN (no DHCP server runs there during SD boots)
for n in /dev/net/genet/*; do
	[ -e "$n" ] || continue
	ifconfig "$n" 10.42.0.50 255.255.255.0 up
	sleep 8
	ping -c 4 10.42.0.1 2>&1 | while read -r line; do say "ping $line"; done
done
ifconfig 2>/dev/null | while read -r line; do say "ifconfig $line"; done
sysinfo -cpu 2>/dev/null | head -n 12 | while read -r line; do say "cpu $line"; done
say end

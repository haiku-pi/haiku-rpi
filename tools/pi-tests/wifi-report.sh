#!/bin/sh
# wifi-report.sh — a UserBootscript for test images (scripts/mkimage-pi4.sh --bootscript): brings
# up the WiFi interface and reports what it sees to the serial console (/dev/dprintf).
# Every line starts with "WFR " so the capture can be graded.
sleep 15
out=/dev/dprintf
say() { echo "WFR $*" > $out; }
say "begin $(uname -a)"
ls /dev/net 2>/dev/null | while read -r line; do say "net $line"; done
for n in /dev/net/broadcomfmac/*; do
	[ -e "$n" ] || { say "no broadcomfmac device"; continue; }
	ifconfig "$n" up 2>&1 | while read -r line; do say "up $line"; done
	sleep 10
	ifconfig "$n" 2>&1 | while read -r line; do say "ifconfig $line"; done
	for i in 1 2 3; do
		ifconfig "$n" scan 2>&1 | while read -r line; do say "scan$i $line"; done
		sleep 5
	done
done
say end

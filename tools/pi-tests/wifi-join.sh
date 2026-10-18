#!/bin/sh
# wifi-join.sh — a UserBootscript template for test images: joins the bench's WiFi access point
# (WPA2) and reports to the serial console (/dev/dprintf), lines starting with "WFJ ".
# @SSID@, @PSK@ and @GATEWAY@ are filled in by scripts/wifi-join-image.sh into a temporary copy:
# the passphrase never goes into a repository.
sleep 15
out=/dev/dprintf
say() { echo "WFJ $*" > $out; }
say begin
for n in /dev/net/broadcomfmac/*; do
	[ -e "$n" ] || { say "no broadcomfmac device"; continue; }
	ifconfig "$n" up
	sleep 8
	ifconfig "$n" scan 2>&1 | while read -r line; do say "scan $line"; done
	ifconfig "$n" join "@SSID@" "@PSK@" 2>&1 | while read -r line; do say "join $line"; done
	for i in 1 2 3 4 5 6; do
		sleep 5
		ifconfig "$n" 2>&1 | while read -r line; do say "ifconfig$i $line"; done
	done
	ping -c 5 @GATEWAY@ 2>&1 | while read -r line; do say "ping $line"; done
done
say end

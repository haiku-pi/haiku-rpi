#!/bin/sh
# net-perf.sh — a UserBootscript template for test images: TCP throughput over Ethernet and WiFi
# against scripts/net-perf-server.sh on the bench host, "NPF " lines on the serial console.
# Joins the WiFi AP like wifi-join.sh (@SSID@, @PSK@, @GATEWAY@ filled in by
# scripts/wifi-join-image.sh --script tools/pi-tests/net-perf.sh).
sleep 15
out=/dev/dprintf
say() { echo "NPF $*" > $out; }
say begin
# needs tcp_throughput (src/tests/system/network/tcp_throughput, mkimage-pi4.sh --add-bin)
measure() {
	# $1 label, $2 host: 64 MiB up, then 64 MiB down
	tcp_throughput send $2 5001 64 2>&1 | while read -r line; do say "$1 upload $line"; done
	tcp_throughput receive $2 5002 2>&1 | while read -r line; do say "$1 download $line"; done
}
for n in /dev/net/genet/*; do
	[ -e "$n" ] || continue
	ifconfig "$n" 10.42.0.50 255.255.255.0 up
	sleep 8
	measure ethernet 10.42.0.1
	ifconfig "$n" down
done
for n in /dev/net/broadcomfmac/*; do
	[ -e "$n" ] || continue
	ifconfig "$n" up
	sleep 8
	ifconfig "$n" join "@SSID@" "@PSK@" 2>&1 | while read -r line; do say "join $line"; done
	sleep 20
	ifconfig "$n" 2>&1 | while read -r line; do say "ifconfig $line"; done
	measure wifi @GATEWAY@
done
say end

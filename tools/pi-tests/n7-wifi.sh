#!/bin/sh
# n7-wifi.sh — the measurements of H20 item N7 (the WiFi SDIO path waiting by spinning,
# docs/design/perf-round-h20.md "N7 results"), over ssh in a Pi session on a fresh boot, from /boot/home/n7
# (scripts/n7-wifi.sh copies this script and tcp_throughput there, and runs it):
#
#   WIFI passphrase on stdin | scripts/pi-ssh.sh sh /boot/home/n7/n7-wifi.sh LABEL SSID GATEWAY [RUNS]
#
# The passphrase is read from stdin (never on a "say" line, never in a file). Lines "N7 LABEL ...": WiFi
# bring-up (the driver's attach lines from the syslog, the time from `ifconfig up` + join to an IPv4 address),
# RUNS (default 3) uploads and downloads of 64 MiB with tcp_throughput against scripts/net-perf-server.sh on
# GATEWAY, each under `pmustat -A` (all CPUs: cycles, CPUs busy, per CPU) with the ARM clock sampled, two more of
# each with the clock held at 1500 MHz by a busy loop under `pmustat -k` (kernel cycles), then one of each under
# `profile -a -k -S -i 1000` (left in /tmp/n7-LABEL-up.prof / -down.prof); the SD card controller's
# attach lines and a raw read-only read of the card (dd to /dev/null, 64 MiB, twice; nothing is mounted);
# the sdhci/broadcomfmac syslog lines.
label=${1:-run} ssid=$2 gw=$3 runs=${4:-3}
pmu_args=
read -r psk
exec < /dev/null
cd /boot/home/n7 || exit 1
say() { echo "N7 $label $*"; }
say "image: $(uname -a | cut -c1-100)"
dev=
for i in $(seq 1 30); do
	for n in /dev/net/broadcomfmac/*; do [ -e "$n" ] && dev=$n; done
	[ -n "$dev" ] && break
	sleep 1
done
[ -n "$dev" ] || { say "bringup: no broadcomfmac device"; say end; exit 1; }
say "bringup: device $dev after ${i} s"
grep -a -i -E 'bwfm|broadcomfmac|firmware' /var/log/syslog | grep -a -v -i 'usb' | head -n 20 \
	| while read -r l; do say "syslog: $l"; done
# up, then join; once associated, DHCP (auto-config: a session image has no interface settings for it).
# DHCP started right after the association shows up can get no lease (seen twice on A): so a few seconds
# later, and the whole step again (join included) up to 3 times. The times count from the first join.
# An interface that already has an address (brought up by hand) is measured as it is.
addr=$(ifconfig "$dev" 2>/dev/null | grep -a -o 'inet addr: [0-9.]*' | awk '{ print $3 }')
if [ -n "$addr" ] && [ "$addr" != 0.0.0.0 ]; then
	say "bringup: already up ($addr): measured as it is"
	psk=
else
addr=
ifconfig "$dev" up
sleep 8
s=$(date +%s%N)
a=
for j in 1 2 3; do
	ifconfig "$dev" join "$ssid" "$psk" > /dev/null 2>&1
	for i in $(seq 1 40); do
		ifconfig "$dev" 2>/dev/null | grep -a -q "Network: $ssid" && break
		sleep 0.5
	done
	[ -n "$a" ] || a=$(date +%s%N)
	sleep 3
	ifconfig "$dev" auto-config > /dev/null 2>&1
	for i in $(seq 1 40); do
		addr=$(ifconfig "$dev" 2>/dev/null | grep -a -o 'inet addr: [0-9.]*' | awk '{ print $3 }')
		case "$addr" in ''|0.0.0.0) addr= ;; *) break 2 ;; esac
		sleep 0.5
	done
	say "bringup: attempt $j: no address ($(ifconfig "$dev" 2>/dev/null | grep -a -c "Network: $ssid") association)"
	tail -n 12 /var/log/syslog | grep -a -E 'bwfm|DHCP|link' | while read -r l; do say "bringup syslog: $l"; done
done
psk=
e=$(date +%s%N)
if [ -z "$addr" ]; then
	say "bringup: FAIL no address after $(( (e - s) / 1000000 )) ms (joins $j)"
	ifconfig "$dev" 2>&1 | while read -r l; do say "ifconfig: $l"; done
	say end
	exit 1
fi
say "bringup: ok $addr, associated after $(( (a - s) / 1000000 )) ms (joins $j), address after $(( (e - s) / 1000000 )) ms"
fi
route 2>&1 | grep -a -E 'broadcomfmac' | while read -r l; do say "route: $l"; done
ping -c 3 "$gw" 2>&1 | tail -n 2 | while read -r l; do say "ping: $l"; done

# tcp_throughput prints its rate on stdout, pmustat its counts on stderr
# the ARM clock every 0.25 s during a transfer (as tools/pi-tests/startcost-clock.sh)
clk_start() {
	rm -f /tmp/n7-clk-stop
	( while [ ! -f /tmp/n7-clk-stop ]; do grep -a Clocks /dev/power/bcm2835_thermal/0; sleep 0.25; done ) \
		> /tmp/n7-clk.txt 2>/dev/null &
	clkpid=$!
}
clk_stop() {
	touch /tmp/n7-clk-stop
	wait $clkpid
	say "$1 clock: $(grep -a -o 'ARM [0-9]*' /tmp/n7-clk.txt | sort | uniq -c | tr -s ' \n' ' ')"
}
measure() {
	# $1: up|down, $2: run
	clk_start
	if [ "$1" = up ]; then
		pmustat -A $pmu_args ./tcp_throughput send "$gw" 5001 64 > /tmp/n7-tp 2> /tmp/n7-pmu
	else
		pmustat -A $pmu_args ./tcp_throughput receive "$gw" 5002 > /tmp/n7-tp 2> /tmp/n7-pmu
	fi
	clk_stop "$1 $2"
	say "$1 $2: $(grep -a tcp_throughput /tmp/n7-tp)"
	grep -a -E '^ +[0-9,]+ +(cycles|cpu_cycles|inst_retired)|seconds elapsed|busy \(scheduler\)|^ (cycles|cpu_cycles) ' /tmp/n7-pmu \
		| while read -r l; do say "$1 $2 pmu: $l"; done
}
for r in $(seq 1 "$runs"); do
	measure up "$r"
	measure down "$r"
done
# the same with the ARM clock held at its maximum by a busy loop (the governor follows the load), counting
# kernel-mode cycles and instructions only (the busy loop runs in user mode; the WiFi path is in the kernel)
pmu_args="-k -e cpu_cycles,inst_retired"
sh -c 'while :; do :; done' &
spinner=$!
for r in 1 2; do
	measure up "pinned$r"
	measure down "pinned$r"
done
kill $spinner
pmu_args=
for d in up down; do
	prof=/tmp/n7-$label-$d.prof
	if [ $d = up ]; then
		profile -a -k -S -i 1000 -o $prof ./tcp_throughput send "$gw" 5001 64 > /tmp/n7-tp 2>&1
	else
		profile -a -k -S -i 1000 -o $prof ./tcp_throughput receive "$gw" 5002 > /tmp/n7-tp 2>&1
	fi
	say "$d profile: $(grep -a 'tcp_throughput:' /tmp/n7-tp)"
	grep -a -E 'total ticks|unknown ticks' $prof | while read -r l; do say "$d profile: $l"; done
	grep -a -E '^ +[0-9]+ +[0-9]+ +[0-9.]+ ' $prof | head -n 12 | while read -r l; do say "$d profile: $l"; done
done

# the SD card's controller (emmc2) shares the driver: attached and probed? (read-only, raw device, nothing mounted)
grep -a -i -E 'sdhci|mmc' /var/log/syslog | grep -a -v -i 'data blocks moved' | head -n 40 \
	| while read -r l; do say "sd syslog: $l"; done
ls /dev/disk/mmc/ 2>&1 | while read -r l; do say "sd dev: $l"; done
for i in 1 2; do
	dd if=/dev/disk/mmc/0/raw of=/dev/null bs=1M count=64 2>&1 | tail -n 1 | while read -r l; do say "sd dd $i: $l"; done
done
grep -a -E 'data blocks moved|CMD53|not ready|transfer complete|ended early|interrupt storm' /var/log/syslog \
	| while read -r l; do say "sdhci: $l"; done
say "sdhci lines: $(grep -a -c 'sdhci' /var/log/syslog)"
say end

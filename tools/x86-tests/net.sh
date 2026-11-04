#!/bin/sh
# net.sh — H22 test group NET (docs/design/x86-64-check.md §4.3) on QEMU user networking (10.0.2.0/24, gateway
# and DNS 10.0.2.2/10.0.2.3): DHCP lease, ping, DNS, HTTPS, pkgman refresh; then net_server restarted
# (launch_roster stop + start) while DHCP has the interface configured: the interface must get net_server's
# DHCP client again (haiku cb0f2f9884 left an interface with an IPv4 address alone, meant for a network boot):
# its DHCP exchange is in the syslog. Serial lines "X86T net ...".
G=net
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
dev=$(ls -d /dev/net/*/* 2> /dev/null | head -n 1)
say "info interface $dev"
lease() {	# TEST SECS: wait until the interface has a 10.0.2.x address
	i=0
	while [ $i -lt "$2" ]; do
		ifconfig "$dev" 2> /dev/null | grep -q 'inet addr: 10\.0\.2\.' && break
		sleep 1; i=$((i + 1))
	done
	ifconfig "$dev" > /tmp/if.txt 2>&1
	if grep -q 'inet addr: 10\.0\.2\.' /tmp/if.txt; then
		say "result $1 PASS rc=0 after $i s: $(grep 'inet addr' /tmp/if.txt | head -n 1 | tr -s ' \t' ' ')"
	else
		say "result $1 FAIL rc=1 no 10.0.2.x address after $2 s: $(tr '\n' ' ' < /tmp/if.txt | tr -s ' \t' ' ' | cut -c1-200)"
	fi
}
lease dhcp 60
t ping 30 ' 0.0% packet loss' ping -c 3 10.0.2.2
t dns 60 'gethostbyname ok.*getaddrinfo ok' ./resolvetime www.haiku-os.org
t https 120 '^200' curl -sS -o /dev/null -w '%{http_code}\n' https://www.haiku-os.org/
t pkgman-refresh 300 - pkgman refresh

say "info syslog net_server lines before the restart: $(grep -a -c net_server /var/log/syslog)"
mark=$(wc -l < /var/log/syslog)
launch_roster stop x-vnd.haiku-net_server
sleep 3
launch_roster start x-vnd.haiku-net_server
sleep 10
tail -n +"$((mark + 1))" /var/log/syslog | grep -a -i -E 'net_server|dhcp' | head -n 20 \
	| while IFS= read -r l; do say "out restart: $l"; done
if tail -n +"$((mark + 1))" /var/log/syslog | grep -a -q 'leaving it as it is'; then
	say "result restart-config FAIL rc=1 net_server left $dev unconfigured after its restart (no DHCP client)"
else
	say "result restart-config PASS rc=0 net_server configured $dev again"
fi
t https-after-restart 120 '^200' curl -sS -o /dev/null -w '%{http_code}\n' https://www.haiku-os.org/
t resolve-own-name 60 'gethostbyname ok' ./resolvetime "$(hostname)" localhost
finish

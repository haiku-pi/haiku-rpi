#!/bin/sh
# wifi-autojoin.sh — checks that a WiFi network joined once is joined again by net_server after a reboot
# (docs/design/wifi-autojoin.md), over ssh in a Pi session; run by scripts/wifi-autojoin.sh, which copies it to
# /boot/home/wifi-autojoin.sh and sends the passphrase on stdin:
#
#   passphrase | sh wifi-autojoin.sh join SSID     ifconfig up + join (the passphrase as the join's argument),
#                                                   wait for an address
#   passphrase | sh wifi-autojoin.sh joinbad SSID  the same with a wrong passphrase (its last character changed)
#   passphrase | sh wifi-autojoin.sh save SSID     write a saved-network entry with the passphrase by hand
#                                                   (what an older net_server cannot do itself)
#   passphrase | sh wifi-autojoin.sh check SSID GATEWAY [SECS] [NOW]
#                                                   no commands that change anything: wait up to SECS (default
#                                                   150) for the association and the address net_server makes by
#                                                   itself, then ping GATEWAY; NOW=now: report the state at once
#   passphrase | sh wifi-autojoin.sh down|up        take the interface down / bring it back (retry test)
#
# Lines "WAJ ...". The passphrase is only compared against (it is never printed): the saved-network file is
# reported as counts and names, never shown; the syslog lines shown are filtered against it, and the number of
# lines that held it is reported ("leak lines", must be 0).
mode=$1 ssid=$2 gw=$3 secs=${4:-150}
read -r psk
exec < /dev/null
say() { echo "WAJ $mode $*"; }
saved=/boot/system/settings/network/wireless_networks
dev=
for i in $(seq 1 30); do
	for n in /dev/net/broadcomfmac/*; do [ -e "$n" ] && dev=$n; done
	[ -n "$dev" ] && break
	sleep 1
done
[ -n "$dev" ] || { say "no broadcomfmac device"; exit 1; }
up_s() { date +%T; }
addr() { ifconfig "$dev" 2>/dev/null | grep -a -o 'inet addr: [0-9.]*' | awk '{ print $3 }'; }
associated() { ifconfig "$dev" 2>/dev/null | grep -a -q "Network: $ssid"; }
saved_report() {
	if [ -f "$saved" ]; then
		say "saved: $(grep -a -c '^network' "$saved") network block(s), names: $(grep -a -E '^\s*name' "$saved" \
			| awk '{ print $2 }' | tr '\n' ' ')password lines: $(grep -a -c -E '^\s*password' "$saved"), mode \
			$(ls -l "$saved" | awk '{ print $1 }'), passphrase present: $(grep -a -c -F -- "$psk" "$saved")"
	else
		say "saved: no $saved"
	fi
}
syslog_report() {
	say "syslog leak lines: $(grep -a -c -F -- "$psk" /var/log/syslog)"
	grep -a -E 'net_server|auto join|bwfm|broadcomfmac.*(link|join|scan)|DHCP|wlan|80211' /var/log/syslog \
		| grep -a -v -F -- "$psk" | grep -a -v -i 'usb' | tail -n "${1:-25}" | while read -r l; do say "syslog: $l"; done
}

case "$mode" in
join|joinbad)
	key=$psk
	if [ "$mode" = joinbad ]; then
		case "$psk" in *Z) key="${psk%?}Y" ;; *) key="${psk%?}Z" ;; esac
	fi
	ifconfig "$dev" up
	sleep 8
	s=$(date +%s)
	ifconfig "$dev" join "$ssid" "$key" > /tmp/waj-join.txt 2>&1
	rc=$?
	key=
	say "join: exit $rc, $(grep -a -v -F -- "$psk" /tmp/waj-join.txt | head -n 2 | tr '\n' ' ')"
	rm -f /tmp/waj-join.txt
	a=
	for i in $(seq 1 "$secs"); do
		a=$(addr)
		case "$a" in ''|0.0.0.0) a= ;; *) associated && break ;; esac
		sleep 1
	done
	say "result: associated $(associated && echo yes || echo no), address ${a:-none} after $(( $(date +%s) - s )) s"
	saved_report
	syslog_report 15
	;;
save)
	mkdir -p "$(dirname "$saved")"
	printf 'network {\n\tname "%s"\n\tpassword "%s"\n}\n' "$ssid" "$psk" >> "$saved"
	chmod 600 "$saved"
	saved_report
	;;
check)
	say "start: $(up_s)"
	saved_report
	s=$(date +%s) a=
	if [ "${5:-}" != now ]; then
		for i in $(seq 1 "$secs"); do
			a=$(addr)
			case "$a" in ''|0.0.0.0) a= ;; *) associated && break ;; esac
			sleep 1
		done
	fi
	a=$(addr)
	say "result: associated $(associated && echo yes || echo no), address ${a:-none} after $(( $(date +%s) - s )) s more, $(up_s)"
	ifconfig "$dev" 2>&1 | grep -a -E 'Network|inet addr|flags|Media|Hardware' | grep -a -v -F -- "$psk" \
		| while read -r l; do say "ifconfig: $l"; done
	case "$a" in ''|0.0.0.0) ;; *)
		ping -c 3 "$gw" 2>&1 | tail -n 2 | while read -r l; do say "ping: $l"; done ;;
	esac
	syslog_report
	;;
down)
	ifconfig "$dev" down
	sleep 2
	say "down: $(ifconfig "$dev" 2>&1 | grep -a -o 'flags.*' | head -n 1)"
	;;
up)
	ifconfig "$dev" up
	say "up: $(ifconfig "$dev" 2>&1 | grep -a -o 'flags.*' | head -n 1), $(up_s)"
	;;
*)
	say "unknown mode"
	exit 2
	;;
esac
psk=
say end

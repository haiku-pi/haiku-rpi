#!/usr/bin/env bash
# c1-heat-hunt.sh [--image IMG] [--trials N] [--soak SECS] [--off SECS] — KNOWN-ISSUES C1 with the condition the
# wedges came in on 10-29/30: the first network boot after a long, heavy session and a few minutes off (quick
# boot-and-off series stay cool and did not wedge: 0 in 44 overnight, the old driver included). Each trial: a
# network session (scripts/pi-session.sh, the regular image) with four CPU-bound loops for SOAK s (default 600),
# the SoC temperature before and after; the session stopped; then one scripts/c1-hunt.sh boot of IMG after OFF s
# (default 240). One line per trial on stdout. --sd: the boot under test is an SD boot of what the card holds
# (scripts/sd-cycle.sh, no flashing; --image is ignored), judged by "hardware cursor shown" within 150 s.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-regular.img" trials=6 soak=600 off=240
session="$root/artifacts/images/haiku-pi4-regular.img" sd=0
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--session-image) session="$(realpath "$2")"; shift 2 ;;
	--trials) trials="$2"; shift 2 ;;
	--soak) soak="$2"; shift 2 ;;
	--off) off="$2"; shift 2 ;;
	--sd) sd=1; shift ;;
	*) sed -n '2,10p' "$0" >&2; exit 2 ;;
	esac
done
temp='grep -a "Current Temperature" /dev/power/bcm2835_thermal/0 | tr -s " " | cut -c1-40'
for t in $(seq 1 "$trials"); do
	"$root/scripts/pi-session.sh" start --minutes $((soak / 60 + 10)) --image "$session" --label c1heat > /dev/null 2>&1 \
		|| { echo "trial $t: session did not start"; continue; }
	before=$("$root/scripts/pi-ssh.sh" "$temp" 2>/dev/null | tr -d '\r' | head -c 80)
	"$root/scripts/pi-ssh.sh" "for i in 1 2 3 4; do (while :; do :; done) & done; sleep $soak; $temp" \
		> /tmp/c1heat-$$.txt 2>&1 || true
	after=$(tr -d '\r' < /tmp/c1heat-$$.txt | tail -n 1 | head -c 80)
	"$root/scripts/pi-session.sh" stop > /dev/null 2>&1 || true
	if [ "$sd" = 1 ]; then
		sleep "$off"
		"$root/scripts/sd-cycle.sh" --secs 150 --label "c1sd-$t" --until 'hardware cursor shown' > /dev/null 2>&1 || true
		log=$(ls -t "$root"/artifacts/uart/*-c1sd-"$t".log | head -n 1)
		if grep -a -q 'hardware cursor shown' "$log"; then
			r="SD booted $log"
		else
			r="SD WEDGE $log; last line: $(grep -a -v '^\s*$' "$log" | tail -n 1 | cut -c1-120)"
		fi
	else
		r=$("$root/scripts/c1-hunt.sh" --image "$img" --trials 1 --off "$off" 2>&1 | grep '^trial' | sed 's/^trial 1: //')
	fi
	echo "trial $t (soak $soak s, before: $before, after: $after): $r" | cut -c1-260
done
rm -f /tmp/c1heat-$$.txt

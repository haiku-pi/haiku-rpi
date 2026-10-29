#!/usr/bin/env bash
# c1-hunt.sh [--image IMG] [--trials N] [--off SECS] — KNOWN-ISSUES C1, the network-boot wedge: N network boots
# (scripts/netboot-cycle.sh), each after the Pi has been off for SECS (default 240: on 10-29, 3 of 10 boots after
# 2-5 min off wedged, 0 of 151 after less), of a copy of IMG (default artifacts/images/haiku-pi4-regular.img; it
# needs a kernel with the "debug_heartbeat" setting, haiku rpi4 after 2486477fab) with the kernel settings
# "debug_heartbeat true" (each CPU writes "HB<cpu> <s> pc <pc> <k|u> thread <id>" to the serial line from its
# interrupt handler every 2 s, past the output queue and its lock) and "serial_debug_buffered false". A boot whose
# cursor does not appear within 150 s is a wedge: its last heartbeat line per CPU is printed (which CPUs still take
# interrupts, and what they interrupted; addr2line the pcs against the kernel). One line per trial on stdout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-regular.img" trials=10 off=240
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--trials) trials="$2"; shift 2 ;;
	--off) off="$2"; shift 2 ;;
	*) sed -n '2,9p' "$0" >&2; exit 2 ;;
	esac
done
hunt="$root/artifacts/images/c1-hunt.img"
settings="$(mktemp)"
printf 'debug_heartbeat true\nserial_debug_buffered false\n' > "$settings"
"$root/scripts/image-add.sh" "$img" "$hunt" "$settings:/boot/home/config/settings/kernel/drivers/kernel" > /dev/null
rm -f "$settings"
wedges=0
for t in $(seq 1 "$trials"); do
	sleep "$off"
	label="c1hunt-$t"
	"$root/scripts/netboot-cycle.sh" --image "$hunt" --secs 150 --label "$label" --until 'hardware cursor shown' \
		> /dev/null 2>&1 || true
	log=$(ls -t "$root"/artifacts/uart/*-"$label".log | head -n 1)
	if grep -a -q 'hardware cursor shown' "$log"; then
		echo "trial $t: booted ($(grep -a -c '^\[.*\] HB[0-3] ' "$log") heartbeat lines) $log"
		continue
	fi
	wedges=$((wedges + 1))
	echo "trial $t: WEDGE $log; last line: $(grep -a -v ' HB[0-3] ' "$log" | tail -n 1 | cut -c1-120)"
	for cpu in 0 1 2 3; do
		echo "  cpu $cpu: $(grep -a " HB$cpu " "$log" | tail -n 1 | cut -c1-120)"
	done
done
echo "c1-hunt: $wedges wedges in $trials boots after $off s off"

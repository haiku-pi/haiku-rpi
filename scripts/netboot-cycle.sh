#!/usr/bin/env bash
# netboot-cycle.sh — one Pi 4 cycle booting Haiku from the network (scripts/netboot-server.sh: TFTP for
# the firmware, U-Boot and the loader; the boot volume a remote disk served from IMG), under the bench
# lock: no SD card writing, so an image built a minute ago boots at once.
#
#   scripts/netboot-cycle.sh [--image IMG] [--secs N] [--label L] [--hdmi-every N]
#                            [--until RE]... [--fail RE]... [--send SECS:TEXT]... [--no-wedge-dump]
#
# IMG: default artifacts/images/haiku-pi4-regular.img (any image of scripts/mkimage-pi4.sh: its FAT
# partition gives the boot files, the whole image is the disk). Logs: artifacts/uart/<ts>-<label>.log,
# HDMI frames artifacts/hdmi/<ts>-<label>-*.png, the servers' logs in artifacts/netboot/state/ (the
# last cycle's), and artifacts/uart/<ts>-<label>-disk.txt: the remote disk's requests so far, every
# 5 s from power-on (a boot whose serial line went quiet but whose disk reads go on is alive).
# A boot whose serial line goes quiet for 20 s before app_server set its mode (the network-boot
# wedge) gets the kernel debugger's break and each CPU's stack crawl, ICIs and interrupts typed
# into it (uart-capture.py --silence-after); --no-wedge-dump: not.
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
img="$HAIKU_RPI_ROOT/artifacts/images/haiku-pi4-regular.img"
secs=200 label=netboot hdmi_every=20
caps=()
wedgeDump=1
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--hdmi-every) hdmi_every="$2"; shift 2 ;;
	--until|--fail|--send) caps+=("$1" "$2"); shift 2 ;;
	--no-wedge-dump) wedgeDump=0; shift ;;
	*) echo "netboot-cycle: unknown option $1" >&2; exit 2 ;;
	esac
done
if [ "$wedgeDump" = 1 ]; then
	caps+=(--silence-after 20 --silence-disarm 'hardware cursor shown' --silence-send '0:\x1d\x1d\x1dd')
	for cpu in 0 1 2 3; do
		caps+=(--silence-send "$((4 + cpu * 4)):cpu $cpu\n" --silence-send "$((5 + cpu * 4)):bt\n")
	done
	caps+=(--silence-send '22:ici\n' --silence-send '25:ints\n')
fi
ts="$(date +%Y%m%d-%H%M%S)"
uart_dir="$HAIKU_RPI_ROOT/artifacts/uart"; hdmi_dir="$HAIKU_RPI_ROOT/artifacts/hdmi"
mkdir -p "$uart_dir" "$hdmi_dir"

bench_lock
hdmi_pid="" disk_pid=""
cleanup() {
	[ -n "$hdmi_pid" ] && { pkill -P "$hdmi_pid" 2>/dev/null; kill "$hdmi_pid" 2>/dev/null; } || true
	[ -n "$disk_pid" ] && { pkill -P "$disk_pid" 2>/dev/null; kill "$disk_pid" 2>/dev/null; } || true
	pi_power off || true
	"$HAIKU_RPI_ROOT/scripts/netboot-server.sh" down >/dev/null 2>&1 || true
	peer_netboot_restore
}
trap cleanup EXIT

pi_power off >/dev/null 2>&1 || true
"$HAIKU_RPI_ROOT/scripts/netboot-server.sh" up "$img"
log="$uart_dir/$ts-$label.log"
"$PYTHON" "$HAIKU_RPI_ROOT/scripts/uart-capture.py" --dev "$PI_UART" --log "$log" --secs "$secs" \
	"${caps[@]}" &
cap_pid=$!
sleep 2
pi_power on
# (without the bench lock's fd 9: a sleep outliving the cycle would hold the bench)
( n=0; while sleep "$hdmi_every"; do n=$((n + 1)); hdmi_snap "$hdmi_dir/$ts-$label-$(printf %02d $n).png" || true; done ) 9>&- &
hdmi_pid=$!
disk_log="$HAIKU_RPI_ROOT/artifacts/netboot/state/disk.log"
( t=0; while sleep 5; do t=$((t + 5)); echo "$t s: $(wc -l < "$disk_log" 2>/dev/null || echo 0) requests"; done \
	> "$uart_dir/$ts-$label-disk.txt" ) 9>&- &
disk_pid=$!
rc=0; wait "$cap_pid" || rc=$?
hdmi_snap "$hdmi_dir/$ts-$label-final.png" || true
echo "netboot-cycle: capture rc=$rc log=$log"
grep -a -c 'READ request' "$HAIKU_RPI_ROOT/artifacts/netboot/state/disk.log" 2>/dev/null \
	| sed 's/^/netboot-cycle: remote disk reads: /' || true
exit "$rc"

#!/usr/bin/env bash
# sd-cycle.sh — one Pi 4 SD-card cycle, under the shared bench lock:
#   [--flash IMG]  netboot the Linux flash lane, write IMG to the Pi's SD card, verify its SHA-256
#   then           power-cycle with no DHCP server on the Pi LAN so the Pi boots the SD card,
#                  capture the UART (+ an HDMI frame every --hdmi-every s), power off,
#                  and restore the peer project's netboot server (the bench default).
#
#   scripts/sd-cycle.sh [--flash IMG] [--no-boot] [--secs N] [--label L] [--until RE]... [--fail RE]...
#
# Logs: artifacts/uart/<ts>-<label>.log (+ -flash.log), HDMI: artifacts/hdmi/<ts>-<label>-*.png.
# Exit: 0 boot capture ended on --until (or ran its full --secs with no --until), 1 flash failed,
# 3 a --fail line, 2 the UART stayed silent, 4 UART went quiet.
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
flash="" boot=1 secs=120 label=sd hdmi_every=20 quiet=0
caps=()
while [ $# -gt 0 ]; do
	case "$1" in
	--flash) flash="$(realpath "$2")"; shift 2 ;;
	--no-boot) boot=0; shift ;;
	--secs) secs="$2"; shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--until|--fail) caps+=("$1" "$2"); shift 2 ;;
	--quiet-secs) quiet="$2"; shift 2 ;;
	--hdmi-every) hdmi_every="$2"; shift 2 ;;
	*) echo "sd-cycle: unknown option $1" >&2; exit 2 ;;
	esac
done
ts="$(date +%Y%m%d-%H%M%S)"
uart_dir="$HAIKU_RPI_ROOT/artifacts/uart"; hdmi_dir="$HAIKU_RPI_ROOT/artifacts/hdmi"
mkdir -p "$uart_dir" "$hdmi_dir"
cap="$HAIKU_RPI_ROOT/scripts/uart-capture.py"

bench_lock
hdmi_pid=""
cleanup() {
	[ -n "$hdmi_pid" ] && kill "$hdmi_pid" 2>/dev/null || true
	pi_power off || true
	"$HAIKU_RPI_ROOT/scripts/flashlane-server.sh" down >/dev/null 2>&1 || true
	peer_netboot_restore
}
trap cleanup EXIT
pi_power off || true
sleep 4

if [ -n "$flash" ]; then
	www="$HAIKU_RPI_ROOT/artifacts/flashlane/www"; mkdir -p "$www"
	name="$(basename "$flash")"
	rm -f "$www/$name"; ln "$flash" "$www/$name" 2>/dev/null || cp "$flash" "$www/$name"
	size="$(stat -c %s "$flash")"; sha="$(sha256sum "$flash" | cut -d' ' -f1)"
	printf 'IMAGE=%s\nSIZE=%s\nSHA256=%s\n' "$name" "$size" "$sha" > "$www/job.txt"
	"$HAIKU_RPI_ROOT/scripts/flashlane-server.sh" up
	pi_power on
	flog="$uart_dir/$ts-$label-flash.log"
	"$PYTHON" "$cap" --dev "$PI_UART" --log "$flog" --secs 900 --until '^HFL end' || true
	grep -a '^\[.*\] HFL' "$flog" || true
	pi_power off
	"$HAIKU_RPI_ROOT/scripts/flashlane-server.sh" down
	if ! grep -aq "HFL done ok=1 sha256=$sha" "$flog"; then
		echo "sd-cycle: FLASH FAILED ($flog)" >&2; exit 1
	fi
	echo "sd-cycle: flashed $name ($size bytes, sha256 verified)"
	sleep 4
fi
[ "$boot" = 1 ] || exit 0

# SD boot: no DHCP server may answer on the Pi LAN, or the firmware netboots instead.
[ -x "$PEER_NETBOOT_DOWN" ] && (cd "$PEER_ROOT" && "$PEER_NETBOOT_DOWN") >/dev/null 2>&1 || true
log="$uart_dir/$ts-$label.log"
"$PYTHON" "$cap" --dev "$PI_UART" --log "$log" --secs "$secs" --quiet-secs "$quiet" "${caps[@]}" &
cap_pid=$!
sleep 0.5
pi_power on
( n=0; while sleep "$hdmi_every"; do n=$((n + 1)); hdmi_snap "$hdmi_dir/$ts-$label-$(printf %02d $n).png" || true; done ) &
hdmi_pid=$!
rc=0; wait "$cap_pid" || rc=$?
hdmi_snap "$hdmi_dir/$ts-$label-final.png" || true
echo "sd-cycle: boot capture rc=$rc log=$log"
exit "$rc"

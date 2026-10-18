#!/usr/bin/env bash
# sd-cycle.sh — one Pi 4 SD-card cycle, under the shared bench lock:
#   [--flash IMG]  netboot the Linux flash lane, write IMG to the Pi's SD card, verify its SHA-256
#   [--read-back FILE [--read-mb N] [--read-skip-mb N]]
#                  (instead of booting) netboot the flash lane and copy the card's first N MiB
#                  (default 400) to FILE, e.g. to read Haiku's syslog with scripts/sd-syslog.sh
#   then           power-cycle with no DHCP server on the Pi LAN so the Pi boots the SD card,
#                  capture the UART (+ an HDMI frame every --hdmi-every s), power off,
#                  and restore the peer project's netboot server (the bench default).
#
#   scripts/sd-cycle.sh [--flash IMG] [--no-boot] [--secs N] [--label L] [--until RE]... [--fail RE]...
#                       [--send SECS:TEXT]...   (typed into the UART, see uart-capture.py; three
#                       Ctrl-] then 'd' enters Haiku's kernel debugger: --send '150:\x1d\x1d\x1dd')
#                       [--no-probe]   (by default Ctrl-T is typed at 150 and 155 s: a kernel with the
#                                       freeze probe makes every CPU print its timer/interrupt state)
#
# Logs: artifacts/uart/<ts>-<label>.log (+ -flash.log), HDMI: artifacts/hdmi/<ts>-<label>-*.png.
# Exit: 0 boot capture ended on --until (or ran its full --secs with no --until), 1 flash failed,
# 3 a --fail line, 2 the UART stayed silent, 4 UART went quiet.
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
flash="" boot=1 secs=120 label=sd hdmi_every=20 quiet=0 readback="" readmb=400 readskip=0 probe=1
caps=()
while [ $# -gt 0 ]; do
	case "$1" in
	--flash) flash="$(realpath "$2")"; shift 2 ;;
	--no-boot) boot=0; shift ;;
	--read-back) readback="$(realpath -m "$2")"; boot=0; shift 2 ;;
	--read-mb) readmb="$2"; shift 2 ;;
	--read-skip-mb) readskip="$2"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--until|--fail|--send) caps+=("$1" "$2"); shift 2 ;;
	--quiet-secs) quiet="$2"; shift 2 ;;
	--hdmi-every) hdmi_every="$2"; shift 2 ;;
	--no-probe) probe=0; shift ;;
	*) echo "sd-cycle: unknown option $1" >&2; exit 2 ;;
	esac
done
[ "$probe" = 1 ] && caps+=(--send '150:\x14' --send '155:\x14')
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
if [ -n "$readback" ]; then
	www="$HAIKU_RPI_ROOT/artifacts/flashlane/www"; mkdir -p "$www"
	readport=$((FLASHLANE_PORT - 1))
	printf 'MODE=read\nOFFSET=%s\nSIZE=%s\nREAD_PORT=%s\n' "$readskip" "$readmb" "$readport" > "$www/job.txt"
	"$HAIKU_RPI_ROOT/scripts/flashlane-server.sh" up
	mkdir -p "$(dirname "$readback")"
	timeout 600 nc -l "$PI_LAN_HOST" "$readport" > "$readback.part" 9>&- &
	nc_pid=$!
	pi_power on
	rlog="$uart_dir/$ts-$label-readback.log"
	"$PYTHON" "$cap" --dev "$PI_UART" --log "$rlog" --secs 600 --until '^HFL end' || true
	grep -a '^\[.*\] HFL' "$rlog" || true
	pi_power off
	"$HAIKU_RPI_ROOT/scripts/flashlane-server.sh" down
	wait "$nc_pid" || true
	if [ "$(stat -c %s "$readback.part")" != $((readmb * 1048576)) ]; then
		echo "sd-cycle: READ-BACK FAILED, $(stat -c %s "$readback.part") bytes ($rlog)" >&2; exit 1
	fi
	mv "$readback.part" "$readback"
	echo "sd-cycle: read back $(stat -c %s "$readback") bytes -> $readback"
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

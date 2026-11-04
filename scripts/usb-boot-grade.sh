#!/usr/bin/env bash
# usb-boot-grade.sh LOG... — grade boot logs of scripts/boot-bench.sh for USB health (task 116, the USB
# enumeration stall): one line per log, then the totals.
#   desktop  boot-bench's test (app_server set its mode; Deskbar's and Tracker's windows in the thread list)
#   kbd/mouse  the input_server watcher threads "USB Keyboard 1 watcher" / "USB Mouse 1 watcher" in the
#            debugger's thread list (boot-bench types `threads` at 181 s)
#   stick    usb_disk publications (disk/usb/N/0/raw; more than 1 = the stick enumerated again)
#   reenum   "new device on a port that is already in use" (a device reconnected while still known)
#   errors   xHCI/USB error lines: transfer errors, TRBs not found, control timeouts, failed commands,
#            usb_disk failures, Host System Error
#   stall    no desktop and the log went quiet before the debugger
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
errRe='transfer error|was not found in the endpoint|timeout waiting for queued|unsuccessful command|halted endpoint|usb_disk: .*failed|Host System Error|could not stop endpoint'
n=0 desk=0 kbd=0 mouse=0 stick=0 reenum=0 errs=0
printf '%-48s %-7s %-4s %-5s %-5s %-6s %s\n' log desktop kbd mouse stick reenum errors
for log in "$@"; do
	d=no k=no m=no
	"$root/scripts/boot-bench.sh" --grade "$log" | grep -q PASS && d=yes
	grep -aq 'USB Keyboard 1 watcher' "$log" && k=yes
	grep -aq 'USB Mouse 1 watcher' "$log" && m=yes
	s=$(grep -a -c 'path disk/usb/[0-9]*/0/raw' "$log" || true)
	r=$(grep -a -c 'already in use' "$log" || true)
	e=$(grep -a -c -E "$errRe" "$log" || true)
	printf '%-48s %-7s %-4s %-5s %-5s %-6s %s\n' "$(basename "$log")" "$d" "$k" "$m" "$s" "$r" "$e"
	n=$((n + 1))
	[ $d = yes ] && desk=$((desk + 1))
	[ $k = yes ] && kbd=$((kbd + 1))
	[ $m = yes ] && mouse=$((mouse + 1))
	[ "$s" = 1 ] && stick=$((stick + 1))
	[ "$r" -gt 0 ] && reenum=$((reenum + 1))
	[ "$e" -gt 0 ] && errs=$((errs + 1))
done
echo "usb-boot-grade: $n boots: desktop $desk, keyboard $kbd, mouse $mouse, stick once $stick," \
	"re-enumerated $reenum, with USB errors $errs"

#!/usr/bin/env bash
# pi-snap-on.sh REMOTE-LOG OUTDIR [END-MARKER] [SECS] [ACK] — while a test runs on the Pi of a session
# (scripts/pi-session.sh), take an HDMI frame (scripts/hdmi-snap.sh) into OUTDIR/NAME.png each time a line
# "... SNAP NAME" appears in REMOTE-LOG; stop at a line containing END-MARKER (default "done") or after SECS
# (default 600). ACK: a path prefix on the Pi; after each frame the file ACK-NAME is created there, so a test
# can hold still until its frame is taken (tools/pi-tests/blender-m4.py waits for /tmp/bm4-ack-NAME).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n 2,5p "$0" >&2; exit 2; }
log=$1 dir=$2 end=${3:-done} secs=${4:-600} ack=${5:-}
mkdir -p "$dir"
seen=" "
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$secs" ]; do
	text="$("$root/scripts/pi-ssh.sh" cat "$log" 2> /dev/null || true)"
	for s in $(printf '%s\n' "$text" | sed -n 's/.* SNAP \([A-Za-z0-9._-]*\)$/\1/p'); do
		case "$seen" in *" $s "*) continue ;; esac
		"$root/scripts/hdmi-snap.sh" "$dir/$s.png" > /dev/null 2>&1 && echo "pi-snap-on: $s $(date +%T)" \
			|| echo "pi-snap-on: $s: no frame"
		seen="$seen$s "
		[ -z "$ack" ] || "$root/scripts/pi-ssh.sh" touch "$ack-$s" > /dev/null 2>&1 || true
	done
	printf '%s\n' "$text" | grep -q -- "$end" && exit 0
	sleep 1
done
echo "pi-snap-on: no \"$end\" within $secs s" >&2
exit 1

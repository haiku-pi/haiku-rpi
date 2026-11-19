#!/usr/bin/env bash
# hdmi-snap.sh OUT.png — one frame of the Pi's HDMI output now, from the capture card, during a running session
# (scripts/pi-session.sh; scripts/lib/bench.sh hdmi_snap). The session's cycle takes a frame every 5 minutes;
# when that holds the card, the snapshot is tried again a few times.
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
[ $# -eq 1 ] || { sed -n 2,4p "$0" >&2; exit 2; }
for try in 1 2 3 4; do
	if hdmi_snap "$1" && [ -s "$1" ]; then
		echo "hdmi-snap: $1"
		exit 0
	fi
	sleep 2
done
echo "hdmi-snap: no frame (no capture card, or it stayed busy)" >&2
exit 1

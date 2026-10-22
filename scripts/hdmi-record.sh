#!/usr/bin/env bash
# hdmi-record.sh OUT.mp4 SECS — a video of the Pi's HDMI output now, from the capture card, during a running
# session (scripts/pi-session.sh): start the program on the Pi over ssh, then record. The session's cycle takes
# a frame every 5 minutes; when that holds the card, the recording is tried again a few times.
set -euo pipefail
. "$(dirname "$0")/lib/bench.sh"
[ $# -eq 2 ] || { sed -n 2,4p "$0" >&2; exit 2; }
for try in 1 2 3; do
	if hdmi_record "$1" "$2" && [ -s "$1" ]; then
		echo "hdmi-record: $1 ($(stat -c %s "$1") bytes)"
		exit 0
	fi
	sleep 6
done
echo "hdmi-record: no video (no capture card, or it stayed busy)" >&2
exit 1

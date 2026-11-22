#!/bin/bash
# wp4-run.sh — WP4's checks of haikuwebkit 1.10.0-3 + the BAdapterIO end-of-stream fix on the session Pi
# (docs/design/webpositive-video-overlay.md §6), in /boot/home/wp1 (the kits of wp1-run.sh setup and wp3-run.sh setup).
#   tools/pi-tests/wp4-run.sh setup        copies wp4-mp.sh, wp3-seek.sh and, if WP4_STOCK_MEDIA is set, that libmedia.so
#                                          as /boot/home/wp1/stockmedia/libmedia.so (a control without the fix)
#   tools/pi-tests/wp4-run.sh LABEL CMD... runs CMD in /boot/home/wp1 on the Pi, an HDMI frame LABEL-NAME.png the
#                                          moment it prints "SNAP NAME"; output in artifacts/wp4/runs/LABEL.out
#   tools/pi-tests/wp4-run.sh H1 sh wp3-seek.sh paused http://10.42.0.1:8091/f/play-720p30.mp4 H1
#   tools/pi-tests/wp4-run.sh M1 sh wp4-mp.sh seek http://10.42.0.1:8091/f/play-720p30.mp4 M1
# The clips are served from the host by tools/pi-tests/wp4-httpd.py.
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
out=$R/artifacts/wp4/runs
D=/boot/home/wp1
mkdir -p "$out"
ssh_() { "$R/scripts/pi-ssh.sh" "$@"; }
if [ "${1:-}" = setup ]; then
	ssh_ put "$R/tools/pi-tests/wp4-mp.sh" "$R/tools/pi-tests/wp3-seek.sh" "$D/"
	if [ -n "${WP4_STOCK_MEDIA:-}" ]; then
		ssh_ "mkdir -p $D/stockmedia"
		ssh_ put "$WP4_STOCK_MEDIA" "$D/stockmedia/libmedia.so"
	fi
	ssh_ "cd $D && ls -l wp4-mp.sh wp3-seek.sh stockmedia 2>&1"
	exit 0
fi
label=$1
shift
ssh_ "cd $D && $*" 2>&1 | while IFS= read -r line; do
	echo "$line"
	case "$line" in
	*" SNAP "*) name=${line##* SNAP }
		"$R/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null 2>&1 && echo "snap $label-$name.png" ;;
	esac
done | tee "$out/$label.out"

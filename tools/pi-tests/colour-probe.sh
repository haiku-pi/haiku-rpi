#!/usr/bin/env bash
# colour-probe.sh OUTDIR [enc CODE...] [layout N...] — during a session (scripts/pi-session.sh) on an image with
# overlays above the desktop (driver setting overlay_above_desktop), shows tools/haiku-tests/sandprobe's
# pictures one at a time and takes an HDMI snapshot of each: OUTDIR/enc-CODE.png, OUTDIR/layout-N.png.
# sandprobe must be at /boot/home/v6/sandprobe on the Pi. Grade: tools/pi-tests/colour-probe.py OUTDIR/*.png
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 3 ] || { sed -n 2,5p "$0" >&2; exit 2; }
out=$1; shift
mkdir -p "$out"
kind=""
for a in "$@"; do
	case "$a" in
	enc|layout) kind=$a; continue ;;
	esac
	[ -n "$kind" ] || { echo "colour-probe: enc or layout first" >&2; exit 2; }
	# the picture stays up for 9 s; the snapshot after 4 s (the card skips 5 frames itself)
	"$root/scripts/pi-ssh.sh" "/boot/home/v6/sandprobe $kind $a 9" > "$out/$kind-$a.txt" 2>&1 &
	p=$!
	sleep 4
	"$root/scripts/hdmi-snap.sh" "$out/$kind-$a.png" > /dev/null || echo "colour-probe: no snapshot for $kind $a" >&2
	wait $p || true
	grep -a SND "$out/$kind-$a.txt" | sed -n 2p
done

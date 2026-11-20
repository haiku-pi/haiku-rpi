#!/usr/bin/env bash
# v6-colour-run.sh OUTDIR LABEL [ENV] -- CLIP... — during a session of tools/pi-tests/v6-session.sh: plays each
# clip (in /boot/home/v6 on the Pi) with MediaPlayer (MP=PATH on the Pi, default /boot/home/v6/new/MediaPlayer),
# takes an HDMI snapshot 7 s after the start (OUTDIR/LABEL-CLIP.png) and keeps the player's lines and the display
# driver's plane statistics (OUTDIR/LABEL-CLIP.txt); ENV (e.g. FFMPEG_YUV420=0) goes into the player's
# environment. Grade: tools/pi-tests/colour-bars.py OUTDIR/LABEL-CLIP.png OUTDIR/OTHER-CLIP.png
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 4 ] || { sed -n 2,7p "$0" >&2; exit 2; }
out=$1 label=$2; shift 2
envset=""
if [ "$1" != -- ]; then envset=$1; shift; fi
[ "$1" = -- ] && shift
mkdir -p "$out"
mp=${MP:-/boot/home/v6/new/MediaPlayer}
ssh_() { "$root/scripts/pi-ssh.sh" "$@"; }
for clip in "$@"; do
	name=${clip%.mp4}
	ssh_ "cd /boot/home/v6 && rmattr Media:Frame $clip 2>/dev/null; wc -l < /var/log/syslog > /tmp/v6-sl; (env $envset $mp /boot/home/v6/$clip > /tmp/v6-mp.txt 2>&1 &) ; sleep 1"
	sleep 6
	"$root/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null || echo "v6-colour: no snapshot for $clip" >&2
	sleep 4
	ssh_ "hey MediaPlayer quit > /dev/null 2>&1; sleep 2; for t in \$(ps | awk '\$1 ~ /MediaPlayer\$/ { print \$(NF-3) }'); do kill -9 \$t; done; \
		grep -a -E '^AVCodecDecoder|rpivid|MediaTrackVideoSupplier|NodeManager|VideoConsumer|falling back|sand' /tmp/v6-mp.txt | sort | uniq -c | head -n 12; \
		tail -n +\$(( \$(cat /tmp/v6-sl) + 1 )) /var/log/syslog | grep -a -E 'bcm2711_display: plane|rpivid' | tail -n 4" > "$out/$label-$name.txt" 2>&1 || true
	echo "== $label $name"; cat "$out/$label-$name.txt"
	python3 "$root/tools/pi-tests/colour-bars.py" "$out/$label-$name.png" || true
done

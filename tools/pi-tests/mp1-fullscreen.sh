#!/usr/bin/env bash
# mp1-fullscreen.sh OUTDIR [CASE...] — during a bench session (scripts/pi-session.sh): MediaPlayer's full-screen toggle
# while its video is on an overlay plane (docs/design/video-overlay.md §10, KNOWN-ISSUES F2): after the clip has
# ended, paused, and playing; to full screen and back. Per state an HDMI snapshot and a screenshot (OUTDIR/NAME-hdmi.png,
# NAME-shot.png) and a key census of the snapshot (tools/pi-tests/key-census.py: pixels of the overlay key colour
# left on the screen, where the colour bars are), in OUTDIR/census.txt; MediaPlayer's log lines in OUTDIR/NAME.txt.
#
#   setup            copies the kit (artifacts/s1/bin's screenread; the clips below) to /boot/home/mp1 (run first)
#   end-CLIP         CLIP (a 10 s colour-bar clip) played to its end, then full screen, then back
#   pause-CLIP       CLIP paused after 6 s, then full screen, then back
#   play-CLIP        CLIP playing: full screen after 5 s, back 4 s later
# CLIP: col-601-sd (H.264 720x480, 3:2: B_YUV420 plane), col-601-hevc (HEVC 1280x720: SAND plane), play-854x480
# (H.264, 2 min), play-hevc-720p30 (HEVC, 2 min). Default CASEs: setup and all of end/pause/play for the two codecs.
# PI_SESSION_LABEL as for scripts/pi-ssh.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 1 ] || { sed -n 2,14p "$0" >&2; exit 2; }
out=$1; shift
mkdir -p "$out"
h=/boot/home/mp1
ssh_() { "$root/scripts/pi-ssh.sh" "$@"; }

clip_file() {
	case "$1" in
	col-*) echo "$root/artifacts/v6-video/bin/$1.mp4" ;;
	play-854x480|play-hevc-720p30) echo "$root/artifacts/v1-overlay/clips/$1.mp4" ;;
	*) echo "mp1: unknown clip $1" >&2; return 1 ;;
	esac
}

# snap NAME: HDMI snapshot + screenshot of the same moment, the key census of both
snap() {
	local name=$1
	ssh_ "sleep 0.3; screenshot -s $h/out/$name-shot.png" > /dev/null 2>&1 || true
	"$root/scripts/hdmi-snap.sh" "$out/$name-hdmi.png" > /dev/null || echo "mp1: no HDMI snapshot for $name" >&2
	"$root/scripts/pi-ssh.sh" get "$h/out/$name-shot.png" "$out/" > /dev/null 2>&1 || true
	python3 "$root/tools/pi-tests/key-census.py" "$out/$name-hdmi.png" | sed "s/^/$(date +%T) /" | tee -a "$out/census.txt"
}

# player NAME CLIP: a new MediaPlayer on CLIP from its start (the remembered position forgotten)
player() {
	ssh_ "rmattr Media:Frame $h/$2.mp4 2> /dev/null; (/boot/system/apps/MediaPlayer $h/$2.mp4 > $h/out/$1.log 2>&1 &); true"
}
# (an unfixed MediaPlayer toggles but replies B_BAD_SCRIPT_SYNTAX: hey fails)
toggle() { ssh_ "hey MediaPlayer do ToggleFullscreen of Window 0 > /dev/null 2>&1" || true; }
quit() {
	local name=$1
	ssh_ "hey MediaPlayer quit > /dev/null 2>&1; sleep 2" || true
	ssh_ "for t in \$(ps | awk '\$1 ~ /MediaPlayer\$/ { print \$(NF-3) }'); do echo killed \$t; kill -9 \$t; done" || true
	ssh_ "grep -a -E '^AVCodecDecoder|rpivid|VideoConsumer|SAND|YUV|overlay|_ToggleFullscreen|saving current' $h/out/$name.log \
		| sort | uniq -c | head -n 16" > "$out/$name.txt" 2>&1 || true
}

case_end() {
	local clip=$1 name=end-$1
	player $name $clip
	sleep 16
	snap $name-1win
	toggle; sleep 3
	snap $name-2full
	toggle; sleep 3
	snap $name-3back
	quit $name
}

case_pause() {
	local clip=$1 name=pause-$1
	player $name $clip
	sleep 6
	ssh_ "hey MediaPlayer do TogglePlaying of Window 0 > /dev/null"; sleep 1
	snap $name-1win
	toggle; sleep 3
	snap $name-2full
	toggle; sleep 3
	snap $name-3back
	quit $name
}

case_play() {
	local clip=$1 name=play-$1
	player $name $clip
	sleep 5
	toggle; sleep 2
	snap $name-2full
	toggle; sleep 2
	snap $name-3back
	quit $name
}

run() {
	case "$1" in
	setup)
		ssh_ "mkdir -p $h/out"
		"$root/scripts/pi-ssh.sh" put "$root/artifacts/s1/bin/screenread" \
			"$(clip_file col-601-sd)" "$(clip_file col-601-hevc)" \
			"$(clip_file play-854x480)" "$(clip_file play-hevc-720p30)" "$h/"
		# the pointer out of the way (top right; at the bottom it shows the full-screen controls)
		ssh_ "$h/screenread -p 1919 0; ls $h" ;;
	end-*) case_end "${1#end-}" ;;
	pause-*) case_pause "${1#pause-}" ;;
	play-*) case_play "${1#play-}" ;;
	*) echo "mp1: unknown case $1" >&2 ;;
	esac
}

[ $# -gt 0 ] || set -- setup end-col-601-sd end-col-601-hevc pause-col-601-sd pause-play-854x480 pause-play-hevc-720p30 \
	play-play-854x480 play-play-hevc-720p30
for c in "$@"; do echo "== $c $(date +%T)"; run "$c"; done

#!/usr/bin/env bash
# s1-readback.sh OUTDIR [CASE...] — during a bench session (scripts/pi-session.sh) on an image whose app_server reads
# overlays back (docs/design/gpu-stage6.md §11): shows something on an overlay plane, then takes a screenshot on the
# Pi (the `screenshot` command, i.e. BScreen::GetBitmap()) and an HDMI snapshot of the same moment, and compares
# them (tools/pi-tests/shot-vs-hdmi.py, colour-bars.py). Per CASE: OUTDIR/CASE-shot.png, CASE-hdmi.png, CASE.txt
# (the program's lines, the display driver's plane lines, the comparison).
#
#   setup                      copies the kit (artifacts/s1/bin: overlaytest, screenread, glflip, uiinject; the colour
#                              clips of artifacts/v6-video/bin) to /boot/home/s1 (run first)
#   desk, desk-NAME            no overlay: the capture chain's own error, and today's screenshots unchanged
#   ovl-SPACE                  overlaytest -s SPACE (rgb32 yuv420 sand sand10; yuv420-720: 1280x720, BT.709):
#                              -cover (a window over the overlay), -off (partly off the screen), -hold, -part
#                              (a rectangle of the screen: screenread -r)
#   mp-CLIP                    MediaPlayer plays col-CLIP.mp4 (709-hd 601-sd 601full-hd 709-hevc 709-hevc10):
#                              windowed, -alert (an alert window over the video), -full (full screen, scaled)
#   pause-FILE                 MediaPlayer plays $h/FILE (copy it there first), paused after 6 s
#   ff                         Firefox plays col-709-hd.mp4 in a page (the video on the plane: firefox -11)
#   gl                         glflip -b: full-screen GL on a plane, still colour bars; gl-cover: with a window over it
# Default CASEs: all of them. The mouse pointer is put at the bottom right corner first (HDMI shows it, a screenshot
# without -m not). PI_SESSION_LABEL as for scripts/pi-ssh.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 1 ] || { sed -n 2,20p "$0" >&2; exit 2; }
out=$1; shift
mkdir -p "$out"
h=/boot/home/s1
ssh_() { "$root/scripts/pi-ssh.sh" "$@"; }

# snap NAME [RECT...]: screenshot + HDMI snapshot, compared (RECT: X,Y,W,H for shot-vs-hdmi.py)
snap() {
	local name=$1; shift
	ssh_ "$h/screenread -p 1919 1079; sleep 0.5; screenshot -s $h/out/$name-shot.png; $h/screenread $h/out/$name-sr.ppm"
	"$root/scripts/hdmi-snap.sh" "$out/$name-hdmi.png" > /dev/null || echo "s1: no HDMI snapshot for $name" >&2
	"$root/scripts/pi-ssh.sh" get "$h/out/$name-shot.png" "$out/" > /dev/null
	local args=()
	for r in "$@"; do args+=(--rect "$r"); done
	{
		echo "== $name"
		python3 "$root/tools/pi-tests/shot-vs-hdmi.py" "$out/$name-shot.png" "$out/$name-hdmi.png" "${args[@]}" || true
		python3 "$root/tools/pi-tests/colour-bars.py" "$out/$name-shot.png" "$out/$name-hdmi.png" 2>&1 || true
	} | tee -a "$out/$name.txt"
}

# wait_for FILE PATTERN [SECS]: until the Pi's FILE has a line matching PATTERN
wait_for() {
	local t
	for ((t = 0; t < ${3:-60}; t++)); do
		ssh_ "grep -a -q -E '$2' $1" 2>/dev/null && return 0
		sleep 1
	done
	echo "s1: '$2' not in $1 after ${3:-60} s" >&2
	return 1
}

mark_syslog() { ssh_ "wc -l < /var/log/syslog > /tmp/s1-sl"; }
planes() { ssh_ "tail -n +\$(( \$(cat /tmp/s1-sl) + 1 )) /var/log/syslog | grep -a -E 'bcm2711_display: (plane|overlay)' | tail -n 6" || true; }
kill_named() { ssh_ "for t in \$(ps | awk '\$1 ~ /$1\$/ { print \$(NF-3) }'); do kill -9 \$t; done" || true; }

case_ovl() {
	local space=$1 opts="" name=ovl-$1
	[ "$space" = yuv420-720 ] && { space=yuv420; opts="-x 1280x720"; }
	mark_syslog
	ssh_ "($h/overlaytest -s $space $opts -p 12 -h 15 > $h/out/$name.log 2>&1 &); sleep 1"
	# the window's content (the overlay) is at 100,100: 640x480 (twice 320x240), or 1280x720 as it is
	local w=640 hh=480
	[ -n "$opts" ] && { w=1280; hh=720; }
	wait_for $h/out/$name.log 'cover window shown' 40 && snap $name-cover "100,100,$w,$hh"
	wait_for $h/out/$name.log 'moved to' 20 && snap $name-off "0,100,$((w - 200)),$hh"
	wait_for $h/out/$name.log 'holding' 20 && snap $name-hold "100,100,$w,$hh"
	# a rectangle across the overlay's edge
	ssh_ "$h/screenread -r 60 150 400 300 $h/out/$name-part.ppm" | tee -a "$out/$name.txt"
	"$root/scripts/pi-ssh.sh" get "$h/out/$name-part.ppm" "$out/" > /dev/null
	python3 "$root/tools/pi-tests/shot-vs-hdmi.py" "$out/$name-part.ppm" "$out/$name-hold-hdmi.png" --crop 60,150 \
		| tee -a "$out/$name.txt" || true
	wait_for $h/out/$name.log 'end:' 40 || true
	{ ssh_ "grep -a OVL $h/out/$name.log"; planes; } | tee -a "$out/$name.txt"
}

case_mp() {
	local clip=$1 name=mp-$1
	mark_syslog
	ssh_ "(/boot/system/apps/MediaPlayer $h/col-$clip.mp4 > $h/out/$name.log 2>&1 &); sleep 8"
	snap $name
	ssh_ "(alert --info 'over the video' > /dev/null 2>&1 &); sleep 2"
	snap $name-alert
	kill_named alert
	ssh_ "hey MediaPlayer do ToggleFullscreen of Window 0 > /dev/null; sleep 4"
	snap $name-full
	ssh_ "hey MediaPlayer quit > /dev/null 2>&1; sleep 2" || true
	kill_named MediaPlayer
	{ ssh_ "grep -a -E '^AVCodecDecoder|rpivid|VideoConsumer|falling back|sand|SAND|YUV' $h/out/$name.log | sort | uniq -c | head -n 12" || true
	  planes; } | tee -a "$out/$name.txt"
}

# a real clip (copied to $h first), paused after 6 s: moving content, still for the comparison
case_pause() {
	local clip=$1 name=pause-${1%.*}
	mark_syslog
	ssh_ "(/boot/system/apps/MediaPlayer $h/$clip > $h/out/$name.log 2>&1 &); sleep 6; hey MediaPlayer do TogglePlaying of Window 0 > /dev/null; sleep 2"
	snap $name
	ssh_ "hey MediaPlayer quit > /dev/null 2>&1; sleep 2" || true
	kill_named MediaPlayer
	{ ssh_ "grep -a -E '^AVCodecDecoder' $h/out/$name.log | sort | uniq -c | head -n 6" || true; planes; } | tee -a "$out/$name.txt"
}

case_ff() {
	mark_syslog
	ssh_ "mkdir -p /boot/home/s1-ffx; printf 'user_pref(\"browser.aboutwelcome.enabled\", false);\nuser_pref(\"browser.shell.checkDefaultBrowser\", false);\nuser_pref(\"media.autoplay.default\", 0);\nuser_pref(\"datareporting.policy.firstRunURL\", \"\");\n' > /boot/home/s1-ffx/user.js; printf '<!DOCTYPE html><html><body style=\"margin:0;background:#404040\"><video src=\"file://$h/col-709-hd.mp4\" width=\"960\" height=\"540\" autoplay loop muted></video></body></html>' > $h/video.html; (MOZ_CRASHREPORTER_DISABLE=1 /boot/system/apps/Firefox/Firefox --no-remote --profile /boot/home/s1-ffx file://$h/video.html > $h/out/ff.log 2>&1 &); sleep 40"
	snap ff
	kill_named Firefox
	planes | tee -a "$out/ff.txt"
}

case_gl() {
	local name=$1 opts="-b -n 1500"
	[ "$name" = gl-cover ] && opts="-b -o -n 1500"
	mark_syslog
	ssh_ "($h/glflip $opts > $h/out/$name.log 2>&1 &); sleep 12"
	# (gl-cover: the cover window lies over the screen's middle third from a third of the frames on)
	snap $name
	wait_for $h/out/$name.log 'PASS|FAIL' 30 || true
	{ ssh_ "grep -a GLF $h/out/$name.log"; planes; } | tee -a "$out/$name.txt"
}

run() {
	case "$1" in
	setup)
		ssh_ "mkdir -p $h/out"
		"$root/scripts/pi-ssh.sh" put "$root"/artifacts/s1/bin/* "$root"/artifacts/v6-video/bin/col-709-hd.mp4 \
			"$root"/artifacts/v6-video/bin/col-601-sd.mp4 "$root"/artifacts/v6-video/bin/col-601full-hd.mp4 \
			"$root"/artifacts/v6-video/bin/col-709-hevc.mp4 "$root"/artifacts/v6-video/bin/col-709-hevc10.mp4 "$h/"
		ssh_ "ls $h" ;;
	desk*) snap "$1" ;;
	ovl-*) case_ovl "${1#ovl-}" ;;
	mp-*) case_mp "${1#mp-}" ;;
	ff) case_ff ;;
	pause-*) case_pause "${1#pause-}" ;;
	gl|gl-cover) case_gl "$1" ;;
	*) echo "s1: unknown case $1" >&2 ;;
	esac
}

[ $# -gt 0 ] || set -- setup desk ovl-rgb32 ovl-yuv420 ovl-yuv420-720 ovl-sand ovl-sand10 mp-709-hd mp-601-sd \
	mp-601full-hd mp-709-hevc mp-709-hevc10 gl gl-cover ff desk-after
for c in "$@"; do run "$c"; done

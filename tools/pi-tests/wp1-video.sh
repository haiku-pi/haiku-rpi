#!/bin/sh
# wp1-video.sh MODE CLIP LABEL — WebPositive <video> on the YUV overlay plane (WP1, docs/design/webpositive-video-overlay.md):
# WebPositive on a page playing CLIP (in the script's directory) muted and looped, with the overlay's counters on
# (WEBKIT_VIDEO_OVERLAY_LOG=1: "WVO" lines on stderr every 2 s; a WebKit without the change prints none).
# LIB=DIR: DIR first in LIBRARY_PATH (a test libWebKitLegacy.so.1); OVL=0: WEBKIT_VIDEO_OVERLAY=0 (same library,
# decoded as B_RGB32 and drawn by app_server, as before); FFENV="A=1 B=2": more environment for WebPositive.
#   measure     the video filling the window (letterboxed); after WAIT s (default 20) the teams' CPU over SECS
#               (default 10) s: WebPositive, app_server; the plane's updates (display driver statistics)
#   controls    a 1280x720 <video controls>; from 12 s to 24 s a translucent bar (text changing 4 times a second) and an
#               opaque square over it (the media controls do not show for injected mouse moves); the mouse over the video at 15 s
#               off it at 25 s; SNAP lines at the moments for HDMI frames
#   scroll      a 640x360 video in a long page, scrolled 2 px every 50 ms for 2 s, still for 6 s, twice
#   full        the measure page; the window resized to the whole screen at 13 s, back at 25 s; CPU over 5 s then
#   seek        the measure page; paused at 12 s, seeked to 5 s and 20 s while paused, played at 22 s (JavaScript)
#   cycle       CYCLES (default 5) times: started on the measure page, PLAY s (default 10) of playing, quit; the
#               WebPositive teams left after 15 s (killed then) and the debugger entries in the syslog
# Lines "WP1 <label> ...", "WP1 <label> SNAP <name>" at the moments meant for an HDMI frame.
# Run over ssh in a bench session (scripts/pi-session.sh, scripts/pi-ssh.sh); tools/pi-tests/wp1-run.sh from the host.
mode=${1:?usage: wp1-video.sh MODE CLIP LABEL}
clip=${2:?usage: wp1-video.sh MODE CLIP LABEL}
label=${3:?usage: wp1-video.sh MODE CLIP LABEL}
wait=${WAIT:-20}
secs=${SECS:-10}
dir=$(cd "$(dirname "$0")" && pwd)
log=$dir/wp1-$label.log
page=$dir/wp1-$label.html
say() { echo "WP1 $label $*"; }
snapshot() { say "SNAP $1"; }
[ -f "$dir/$clip" ] || { say "no $dir/$clip"; exit 1; }
src="file://$dir/$clip"
video="muted loop autoplay src=\"$src\""

wpteams() { ps | awk '$1 ~ /WebPositive$/ { print $(NF-3) }'; }
apteam() { ps | awk '$1 ~ /app_server$/ { print $(NF-3) }' | head -n 1; }
quit_wp() {
	timeout 10 hey WebPositive quit > /dev/null 2>&1 &
	i=0
	while [ -n "$(wpteams)" ] && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
	left=$(wpteams)
	for t in $left; do say "WebPositive $t did not quit: killed"; kill -9 "$t"; done
	[ -z "$left" ] && say "quit in $i s"
	sleep 1
}
start_wp() {	# start WebPositive on $page; team in $team
	for t in $(wpteams); do kill -9 "$t"; done
	# no restored tabs of earlier runs
	rm -f /boot/home/config/settings/WebPositive/Session
	e="WEBKIT_VIDEO_OVERLAY_LOG=1"
	[ -n "${LIB:-}" ] && e="$e LIBRARY_PATH=$LIB:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
	[ "${OVL:-1}" = 0 ] && e="$e WEBKIT_VIDEO_OVERLAY=0"
	# shellcheck disable=SC2086
	env $e ${FFENV:-} /boot/system/apps/WebPositive "file://$page" > "$log" 2>&1 &
	team=$!
	sleep 3
	# a fixed window: 1600x900 at 40,40 (WebPositive remembers its last frame otherwise)
	timeout 5 hey WebPositive set Frame of Window "wp1 $label - WebPositive" to "BRect(40,40,1639,939)" > /dev/null 2>&1
	say "started team $team (LIB=${LIB:-system} OVL=${OVL:-1})"
}
measure_teams() {	# SECS
	"$dir/teamstat" -i "$1" "$team" "$(apteam)" | while read -r line; do say "$line"; done
}
plane_stats() {
	tail -n +$((syslogStart + 1)) /var/log/syslog \
		| grep -a -o "plane [0-9]: [0-9]* updates in [0-9]* vblanks, [0-9]* late.*" | tail -n 3 \
		| while read -r line; do say "shown: $line"; done
}
wvo_lines() {	# the last N WVO lines
	grep -a "^WVO" "$log" | tail -n "${1:-2}" | while read -r line; do say "$line"; done
}

fill="<html style=\"height:100%;margin:0\"><body style=\"height:100%;margin:0;overflow:hidden;background:#000\">
<video $video style=\"display:block;width:100%;height:100%\"></video>"
case "$mode" in
measure|full|cycle) body=$fill ;;
seek) body="$fill
<script>const v = document.querySelector(\"video\");
setTimeout(() => v.pause(), 12000); setTimeout(() => { v.currentTime = 5; }, 14000);
setTimeout(() => { v.currentTime = 20; }, 17000); setTimeout(() => v.play(), 22000);</script>" ;;
controls) body="<body style=\"margin:0;background:#000\"><div style=\"position:relative;width:1280px;height:720px\">
<video controls width=\"1280\" height=\"720\" $video></video>
<div id=\"o\" style=\"display:none;position:absolute;left:40px;right:40px;bottom:30px;height:60px;background:rgba(0,0,0,0.5);color:#fff;font:28px sans-serif;padding:10px\">A translucent bar over the video <span id=\"n\"></span></div>
<div id=\"p\" style=\"display:none;position:absolute;left:560px;top:280px;width:160px;height:160px;background:#c00\"></div></div>
<script>let n = 0; const o = document.getElementById(\"o\"), p = document.getElementById(\"p\");
setTimeout(() => { o.style.display = \"block\"; p.style.display = \"block\"; }, 12000);
setInterval(() => { document.getElementById(\"n\").textContent = n++; }, 250);
setTimeout(() => { o.style.display = \"none\"; p.style.display = \"none\"; }, 24000);</script>" ;;
scroll)
	para='<p>Haiku is an open-source operating system that specifically targets personal computing. Inspired by the
BeOS, Haiku is fast, simple to use, easy to learn and yet very powerful. This paragraph is here so that the page is
long enough to scroll, with a video in the middle of the text.</p>'
	body="<body style=\"margin:0;font:19px/1.5 serif;background:#f4f1e8;color:#222\"><main style=\"width:900px;margin:0 auto\">
$para $para $para <video width=\"640\" height=\"360\" $video></video> $para $para $para $para $para $para $para $para $para</main>
<script>function glide(dy) { let n = 0; const t = setInterval(() => { window.scrollBy(0, dy); if (++n == 40) clearInterval(t); }, 50); }
setTimeout(() => glide(2), 10000); setTimeout(() => glide(-2), 18000);</script>" ;;
*) say "unknown mode $mode"; exit 2 ;;
esac
echo "<!DOCTYPE html><html><head><title>wp1 $label</title></head>$body</html>" > "$page"

syslogStart=$(wc -l < /var/log/syslog)
dbgStart=$(grep -a -c "entered the debugger" /var/log/syslog)
case "$mode" in
measure)
	start_wp
	sleep "$wait"
	snapshot play
	measure_teams "$secs"
	wvo_lines 2
	plane_stats
	quit_wp
	;;
controls)
	start_wp
	sleep 12
	snapshot nocontrols
	"$dir/uiinject" "$team" "wp1" activate move 640 300 wait 300 move 650 320 wait 300 move 660 340 > /dev/null 2>&1
	sleep 4
	snapshot controls
	wvo_lines 1
	sleep 6
	"$dir/uiinject" "$team" "wp1" move 1500 850 > /dev/null 2>&1
	sleep 8
	snapshot after
	wvo_lines 1
	plane_stats
	quit_wp
	;;
scroll)
	start_wp
	sleep 8
	snapshot still1
	sleep 3
	snapshot scrolling
	sleep 5
	snapshot still2
	wvo_lines 1
	sleep 8
	snapshot still3
	wvo_lines 1
	plane_stats
	quit_wp
	;;
full)
	start_wp
	sleep 10
	snapshot window
	# F11 (WebPositive's full screen) by uiinject does not reach it: the window resized to the whole screen
	# instead, the same relayout and repaint for the video
	"$dir/uiinject" "$team" "wp1" activate key f11 > /dev/null 2>&1
	timeout 5 hey WebPositive set Frame of Window "wp1 $label - WebPositive" to "BRect(0,0,1919,1079)" > /dev/null 2>&1
	sleep 5
	snapshot full
	measure_teams 5
	wvo_lines 1
	sleep 2
	timeout 5 hey WebPositive set Frame of Window "wp1 $label - WebPositive" to "BRect(40,40,1639,939)" > /dev/null 2>&1
	sleep 4
	snapshot back
	wvo_lines 1
	plane_stats
	quit_wp
	;;
seek)
	start_wp
	sleep 13
	snapshot paused
	sleep 2
	snapshot seek5
	sleep 3
	snapshot seek20
	sleep 6
	snapshot playing
	wvo_lines 2
	quit_wp
	;;
cycle)
	n=0
	while [ $n -lt "${CYCLES:-5}" ]; do
		n=$((n + 1))
		start_wp
		sleep "${PLAY:-10}"
		wvo_lines 1
		quit_wp
	done
	;;
esac
say "debugger entries: $(( $(grep -a -c "entered the debugger" /var/log/syslog) - dbgStart ))"
grep -a -E "^WVO (end|stats)" "$log" | tail -n 1 | while read -r line; do say "last: $line"; done

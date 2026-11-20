#!/bin/sh
# ffv-a1.sh MODE CLIP LABEL — Firefox <video> on the YUV overlay plane (docs/design/firefox-video-overlay.md §6
# step 3, patches/firefox/0006): plays CLIP (in the script's directory) looped and muted in a page for MODE, with
# the overlay's log on (MOZ_HAIKU_VIDEO_OVERLAY_LOG=1: "HVO show/hide/stats" lines on Firefox's stderr, counters of
# the frames on the plane and of the reasons a frame went in software). FFX=PATH: another Firefox binary (an
# extracted package); OVL=0: the overlay off (MOZ_HAIKU_VIDEO_OVERLAY=0, the same binary in software).
#   measure   a 1280x720 <video> on a black page; after WAIT s (default 45) every thread's CPU time twice, SECS
#             (default 10) apart (as ffv0.sh), frames decoded/dropped; the plane's updates (display driver)
#   scroll    a 640x360 video in a long page, scrolled by 1.5 px every 50 ms for 2 s, then still for 6 s, again:
#             software while moving (Unstable), back on the plane when still
#   half      the video half above the window's top edge for 12 s (NotWhole), then wholly in view (plane)
#   two       two videos (960x540 and 480x270): the larger on the plane, the smaller in software
#   caption   a 1280x720 <video controls> with an opaque caption box and a translucent box over it; the mouse is
#             moved over the video at 20 s (uiinject, in the script's directory) to show the controls
#   noplane   six overlaytests (in the script's directory) hold all overlay planes for 25 s, then end: software
#             (NoPlane) first, the plane after
#   mode      the screen to 1280x720 at 20 s and back at 30 s (overlays suspended): software meanwhile, the plane
#             after
#   real      a styled article: text around a 960x540 video at a fractional position (scaled 0.9, centred column,
#             half-pixel padding), a translucent caption over it, the page scrolled by 200 px at 15 s and back at 25 s
#   tab       a second tab opened in front at 15 s (window.open) and closed at 30 s; an overlaytest (yuv420) runs
#             while the video's tab is hidden: the plane must be free for it, and back for the video afterwards
#   minimize  the window minimised at 15 s and restored at 27 s (scripting), an overlaytest meanwhile
#   fullscreen  <video controls>: fullscreen by script at 12 s, out at 24 s; by a double-click on the video
#             (uiinject) at 32 s, out with Esc at 42 s; CPU over 5 s in the first fullscreen period
#   cycle     CYCLES (default 10) times: Firefox started on PAGE (single: a 1280x720 video; two: the two-video
#             page), PLAY s (default 12) of playing, `hey Firefox quit`; per cycle the debugger entries in the syslog
#             and the Firefox teams left after 20 s (killed then)
# LIBS=DIR: DIR first in LIBRARY_PATH (test builds of libavcodec / libmmal*), any mode; AVLOG=N: FFmpeg's own log at
# level N (MOZ_LOG FFmpegLib, 3 = info) in every mode; NOCAP=1: the real page without its caption
#   switch    a 1280x720 video of CLIP; at 15 s its src becomes SWITCH (default play-1080p30.mp4) in the same page
#             and process: with AVLOG=3, both should decode on the VideoCore (two "VideoCore H264 decode" lines, no
#             "decodes another stream": h264_vc gives its VideoCore slot back when a decoder closes)
#   avsync    the clip unmuted (a beep with a white flash once a second: tools/media-tests/gen-avsync-clip.sh) for
#             SECS (default 40) s; the host records HDMI video + audio (tools/pi-tests/avsync-measure.sh)
# Lines "FFA <label> ...", and "FFA <label> SNAP <name>" at the moments meant for an HDMI frame.
# Run over ssh in a bench session (scripts/pi-session.sh, scripts/pi-ssh.sh).
mode=${1:?usage: ffv-a1.sh MODE CLIP LABEL}
clip=${2:?usage: ffv-a1.sh MODE CLIP LABEL}
label=${3:?usage: ffv-a1.sh MODE CLIP LABEL}
wait=${WAIT:-45}
secs=${SECS:-10}
dir=$(cd "$(dirname "$0")" && pwd)
ffx=${FFX:-/boot/system/apps/Firefox/Firefox}
profile=$dir/ffa-profile-$label
log=$dir/ffa-$label.log
say() { echo "FFA $label $*"; }
# snapshot NAME: a "SNAP" line, the moment the test means for an HDMI frame (the host takes frames on a schedule:
# polling the log over ssh costs the Pi CPU during the measurement)
snapshot() { say "SNAP $1"; }
[ -f "$dir/$clip" ] || { say "no $dir/$clip"; exit 1; }
rm -rf "$profile"
mkdir -p "$profile"
cat > "$profile/user.js" << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
// no background network (remote settings, Safe Browsing, CRLite, telemetry ...: a fresh profile downloads
// ~100 MB in its first minutes, and that CPU falls into the measurement at random): every http(s) request goes
// to a proxy that refuses it; the pages and clips are local files
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", 9);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", 9);
user_pref("network.proxy.no_proxies_on", "");
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.downloads.enabled", false);
user_pref("browser.safebrowsing.update.enabled", false);
user_pref("security.remote_settings.crlite_filters.enabled", false);
user_pref("security.remote_settings.intermediates.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("extensions.update.enabled", false);
// window.open() without a click (tab mode), fullscreen without one (fullscreen mode), no fullscreen notice
user_pref("dom.disable_open_during_load", false);
user_pref("full-screen-api.allow-trusted-requests-only", false);
user_pref("full-screen-api.warning.timeout", 0);
user_pref("media.autoplay.blocking_policy", 0);
PREFS

# the page: QUALITY logs the first video's frame counts every 2 s
quality='const t0 = performance.now();
setInterval(() => { const v = document.querySelector("video"), q = v.getVideoPlaybackQuality();
  console.log("FFAQ " + ((performance.now() - t0) / 1000).toFixed(1) + " s: " + v.videoWidth + "x" + v.videoHeight
    + " frames " + q.totalVideoFrames + " dropped " + q.droppedVideoFrames + " presented " + v.mozPresentedFrames); }, 2000);'
video="muted loop autoplay src=\"file://$dir/$clip\""
case "$mode" in
real)
	para='<p>Haiku is an open-source operating system that specifically targets personal computing. Inspired by the
BeOS, Haiku is fast, simple to use, easy to learn and yet very powerful. This paragraph is here so that text
flows around the video the way it does on a news site or a blog, with a few lines above and below.</p>'
	cap='<figcaption style='
	[ "${NOCAP:-0}" = 1 ] && cap='<figcaption hidden style='
	body="<body style=\"margin:0;font:19px/1.5 serif;background:#f4f1e8;color:#222\">
<header style=\"height:64px;background:#24384f;color:#fff;font:28px sans-serif;padding:14px 30px\">The Daily Haiku</header>
<main style=\"width:1000px;margin:0 auto;padding:10px 30.5px\"><h1 style=\"font:34px sans-serif\">An article with a video</h1>
$para $para
<figure style=\"position:relative;margin:0 0 0 7.5px;width:864px;height:486px\">
<video style=\"transform:scale(0.9);transform-origin:0 0\" width=\"960\" height=\"540\" $video></video>
$cap\"position:absolute;left:16px;bottom:18px;padding:4px 10px;background:rgba(0,0,0,0.55);color:#fff;font:18px sans-serif\">A translucent caption over the video</figcaption></figure>
$para $para $para $para $para $para</main>
<script>function glide(dy) { let n = 0; const t = setInterval(() => { window.scrollBy(0, dy / 40); if (++n == 40) clearInterval(t); }, 50); }
setTimeout(() => glide(200), 15000); setTimeout(() => glide(-200), 25000);</script>" ;;
switch)
	body="<body style=\"margin:0;background:#000\"><video id=\"s\" width=\"1280\" height=\"720\" $video></video>
<script>setTimeout(() => { const s = document.getElementById(\"s\"); s.src = \"file://$dir/${SWITCH:-play-1080p30.mp4}\";
  s.play(); console.log(\"FFA switched\"); }, 15000);</script>" ;;
tab|minimize)
	body="<body style=\"margin:0;background:#000\"><video width=\"1280\" height=\"720\" $video></video>"
	[ "$mode" = tab ] && body="$body
<script>let w; setTimeout(() => { w = window.open(\"about:blank\"); console.log(\"FFA tab opened \" + !!w); }, 15000);
setTimeout(() => { if (w) w.close(); console.log(\"FFA tab closed\"); }, 30000);</script>" ;;
fullscreen)
	body="<body style=\"margin:0;background:#000\"><video controls width=\"1280\" height=\"720\" $video></video>
<script>const fv = document.querySelector(\"video\");
setTimeout(() => fv.requestFullscreen().then(() => console.log(\"FFA fullscreen on\"), e => console.log(\"FFA fullscreen failed \" + e)), 12000);
setTimeout(() => document.exitFullscreen().then(() => console.log(\"FFA fullscreen off\")), 24000);
document.addEventListener(\"fullscreenchange\", () => console.log(\"FFA fullscreenchange \" + !!document.fullscreenElement));</script>" ;;
avsync)
	body="<body style=\"margin:0;background:#000\"><video width=\"1280\" height=\"720\" loop autoplay src=\"file://$dir/$clip\"></video>" ;;
cycle)
	if [ "${PAGE:-single}" = two ]; then
		body="<body style=\"margin:0;background:#000\"><video width=\"960\" height=\"540\" $video></video><video width=\"480\" height=\"270\" $video></video>"
	else
		body="<body style=\"margin:0;background:#000\"><video width=\"1280\" height=\"720\" $video></video>"
	fi ;;
measure|noplane|mode)
	body="<body style=\"margin:0;background:#000\"><video width=\"1280\" height=\"720\" $video></video>" ;;
scroll)
	body="<body style=\"margin:0;background:#246\"><div style=\"height:60px;color:#fff;font:40px sans-serif\">above</div>
<video width=\"640\" height=\"360\" $video></video><div style=\"height:3000px;color:#fff;font:40px sans-serif\">below</div>
<script>let n = 0; setInterval(() => { const phase = n % 160, dir = Math.floor(n / 160) % 2 ? -1 : 1; n++;
  if (phase < 40) window.scrollBy(0, 1.5 * dir); }, 50);</script>" ;;
half)
	body="<body style=\"margin:0;background:#000\"><video id=\"h\" style=\"position:absolute;left:0;top:-360px\" width=\"1280\" height=\"720\" $video></video>
<script>setTimeout(() => { document.getElementById(\"h\").style.top = \"0px\"; console.log(\"FFA moved in\"); }, 12000);</script>" ;;
two)
	body="<body style=\"margin:0;background:#000\"><video width=\"960\" height=\"540\" $video></video><video width=\"480\" height=\"270\" $video></video>" ;;
caption)
	body="<body style=\"margin:0;background:#000\"><div style=\"position:relative;width:1280px;height:720px\">
<video controls width=\"1280\" height=\"720\" $video></video>
<div style=\"position:absolute;left:40px;top:40px;padding:8px;background:#fff;color:#000;font:32px sans-serif\">opaque caption</div>
<div style=\"position:absolute;left:40px;top:140px;width:300px;height:80px;background:rgba(255,255,255,0.5)\"></div></div>" ;;
*)
	say "unknown mode $mode"; exit 2 ;;
esac
cat > "$dir/ffa-$label.html" << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>ffa</title></head>
$body
<script>$quality</script></body></html>
EOF

# every thread: "tid team thread-name utime ktime" (ms)
snap() {
	ps -a | awk '
		/^Team / { getline; team = $1; next }
		/^Thread / || NF < 6 { next }
		$(NF - 4) ~ /^[0-9]+$/ && $(NF - 1) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {
			name = $1; for (i = 2; i <= NF - 5; i++) name = name "_" $i
			n = split(team, p, "/"); print $(NF - 4), p[n], name, $(NF - 1), $NF }'
}
ffteam() { ps | awk -v f="$ffx" '$1 == f { print $(NF-3); exit }'; }

dbg0=$(grep -a -c "entered the debugger" /var/log/syslog)
sys0=$(wc -l < /var/log/syslog)
# LIBS=DIR (any mode): DIR first in LIBRARY_PATH (an ssh shell has none: then the runtime_loader's default, which a
# set one replaces)
[ -n "$LIBS" ] && export LIBRARY_PATH="$LIBS:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
if [ "$mode" = cycle ]; then
	total=0 i=1
	while [ $i -le "${CYCLES:-10}" ]; do
		d0=$(grep -a -c "entered the debugger" /var/log/syslog)
		MOZ_CRASHREPORTER_DISABLE=1 MOZ_LOG=FFmpegVideo:3,FFmpegLib:${AVLOG:-3} $ffx --no-remote --profile "$profile" \
			"file://$dir/ffa-$label.html" > "$log.$i" 2>&1 &
		sleep "${PLAY:-12}"
		frames=$(tr -d '\r' < "$log.$i" | grep -a FFAQ | tail -n 1 | sed 's/.*frames \([0-9]*\).*/\1/')
		hey Firefox quit > /dev/null 2>&1
		n=0
		while [ $n -lt 20 ] && [ -n "$(ffteam)" ]; do sleep 1; n=$((n + 1)); done
		left=$(ps | awk -v f="$ffx" '$1 == f' | wc -l)
		for t in $(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }'); do kill -9 "$t" 2> /dev/null; done
		sleep 2
		d=$(( $(grep -a -c "entered the debugger" /var/log/syslog) - d0 ))
		total=$((total + d))
		dec=$(grep -a -o "Using preferred [a-z]* codec [a-z0-9_]*\|h264_mmal [a-z ]*: h264 continues[a-z ]*" "$log.$i" | sort | uniq -c | tr -s ' ' | tr '\n' ';')
		mm=$(grep -a -c "no event buffer left\|not sent back by the VideoCore\|no reply to message" "$log.$i")
		say "cycle $i: frames ${frames:-?} quit ${n} s left $left debugger $d mmal-errors $mm decoders:$dec"
		i=$((i + 1))
	done
	say "cycles ${CYCLES:-10} debugger entries $total"
	say end
	exit 0
fi
if [ "$mode" = noplane ]; then
	ovl=""
	for i in 1 2 3 4 5 6; do
		"$dir/overlaytest" -s rgb32 -f 10 -h 25 > "$dir/ffa-ovl-$i.log" 2>&1 &
		ovl="$ovl $!"
		sleep 1
	done
	sleep 2
	say "six overlaytests hold the planes"
fi
ovlenv=
[ "${OVL:-1}" = 0 ] && ovlenv="MOZ_HAIKU_VIDEO_OVERLAY=0"
say "firefox $ffx ${ovlenv:-overlay on}"
avlog=
[ -n "$AVLOG" ] && avlog="MOZ_LOG=FFmpegLib:$AVLOG"
env $ovlenv $avlog MOZ_HAIKU_VIDEO_OVERLAY_LOG=1 MOZ_CRASHREPORTER_DISABLE=1 $ffx --no-remote --profile "$profile" \
	"file://$dir/ffa-$label.html" > "$log" 2>&1 &
case "$mode" in
measure)
	sleep "$wait"
	snap > /tmp/ffa-a.txt
	q0=$(tr -d '\r' < "$log" | grep -a FFAQ | tail -n 1)
	h0=$(grep -a "^HVO stats" "$log" | tail -n 1)
	sleep "$secs"
	snap > /tmp/ffa-b.txt
	q1=$(tr -d '\r' < "$log" | grep -a FFAQ | tail -n 1)
	h1=$(grep -a "^HVO stats" "$log" | tail -n 1)
	awk 'NR == FNR { u[$1] = $4; k[$1] = $5; next }
		($1 in u) { du = $4 - u[$1]; dk = $5 - k[$1]; if (du + dk > 0) printf "%6d ms (user %d, kernel %d) %s %s %s\n", du + dk, du, dk, $2, $1, $3 }' \
		/tmp/ffa-a.txt /tmp/ffa-b.txt | grep -v " kernel_team [0-9]* idle_thread" | sort -rn | head -n 16 \
		| while IFS= read -r l; do say "thread $l"; done
	awk 'NR == FNR { s[$1] = $4 + $5; next } ($1 in s) { t[$2] += $4 + $5 - s[$1] }
		END { for (n in t) if (t[n] > 0) printf "%6d ms %s\n", t[n], n }' /tmp/ffa-a.txt /tmp/ffa-b.txt \
		| grep -v " kernel_team$" | sort -rn | head -n 6 | while IFS= read -r l; do say "team $l"; done
	idle=$(awk 'NR == FNR { s[$1] = $5; next } ($1 in s) && $3 ~ /^idle_thread/ { t += $5 - s[$1] } END { print t }' \
		/tmp/ffa-a.txt /tmp/ffa-b.txt)
	say "idle ${idle} ms of $((secs * 4000)) (4 CPUs, ${secs} s)"
	say "quality before: ${q0#*FFAQ }"
	say "quality after:  ${q1#*FFAQ }"
	say "overlay before: $h0"
	say "overlay after:  $h1"
	snapshot "$label-play"
	sleep 4
	;;
scroll)
	sleep 20
	snapshot "$label-moving"
	sleep 4
	snapshot "$label-still"
	sleep 20
	;;
half)
	sleep 8
	snapshot "$label-half"
	sleep 12
	snapshot "$label-whole"
	sleep 6
	;;
two)
	sleep 25
	snapshot "$label-two"
	sleep 6
	;;
caption)
	sleep 15
	snapshot "$label-unhovered"
	sleep 5
	t=$(ffteam)
	"$dir/uiinject" "$t" ffa activate move 640 300 wait 300 move 650 320 wait 300 move 660 340 > /dev/null 2>&1
	sleep 1
	snapshot "$label-hovered"
	sleep 5
	;;
noplane)
	sleep 15
	snapshot "$label-noplane"
	for p in $ovl; do wait "$p" 2> /dev/null; done
	say "overlaytests ended"
	sleep 12
	snapshot "$label-plane"
	sleep 5
	;;
real)
	sleep 12
	snapshot "$label-still"
	sleep 5
	snapshot "$label-scrolling"
	sleep 5
	snapshot "$label-scrolled"
	sleep 12
	snapshot "$label-back"
	sleep 4
	;;
tab|minimize)
	sleep 12
	snapshot "$label-playing"
	sleep 3
	if [ "$mode" = minimize ]; then
		hey Firefox set Minimize of Window 0 to true > /dev/null 2>&1
		say "minimised"
	fi
	sleep 4
	snapshot "$label-away"
	"$dir/overlaytest" -s yuv420 -f 30 -h 2 > "$dir/ffa-ovl-$label.log" 2>&1
	say "overlaytest while away: exit $? ($(grep -a -c 'BAD' "$dir/ffa-ovl-$label.log") BAD lines)"
	if [ "$mode" = minimize ]; then
		sleep 4
		hey Firefox set Minimize of Window 0 to false > /dev/null 2>&1
		say "restored"
		sleep 8
	else
		sleep 12
	fi
	snapshot "$label-back"
	sleep 4
	;;
fullscreen)
	sleep 15
	snap > /tmp/ffa-a.txt
	sleep 5
	snap > /tmp/ffa-b.txt
	snapshot "$label-fs1"
	awk 'NR == FNR { s[$1] = $4 + $5; next } ($1 in s) && ($3 == "Renderer" || $3 == "SwComposite" || $3 ~ /^w:/) {
		d = $4 + $5 - s[$1]; if (d > 0) printf "%6d ms %s %s\n", d, $2, $3 }' /tmp/ffa-a.txt /tmp/ffa-b.txt \
		| while IFS= read -r l; do say "fullscreen cpu (5 s) $l"; done
	sleep 6
	snapshot "$label-out1"
	sleep 5
	t=$(ffteam)
	"$dir/uiinject" "$t" ffa activate move 640 400 wait 200 dblclick 1 640 400 > /dev/null 2>&1
	say "double-click sent"
	sleep 5
	snapshot "$label-fs2"
	sleep 4
	"$dir/uiinject" "$(ffteam)" ffa key esc > /dev/null 2>&1
	say "esc sent"
	sleep 5
	snapshot "$label-out2"
	sleep 3
	;;
avsync)
	sleep "${SECS:-40}"
	;;
switch)
	sleep 32
	snapshot "$label-after"
	sleep 3
	;;
mode)
	sleep 20
	snapshot "$label-before"
	sleep 3
	screenmode 1280 720 > /dev/null 2>&1
	say "mode: 1280x720"
	sleep 6
	snapshot "$label-720"
	sleep 4
	screenmode 1920 1080 > /dev/null 2>&1
	say "mode: 1920x1080"
	sleep 12
	snapshot "$label-after"
	sleep 5
	;;
esac
hey Firefox quit > /dev/null 2>&1
n=0
while [ $n -lt 20 ] && [ -n "$(ffteam)" ]; do sleep 1; n=$((n + 1)); done
left=$(ps | awk -v f="$ffx" '$1 == f' | wc -l)
say "quit: $left Firefox teams left after ${n} s"
for t in $(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }'); do kill -9 "$t" 2> /dev/null; done
grep -a -E "^HVO (show|hide)" "$log" | head -n 20 | while IFS= read -r l; do say "log $l"; done
grep -a "^HVO stats" "$log" | tail -n 1 | while IFS= read -r l; do say "log last $l"; done
tr -d '\r' < "$log" | grep -a "FFA tab\|FFA fullscreen\|FFA switched" | while IFS= read -r l; do say "page $l"; done
grep -a "VideoCore H264 decode\|decodes another stream\|h264_mmal [a-z ]*: h264\|frames decoded from" "$log" | cut -c1-160 \
	| while IFS= read -r l; do say "decoder $l"; done
tr -d '\r' < "$log" | grep -a "FFAQ\|FFA moved" | tail -n 2 | while IFS= read -r l; do say "page $l"; done
tail -n +$((sys0 + 1)) /var/log/syslog | grep -a -o "plane [0-9]: [0-9]* updates in [0-9]* vblanks, [0-9]* late.*" \
	| tail -n 6 | while IFS= read -r l; do say "driver $l"; done
dbg1=$(grep -a -c "entered the debugger" /var/log/syslog)
say "debugger entries: $((dbg1 - dbg0))"
say end

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
PREFS

# the page: QUALITY logs the first video's frame counts every 2 s
quality='const t0 = performance.now();
setInterval(() => { const v = document.querySelector("video"), q = v.getVideoPlaybackQuality();
  console.log("FFAQ " + ((performance.now() - t0) / 1000).toFixed(1) + " s: " + v.videoWidth + "x" + v.videoHeight
    + " frames " + q.totalVideoFrames + " dropped " + q.droppedVideoFrames + " presented " + v.mozPresentedFrames); }, 2000);'
video="muted loop autoplay src=\"file://$dir/$clip\""
case "$mode" in
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
env $ovlenv MOZ_HAIKU_VIDEO_OVERLAY_LOG=1 MOZ_CRASHREPORTER_DISABLE=1 $ffx --no-remote --profile "$profile" \
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
tr -d '\r' < "$log" | grep -a "FFAQ\|FFA moved" | tail -n 2 | while IFS= read -r l; do say "page $l"; done
tail -n +$((sys0 + 1)) /var/log/syslog | grep -a -o "plane [0-9]: [0-9]* updates in [0-9]* vblanks, [0-9]* late.*" \
	| tail -n 6 | while IFS= read -r l; do say "driver $l"; done
dbg1=$(grep -a -c "entered the debugger" /var/log/syslog)
say "debugger entries: $((dbg1 - dbg0))"
say end

#!/bin/sh
# ffv0.sh CLIP LABEL [hud] — Firefox video step 0 (docs/design/firefox-video-overlay.md §6): plays CLIP (in the
# script's directory) looped and muted in a 1280x720 <video> of the released Firefox, waits WAIT s (default 30:
# past G2's start-up drops), then takes the CPU time of every thread in the system twice, SECS (default 10) apart,
# with a system-wide profile (`profile -a -S -k`) in between; prints the busiest threads (any team: Firefox,
# app_server, ...), per-team totals and the frames decoded / dropped.
#   hud: also WebRender's profiler HUD with the compositor-surface counters (an HDMI snapshot reads it) and
#        surface-promotion logging (RUST_LOG=webrender=warn: failures go to Firefox's stderr); the HUD redraws
#        the whole window, so a hud run is not a CPU measurement.
# PERTHREAD=1: the profile per thread (no -S) instead of one summary.
# Run over ssh in a bench session (scripts/pi-session.sh, scripts/pi-ssh.sh). Lines "FFV0 ...".
clip=${1:?usage: ffv0.sh CLIP LABEL [hud]}
label=${2:?usage: ffv0.sh CLIP LABEL [hud]}
mode=${3:-measure}
wait=${WAIT:-30}
secs=${SECS:-10}
dir=$(cd "$(dirname "$0")" && pwd)
ffx=${FFX:-/boot/system/apps/Firefox/Firefox}
profile=$dir/ffv0-profile-$label
say() { echo "FFV0 $label $*"; }
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
PREFS
if [ "$mode" = hud ]; then
	cat >> "$profile/user.js" << 'PREFS'
user_pref("gfx.webrender.debug.profiler", true);
user_pref("gfx.webrender.debug.profiler-ui", "Compositor surface underlays,Compositor surface overlays,Compositor surface blits,Picture cache slices,Rendered picture tiles,Total CPU time,FPS");
user_pref("gfx.webrender.debug.surface-promotion-logging", true);
PREFS
fi
cat > "$dir/ffv0.html" << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>ffv0</title></head>
<body style="margin:0;background:#000"><video id="v" width="1280" height="720" muted loop autoplay
 src="file://$dir/$clip"></video>
<script>
const v = document.getElementById("v"), t0 = performance.now();
setInterval(() => { const q = v.getVideoPlaybackQuality();
  console.log("FFV0Q " + ((performance.now() - t0) / 1000).toFixed(1) + " s: " + v.videoWidth + "x" + v.videoHeight
    + " frames " + q.totalVideoFrames + " dropped " + q.droppedVideoFrames + " painted " + v.mozPaintedFrames
    + " presented " + v.mozPresentedFrames); }, 2000);
</script></body></html>
EOF
log=$dir/ffv0-$label.log
dbg0=$(grep -a -c "entered the debugger" /var/log/syslog)
RUST_LOG=webrender=warn MOZ_CRASHREPORTER_DISABLE=1 $ffx --no-remote --profile "$profile" "file://$dir/ffv0.html" \
	> "$log" 2>&1 &
sleep "$wait"
# every thread: "tid team thread-name utime ktime" (ms)
snap() {
	ps -a | awk '
		/^Team / { getline; team = $1; next }
		/^Thread / || NF < 6 { next }
		$(NF - 4) ~ /^[0-9]+$/ && $(NF - 1) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {
			name = $1; for (i = 2; i <= NF - 5; i++) name = name "_" $i
			n = split(team, p, "/"); print $(NF - 4), p[n], name, $(NF - 1), $NF }'
}
snap > /tmp/ffv0-a.txt
q0=$(tr -d '\r' < "$log" | grep -a FFV0Q | tail -n 1)
if [ -n "$PERTHREAD" ]; then popt=; else popt=-S; fi
profile -a $popt -k -o "$dir/ffv0-prof-$label.txt" sleep "$secs" > /dev/null 2>&1
snap > /tmp/ffv0-b.txt
q1=$(tr -d '\r' < "$log" | grep -a FFV0Q | tail -n 1)
awk 'NR == FNR { u[$1] = $4; k[$1] = $5; next }
	($1 in u) { du = $4 - u[$1]; dk = $5 - k[$1]; if (du + dk > 0) printf "%6d ms (user %d, kernel %d) %s %s %s\n", du + dk, du, dk, $2, $1, $3 }' \
	/tmp/ffv0-a.txt /tmp/ffv0-b.txt | grep -v " kernel_team [0-9]* idle_thread" | sort -rn | head -n 25 \
	| while IFS= read -r l; do say "thread $l"; done
awk 'NR == FNR { s[$1] = $4 + $5; next } ($1 in s) { t[$2] += $4 + $5 - s[$1] }
	END { for (n in t) if (t[n] > 0) printf "%6d ms %s\n", t[n], n }' /tmp/ffv0-a.txt /tmp/ffv0-b.txt \
	| grep -v " kernel_team$" | sort -rn | head -n 8 | while IFS= read -r l; do say "team $l"; done
idle=$(awk 'NR == FNR { s[$1] = $5; next } ($1 in s) && $3 ~ /^idle_thread/ { t += $5 - s[$1] } END { print t }' \
	/tmp/ffv0-a.txt /tmp/ffv0-b.txt)
say "idle ${idle} ms of $((secs * 4000)) (4 CPUs, ${secs} s)"
say "quality before: ${q0#*FFV0Q }"
say "quality after:  ${q1#*FFV0Q }"
grep -a -m 60 -E '^ *[0-9]+ +[0-9.]+' "$dir/ffv0-prof-$label.txt" | head -n 30 | while IFS= read -r l; do say "prof $l"; done
grep -a -i -E "promotion|webrender|swgl|compositor" "$log" | cut -c1-200 | sort | uniq -c | sort -rn | head -n 12 \
	| while IFS= read -r l; do say "log $l"; done
if [ "$mode" = hud ]; then
	say "hud: snapshot now"
	sleep "${HUDHOLD:-40}"
fi
hey Firefox quit > /dev/null 2>&1
sleep 8
for t in $(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }'); do kill -9 "$t" 2> /dev/null; done
dbg1=$(grep -a -c "entered the debugger" /var/log/syslog)
say "debugger entries: $((dbg1 - dbg0))"
say end

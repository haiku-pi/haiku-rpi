#!/bin/sh
# ffv-prof.sh [CLIP] [SECS] — where Firefox's time goes while it plays a video: plays CLIP (default
# h264-1080p.mp4, from /boot/system/non-packaged/data/web-video: scripts/make-web-video-clips.sh) in a loop,
# muted, in a 1280x720 element; after 12 s takes the CPU time of every Firefox thread twice, SECS (default 8)
# apart, with a system-wide profile (`profile -a -S -k`) in between; then the frames decoded and dropped so far.
# Run over ssh in a session (scripts/pi-session.sh, scripts/pi-ssh.sh). Lines "FFP ..."; the profile in
# /tmp/ffprof.txt.
clip=${1:-h264-1080p.mp4}
secs=${2:-8}
ffx=/boot/system/apps/Firefox/Firefox
profile=/boot/home/ffp-profile
clips=/boot/system/non-packaged/data/web-video
say() { echo "FFP $*"; }
[ -f $clips/$clip ] || { say "no $clips/$clip"; exit 1; }
mkdir -p $profile
cat > $profile/user.js << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
user_pref("media.autoplay.default", 0);
PREFS
export MOZ_CRASHREPORTER_DISABLE=1
cat > /tmp/ffp.html << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>ffp</title></head>
<body style="margin:0;background:#000"><video id="v" width="1280" height="720" muted loop playsinline></video>
<script>
const v = document.getElementById("v");
v.src = "file://$clips/$clip";
v.play();
setInterval(() => { const q = v.getVideoPlaybackQuality();
  console.log("FFPQ t=" + (performance.now() / 1000).toFixed(1) + " frames " + q.totalVideoFrames
    + " dropped " + q.droppedVideoFrames); }, 1000);
</script></body></html>
EOF
$ffx --no-remote --profile $profile file:///tmp/ffp.html > /tmp/ffp.txt 2>&1 &
sleep 12
# thread id -> "team name UTime KTime" (ms), for the Firefox teams
snap() {
	ps -a | awk -v f="$ffx" '
		/^Team/ { getline; ff = index($0, f) > 0; team = $NF; next }
		ff && NF >= 5 && $(NF - 1) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {
			name = $1; for (i = 2; i <= NF - 5; i++) name = name "_" $i
			print $(NF - 4), name, $(NF - 1), $NF }'
}
snap > /tmp/ffp-a.txt
profile -a -S -k -o /tmp/ffprof.txt sleep $secs > /dev/null 2>&1
snap > /tmp/ffp-b.txt
# per thread: CPU ms (user + kernel) over the interval, the busiest first
awk 'NR == FNR { u[$1] = $3; k[$1] = $4; next }
	($1 in u) { du = $3 - u[$1]; dk = $4 - k[$1]; if (du + dk > 0) printf "%6d ms (user %d, kernel %d) %s %s\n", du + dk, du, dk, $1, $2 }' \
	/tmp/ffp-a.txt /tmp/ffp-b.txt | sort -rn | head -n 15 | while IFS= read -r l; do say "cpu $l"; done
tot=$(awk 'NR == FNR { s[$1] = $3 + $4; next } ($1 in s) { t += $3 + $4 - s[$1] } END { print t }' /tmp/ffp-a.txt /tmp/ffp-b.txt)
say "cpu total ${tot} ms of $((secs * 4000)) (4 CPUs, ${secs} s)"
tr -d '\r' < /tmp/ffp.txt | grep -a FFPQ | tail -n 1 | while IFS= read -r l; do say "quality ${l#*FFPQ }"; done
grep -a -m 40 -E '^ *[0-9]+ +[0-9.]+' /tmp/ffprof.txt | head -n 25 | while IFS= read -r l; do say "prof $l"; done
for t in $(ps | grep -a "$ffx" | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
say end

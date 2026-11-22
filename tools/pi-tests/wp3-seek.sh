#!/bin/sh
# wp3-seek.sh MODE CLIP LABEL — seeking a WebPositive <video> (WP3, docs/design/webpositive-video-overlay.md §6).
# The page plays CLIP (in the script's directory) muted, filling a 1600x900 window, and puts what the media element
# says into the document's title (read here with hey, one line per change, "WP3 <label> page ..."):
# "dur=" the duration and "sk=" the end of the seekable range at loadedmetadata; then each event with
# currentTime: pause, seeking, seeked, play, playing, ended; and "t" (with the duration and the seekable end) every 2 s.
#   paused   paused at 12 s; currentTime = 5 at 14 s and 20 s at 17 s (while paused); play at 22 s;
#            SNAP lines at 13, 16, 20 and 26 s (page time)
#   playing  currentTime = 40 at 8 s and 3 s at 16 s while playing; SNAP lines at 11, 19 s
#   end      LOOP=1 (default) or 0: played to the end and on (CLIP of 30 s or less); SNAP at 33 s
#   teardown every 1.5 s currentTime = 20, and 150 ms later (while the player decodes on to 20 s) the player dropped
#            (src removed + load(), then src again) or reloaded (src set again), alternately: "teardown N" counts them;
#            a WebPositive that hangs stops counting
# LIB=DIR: DIR first in LIBRARY_PATH (a test libWebKitLegacy.so.1); OVL=0: WEBKIT_VIDEO_OVERLAY=0.
# Run over ssh in a bench session (scripts/pi-session.sh); tools/pi-tests/wp3-run.sh from the host takes the HDMI
# frames at the SNAP lines.
mode=${1:?usage: wp3-seek.sh MODE CLIP LABEL}
clip=${2:?usage: wp3-seek.sh MODE CLIP LABEL}
label=${3:?usage: wp3-seek.sh MODE CLIP LABEL}
dir=$(cd "$(dirname "$0")" && pwd)
log=$dir/wp3-$label.log
page=$dir/wp3-$label.html
say() { echo "WP3 $label $*"; }
[ -f "$dir/$clip" ] || { say "no $dir/$clip"; exit 1; }
loop=""
[ "$mode" = end ] && [ "${LOOP:-1}" = 0 ] || loop=loop

wpteams() { ps | awk '$1 ~ /WebPositive$/ { print $(NF-3) }'; }

case "$mode" in
paused) script='at(12000, () => v.pause()); at(14000, () => { v.currentTime = 5; });
at(17000, () => { v.currentTime = 20; }); at(22000, () => v.play());'
	snaps="13:paused 16:seek5 20:seek20 26:playing" ;;
playing) script='at(8000, () => { v.currentTime = 40; }); at(16000, () => { v.currentTime = 3; });'
	snaps="11:fwd40 19:back3" ;;
end) script=''
	snaps="33:end" ;;
teardown) script='let k = 0; const SRC = v.src;
setInterval(() => { v.currentTime = 20; setTimeout(() => { k++;
	if (k % 2) { v.removeAttribute("src"); v.load(); v.src = SRC; } else v.src = SRC;
	log("teardown " + k); }, 150); }, 1500);'
	snaps="30:end" ;;
*) say "unknown mode $mode"; exit 2 ;;
esac
cat > "$page" << EOF
<!DOCTYPE html><html style="height:100%;margin:0"><head><title>wp3 $label</title></head>
<body style="height:100%;margin:0;overflow:hidden;background:#000">
<video muted $loop autoplay src="file://$dir/$clip" style="display:block;width:100%;height:100%"></video>
<script>const v = document.querySelector("video"), t0 = performance.now(); let n = 0;
const f = (x) => (typeof x == "number" ? x.toFixed(2) : String(x));
const ev = [];
// the last six entries, so that one read of the title between two of them loses none
function log(s) { ev.push("#" + (++n) + " " + ((performance.now() - t0) / 1000).toFixed(1) + " " + s);
	document.title = "wp3 $label " + ev.slice(-6).join(" | "); }
function at(ms, fn) { setTimeout(fn, ms); }
v.addEventListener("loadedmetadata", () => log("meta dur=" + f(v.duration)
	+ " sk=" + (v.seekable.length ? f(v.seekable.end(v.seekable.length - 1)) : "none")));
for (const e of ["pause", "seeking", "seeked", "play", "playing", "ended"])
	v.addEventListener(e, () => log(e + " ct=" + f(v.currentTime)
		+ " sk=" + (v.seekable.length ? f(v.seekable.end(v.seekable.length - 1)) : "none")));
setInterval(() => log("t ct=" + f(v.currentTime) + " dur=" + f(v.duration)
	+ " sk=" + (v.seekable.length ? f(v.seekable.end(v.seekable.length - 1)) : "none") + (v.paused ? " paused" : "")), 2000);
$script</script></body></html>
EOF

for t in $(wpteams); do kill -9 "$t"; done
rm -f /boot/home/config/settings/WebPositive/Session
e="WEBKIT_VIDEO_OVERLAY_LOG=2"
[ -n "${LIB:-}" ] && e="$e LIBRARY_PATH=$LIB:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
[ "${OVL:-1}" = 0 ] && e="$e WEBKIT_VIDEO_OVERLAY=0"
dbgStart=$(grep -a -c "entered the debugger" /var/log/syslog)
# shellcheck disable=SC2086
env $e /boot/system/apps/WebPositive "file://$page" > "$log" 2>&1 &
team=$!
start=$(date +%s)
say "started team $team (LIB=${LIB:-system} OVL=${OVL:-1})"
sleep 2
timeout 5 hey WebPositive set Frame of Window "wp3 $label - WebPositive" to "BRect(40,40,1639,939)" > /dev/null 2>&1

# the page's title, once per change; SNAP lines at their (approximate page) times
last="" said="" win=""
title() { timeout 2 hey WebPositive get Title of Window "$1" 2> /dev/null | sed -n 's/.*"\(wp3 [^"]*\)".*/\1/p'; }
end=$(( $(echo "$snaps" | tr ' ' '\n' | tail -n 1 | cut -d: -f1) + 4 ))
el=0
while [ $el -lt $end ]; do
	# the page's window: found once (WebPositive's never-shown windows do not answer)
	ti=""
	[ -n "$win" ] && ti=$(title "$win")
	if [ -z "$ti" ]; then
		win=""
		i=0
		while [ $i -lt 6 ] && [ -z "$win" ]; do
			ti=$(title $i)
			[ -n "$ti" ] && win=$i
			i=$((i + 1))
		done
	fi
	[ -n "$ti" ] && [ "$ti" != "$last" ] && { say "page ${ti#wp3 $label }"; last=$ti; }
	el=$(( $(date +%s) - start ))
	for s in $snaps; do
		case " $said " in *" $s "*) continue ;; esac
		[ "$el" -ge "${s%%:*}" ] && { say "SNAP ${s#*:}"; said="$said $s"; }
	done
	sleep 0.3
done
grep -a "^WVO" "$log" | grep -a -v "^WVO stats" | tail -n 20 | while read -r line; do say "$line"; done
grep -a "^WVO stats" "$log" | tail -n 1 | while read -r line; do say "$line"; done
timeout 10 hey WebPositive quit > /dev/null 2>&1
sleep 3
for t in $(wpteams); do say "WebPositive $t did not quit: killed"; kill -9 "$t"; done
say "debugger entries: $(( $(grep -a -c "entered the debugger" /var/log/syslog) - dbgStart ))"

#!/bin/sh
# g2-video.sh — KNOWN-ISSUES G2 / perf-round-h20.md C6: frames Firefox drops in the first clip after it starts.
# A UserBootscript (scripts/netboot-cycle.sh --bootscript, or mkimage/image-add for a card boot) that runs the
# plan in /boot/home/g2-plan.txt, one Firefox start per line:
#
#   LABEL DELAY PREREAD CLIP...
#
# DELAY: seconds the page waits after it loaded before the first clip; PREREAD 1: before Firefox starts, read
# every file of the Firefox package and of the system ffmpeg (/boot/system/lib/libav*, libsw*) with cat (the
# "decisive cheap A/B" of C6: does warming the file cache remove the drops?). A LABEL ending in "-log" runs
# Firefox with MOZ_LOG (time-stamped decoder and media-decoder modules) into /boot/home/g2-LABEL.moz; one ending
# in "-prio" raises the threads that present video frames to priority 15 (boost() below) while it plays; one
# with "-busy" in it runs two busy loops (two CPUs' worth of other work) during its first clip only.
# (On boot K of the same disk, /boot/home/g2-plan-K.txt instead, if it exists.)
# CLIP: a file in /boot/home (scripts/make-web-video-clips.sh, put there with --add), played in a 1280x720
# element, muted unless its name contains "aac" (an audio track: the audio sink starts with it).
# Each start: a copy of /boot/home/g2-profile-template, the profile the first start ever made (that start: a new
# profile; a card booted again finds the template), with /boot/home/g2-prefs-LABEL.js appended to its user.js
# if there is one (a pref experiment), Firefox quit with `hey Firefox quit`
# after the last clip (SIGKILL after 30 s). /boot/home/g2-LABEL.txt: Firefox's output.
# Per clip, serial lines "G2V LABEL clip N ...": frames/dropped (getVideoPlaybackQuality), time to first frame
# (src set -> first requestVideoFrameCallback), the longest gap between presented frames; "gaps N": every gap over
# 150 ms (start in the clip + length); "drops N": the drop count over time; "moz N": Firefox's parsed / decoded /
# presented / painted counters (decoder skips, VideoSink drops, compositor drops); "cpu N": CPU ms of the Firefox
# threads during the clip, TEAM:thread@priority, busiest 6 (`ps -a` at each clip's start). Then "team" lines (the
# Firefox teams) and "G2V end". With /boot/home/wakelat on the disk, its runs come first ("G2V WAKELAT ...").
out=/dev/dprintf
say() { echo "G2V $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
ffx=/boot/system/apps/Firefox/Firefox
plan=/boot/home/g2-plan.txt
tpl=/boot/home/g2-profile-template
export HOME=/boot/home MOZ_CRASHREPORTER_DISABLE=1
sleep 25
[ -x $ffx ] || { say "no $ffx"; say end; exit 0; }
# boot K of the same disk (a card booted again) runs /boot/home/g2-plan-K.txt when there is one
boot=$(( $(cat /boot/home/g2-boot-count 2> /dev/null || echo 0) + 1 ))
echo $boot > /boot/home/g2-boot-count
[ -f /boot/home/g2-plan-$boot.txt ] && plan=/boot/home/g2-plan-$boot.txt
[ -f $plan ] || { say "no $plan"; say end; exit 0; }
say "boot $boot of this disk, plan $plan"
say "uname: $(uname -a)"
say "plan: $(tr '\n' ';' < $plan)"
# the scheduler's wake-up latency first, with Firefox not running (tools/haiku-tests/wakelat.c, if on the disk):
# a 33 ms periodic thread at priority 10 / 15 next to 0, 2, 3 busy threads
if [ -x /boot/home/wakelat ]; then
	for c in "10 0" "10 2" "15 2" "10 3" "15 3" "10 4" "15 4"; do
		say "$(/boot/home/wakelat 33 300 $c 2000)"
	done
fi

# thread id -> "name UTime KTime" (ms), the Firefox teams' threads (as ffv-prof.sh)
snap() {
	ps -a | awk -v f="$ffx" '
		/^Team/ { getline; ff = index($0, f) > 0; kind = "T" $(NF - 3); next }
		ff && NF >= 5 && $(NF - 1) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ {
			name = $1; for (i = 2; i <= NF - 5; i++) name = name "_" $i
			print $(NF - 4), kind ":" name "@" $(NF - 2), $(NF - 1), $NF }' > "$1"
}
# boost: every second, the threads that bring a video frame to the screen (compositor, software WebRender,
# image bridge, media state machine, decoder threads) of the Firefox teams set to B_DISPLAY_PRIORITY (15)
boost() {
	while sleep 1; do
		ps -a | awk -v f="$ffx" '
			/^Team/ { getline; ff = index($0, f) > 0; next }
			ff && NF >= 5 && $(NF - 2) ~ /^[0-9]+$/ && $(NF - 2) < 15 {
				name = $1; for (i = 2; i <= NF - 5; i++) name = name " " $i
				if (name ~ /^(Renderer|SwComposite|Compositor|ImageBridge|WRRende|Media|av:|RemVid|Vsync|Canvas|IPC I\/O|IPDL)/)
					print $(NF - 4) }' | while read -r t; do prio $t 15 > /dev/null 2>&1; done
	done
}
cpudiff() {
	awk 'NR == FNR { u[$1] = $3; k[$1] = $4; next }
		($1 in u) { du = $3 - u[$1]; dk = $4 - k[$1]; t += du + dk; if (du + dk > 0) printf "%d %d %d %s\n", du + dk, du, dk, $2 }
		!($1 in u) { t += $3 + $4; if ($3 + $4 > 0) printf "%d %d %d %s(new)\n", $3 + $4, $3, $4, $2 }
		END { printf "%d 0 0 =total\n", t }' "$1" "$2" | sort -rn | head -n 7 \
		| awk '{ printf "%s %d(k%d) ", $4, $1, $3 }'
}

n=0
while read -r label delay preread clips; do
	[ -n "$label" ] || continue
	case "$label" in \#*) continue ;; esac
	n=$((n + 1))
	if [ "$preread" = 1 ]; then
		t0=$(date +%s%N)
		kb=$(find /boot/system/apps/Firefox /boot/system/lib -type f \( -path '*/apps/Firefox/*' \
			-o -name 'libav*' -o -name 'libsw*' \) -exec cat {} + | wc -c)
		say "$label preread: $((kb / 1048576)) MiB in $(ms $t0) ms"
	fi
	prof=/boot/home/g2-profile-$n
	rm -rf $prof
	if [ -d $tpl ]; then cp -a $tpl $prof; else mkdir -p $prof; fi
	cat > $prof/user.js << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
PREFS
	[ -f /boot/home/g2-prefs-$label.js ] && cat /boot/home/g2-prefs-$label.js >> $prof/user.js
	jsclips=$(for c in $clips; do printf '"%s",' "$c"; done)
	t0=$(date +%s%N)
	cat > /tmp/g2.html << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>g2</title></head>
<body style="margin:0;background:#000"><video id="v" width="1280" height="720" playsinline></video>
<script>
function p(s) { console.log("G2P " + s); }
const clips = [$jsclips], delay = $delay * 1000, launchMs = $((t0 / 1000000));
let i = 0;
p("load " + (Date.now() - launchMs) + " ms after the launch");
function play() {
  if (i >= clips.length) { p("done"); return; }
  const c = clips[i++], v = document.getElementById("v"), n = i;
  let first = -1, last = -1, maxGap = 0, gaps = [], drops = [], lastDrop = 0, ended = false, frames = 0;
  setTimeout(() => {
    p("start " + n + " " + c);
    const t0 = performance.now();
    const onFrame = (now, md) => {
      if (ended) return;
      frames++;
      if (first < 0) first = now - t0;
      else { const g = now - last; if (g > maxGap) maxGap = g;
        if (g > 150) gaps.push(((last - t0) / 1000).toFixed(2) + "+" + Math.round(g)); }
      last = now;
      v.requestVideoFrameCallback(onFrame);
    };
    if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(onFrame); else p("no requestVideoFrameCallback");
    const iv = setInterval(() => { const d = v.getVideoPlaybackQuality().droppedVideoFrames;
      if (d !== lastDrop) { drops.push(((performance.now() - t0) / 1000).toFixed(1) + ":" + d); lastDrop = d; } }, 250);
    const finish = (why) => { if (ended) return; ended = true; clearInterval(iv);
      const q = v.getVideoPlaybackQuality();
      p("clip " + n + " " + c + ": " + why + " t=" + v.currentTime.toFixed(1) + " in " + ((performance.now() - t0) / 1000).toFixed(1)
        + " s frames " + q.totalVideoFrames + " dropped " + q.droppedVideoFrames + " presented " + frames
        + " ttff " + Math.round(first) + " maxgap " + Math.round(maxGap));
      p("gaps " + n + " " + (gaps.slice(0, 12).join(" ") || "-"));
      p("drops " + n + " " + (drops.slice(0, 16).join(" ") || "-"));
      p("moz " + n + " parsed " + v.mozParsedFrames + " decoded " + v.mozDecodedFrames + " presented " + v.mozPresentedFrames
        + " painted " + v.mozPaintedFrames + " delay " + (v.mozFrameDelay || 0).toFixed(3));
      v.removeAttribute("src"); v.load();
      setTimeout(play, 2500); };
    v.onended = () => finish("ended");
    v.onerror = () => finish("error " + (v.error ? v.error.code + " " + v.error.message : "?"));
    v.muted = c.indexOf("aac") < 0;
    v.src = "file:///boot/home/" + c;
    v.play().catch(e => p(c + ": play() " + e));
    setTimeout(() => finish("timeout"), 20000);
  }, n === 1 ? delay : 0);
}
window.onload = play;
</script></body></html>
EOF
	log=""
	case "$label" in *-log) log="timestamp,PlatformDecoderModule:5,FFmpegVideo:4,MediaDecoder:3" ;; esac
	if [ -n "$log" ]; then
		MOZ_LOG="$log" MOZ_LOG_FILE=/boot/home/g2-$label.moz $ffx --no-remote --profile $prof \
			file:///tmp/g2.html > /tmp/g2-$n.txt 2>&1 < /dev/null &
	else
		$ffx --no-remote --profile $prof file:///tmp/g2.html > /tmp/g2-$n.txt 2>&1 < /dev/null &
	fi
	pid=$!
	bpid="" busy=""
	case "$label" in *-prio) boost & bpid=$! ;; esac
	# one grep every 0.5 s (the poll must not load the CPUs it measures); a snapshot at each clip's start and at "done"
	nclips=$(echo $clips | wc -w)
	w=0 last=0
	while [ $w -lt 1200 ]; do
		sleep 0.5
		w=$((w + 1))
		c=$(grep -a -c -E 'G2P (start|done)' /tmp/g2-$n.txt)
		if [ "$c" != "$last" ]; then
			snap /tmp/g2-snap-$n-$c
			last=$c
			case "$label:$c" in
			*-busy*:1) for b in 1 2; do sh -c 'while :; do :; done' & busy="$busy $!"; done ;;
			*-busy*:2) kill $busy; busy="" ;;
			esac
		fi
		[ "$c" -gt "$nclips" ] && break
	done
	[ -n "$bpid" ] && kill $bpid
	[ -n "$busy" ] && kill $busy
	say "$label: page done after $(ms $t0) ms"
	ps | grep -a "^$ffx" | awk '{ printf "T%s ", $(NF - 3); for (i = 2; i <= NF - 4; i++) if ($i ~ /^(tab|rdd|socket|utility|gpu|-contentproc|-isForBrowser)$/ || $i ~ /^[a-z]+$/) printf "%s ", $i; print "" }' \
		| cut -c1-150 | while IFS= read -r l; do say "$label team $l"; done
	tr -d '\r' < /tmp/g2-$n.txt | grep -a "G2P" | sed 's/^.*G2P //' | cut -c1-230 | while IFS= read -r l; do say "$label $l"; done
	j=1
	for c in $clips; do
		[ -f /tmp/g2-snap-$n-$j ] && [ -f /tmp/g2-snap-$n-$((j + 1)) ] && \
			say "$label cpu $j: $(cpudiff /tmp/g2-snap-$n-$j /tmp/g2-snap-$n-$((j + 1)))"
		j=$((j + 1))
	done
	hey Firefox quit > /dev/null 2>&1
	q=0
	while [ $q -lt 30 ] && kill -0 $pid 2> /dev/null; do sleep 1; q=$((q + 1)); done
	for t in $(ps | grep -a "^$ffx" | awk '{print $(NF-3)}'); do kill -9 $t 2> /dev/null; done
	say "$label: quit after $q s"
	if [ ! -d $tpl ]; then
		cp -a $prof $tpl
		rm -f $tpl/lock $tpl/.parentlock
		say "profile template: $(du -sk $tpl | cut -f1) KiB"
	fi
	cp /tmp/g2-$n.txt /boot/home/g2-$label.txt
	sleep 3
done < $plan
sync
say end

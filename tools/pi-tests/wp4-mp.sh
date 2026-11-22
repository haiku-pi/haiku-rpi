#!/bin/sh
# wp4-mp.sh MODE SRC LABEL — MediaPlayer on SRC, a file (absolute path) or a URL (http://, https://, file://), read
# through the media kit like any BUrl client (WP4, docs/design/webpositive-video-overlay.md §6: the BAdapterIO end-of-
# stream fix reaches every media-kit application that plays a URL). The position comes from hey (MediaPlayer's
# "Position" property, microseconds; printed in seconds).
#   seek   playing: the position at 6 s; seek to 40 s, 4 s later (expected 42–46); seek to 3 s, 4 s later (5–9);
#          paused: seek to 20 s, 2 s later (19–21, not moving), play, 3 s later (22–24)
#   end    SRC of LEN s (LEN=, default 15) played: the position and IsPlaying every second until LEN + 12 s; the
#          position must pass LEN - 1 s, without a stretch of 3 s or more in which it does not move before that
# LIB=DIR: DIR first in LIBRARY_PATH (a control libmedia.so). Lines "WP4 <label> ...", then MediaPlayer's decoder lines, the debugger entries since the start, and
# "WP4 <label> result: N problems". Run over ssh in a bench session (scripts/pi-session.sh, scripts/pi-ssh.sh).
mode=${1:?usage: wp4-mp.sh MODE SRC LABEL}
src=${2:?usage: wp4-mp.sh MODE SRC LABEL}
label=${3:?usage: wp4-mp.sh MODE SRC LABEL}
dir=$(cd "$(dirname "$0")" && pwd)
log=$dir/wp4-$label.log
problems=0
say() { echo "WP4 $label $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
pos() { timeout 5 hey MediaPlayer get Position of Window 0 2>&1 | grep -a '"result"' | grep -o -E ': -?[0-9]+' | head -n 1 | tr -d ': '; }
secs() { [ -n "$1" ] && awk -v p="$1" 'BEGIN { printf "%.2f", p / 1000000 }'; }
playing() { timeout 5 hey MediaPlayer get IsPlaying of Window 0 2>&1 | grep -a -o -E 'true|false' | head -n 1; }
setpos() { timeout 5 hey MediaPlayer set Position of Window 0 to int64 "$1" > /dev/null 2>&1; }
# in RANGE P LO HI (seconds): P within [LO, HI]
inrange() { [ -n "$1" ] && awk -v p="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(p >= lo * 1000000 && p <= hi * 1000000) }'; }

for t in $(players); do kill -9 "$t"; done
case "$src" in
*://*) ;;
*) rmattr Media:Frame "$src" 2> /dev/null ;;	# MediaPlayer resumes a file where it last stopped
esac
dbgStart=$(grep -a -c "entered the debugger" /var/log/syslog)
# LIB=DIR: DIR first in LIBRARY_PATH (e.g. another libmedia.so, a control)
[ -n "${LIB:-}" ] && export LIBRARY_PATH="$LIB:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
/boot/system/apps/MediaPlayer "$src" > "$log" 2>&1 &
say "started team $! on $src (LIB=${LIB:-system})"

case "$mode" in
seek)
	sleep 6
	say "position at 6 s: $(secs "$(pos)")"
	setpos 40000000
	sleep 4
	p=$(pos)
	say "seek to 40, 4 s later: $(secs "$p")"
	inrange "$p" 42 46 || fail "seek forward: $(secs "$p")"
	setpos 3000000
	sleep 4
	p=$(pos)
	say "seek to 3, 4 s later: $(secs "$p")"
	inrange "$p" 5 9 || fail "seek back: $(secs "$p")"
	timeout 5 hey MediaPlayer do Pause of Window 0 > /dev/null 2>&1
	sleep 1
	setpos 20000000
	sleep 2
	p1=$(pos)
	sleep 1
	p2=$(pos)
	say "paused, seek to 20: $(secs "$p1"), 1 s later $(secs "$p2") ($(playing))"
	inrange "$p1" 19 21 || fail "seek while paused: $(secs "$p1")"
	[ "$p1" = "$p2" ] || fail "the position moved while paused"
	timeout 5 hey MediaPlayer do Play of Window 0 > /dev/null 2>&1
	sleep 3
	p=$(pos)
	say "play, 3 s later: $(secs "$p")"
	inrange "$p" 22 24.5 || fail "play after the paused seek: $(secs "$p")"
	;;
end)
	len=${LEN:-15}
	i=0 last="" still=0 maxStill=0 maxPos=0
	while [ $i -lt $((len + 12)) ]; do
		sleep 1
		i=$((i + 1))
		p=$(pos)
		say "t=$i position $(secs "$p") $(playing)"
		[ -n "$p" ] || continue
		if [ "$p" = "$last" ] && [ "$p" -lt $(((len - 1) * 1000000)) ]; then
			still=$((still + 1))
			[ $still -gt $maxStill ] && maxStill=$still
		else
			still=0
		fi
		[ "$p" -gt "$maxPos" ] && maxPos=$p
		last=$p
	done
	say "furthest position $(secs "$maxPos"), longest still stretch before the end ${maxStill} s"
	[ "$maxPos" -ge $(((len - 1) * 1000000)) ] || fail "did not reach the end: $(secs "$maxPos")"
	[ $maxStill -lt 3 ] || fail "the position stood still for $maxStill s before the end"
	;;
*) say "unknown mode $mode"; exit 2 ;;
esac

hey MediaPlayer quit > /dev/null 2>&1 &
i=0
while [ -n "$(players)" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
for t in $(players); do fail "MediaPlayer $t did not quit: killed"; kill -9 "$t"; done
[ $i -lt 10 ] && say "quit in $i s"
grep -a -E "^AVCodecDecoder|^\[h264_mmal|mmal:|rpivid|No handler|error|Error" "$log" | sort | uniq -c | head -n 8 \
	| while read -r line; do say "log: $line"; done
dbg=$(( $(grep -a -c "entered the debugger" /var/log/syslog) - dbgStart ))
say "debugger entries: $dbg"
[ "$dbg" = 0 ] || fail "$dbg debugger entries"
say "result: $problems problems"

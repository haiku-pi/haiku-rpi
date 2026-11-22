#!/bin/sh
# mp3-failseek.sh MODE URL LABEL — MediaPlayer started on a URL that does not open (e.g. a 404), then one scripted
# command of MODE, as wp4-mp.sh sends them: seek (set Position to 20 s), seekby (set Seek +5 s), play (do Play), or
# all (seek, seekby, play, IsPlaying, Pause, Stop, seek to 3 s). Before the MP3 fix, a seek crashed in
# PlaybackManager::PlaylistFrameAtFrame() and Play in PlaybackManager::SetPlayMode() (no playing state until a file
# has opened). Afterwards: whether it entered the debugger and still answers. APP=PATH: that MediaPlayer binary
# (default the system one); LIB=DIR: DIR first in LIBRARY_PATH. Lines "MP3 <label> ...", the last one
# "MP3 <label> result: N problems".
mode=${1:?usage: mp3-failseek.sh MODE URL LABEL}
url=${2:?usage: mp3-failseek.sh MODE URL LABEL}
label=${3:?usage: mp3-failseek.sh MODE URL LABEL}
app=${APP:-/boot/system/apps/MediaPlayer}
problems=0
say() { echo "MP3 $label $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
dbg() { grep -a -c "entered the debugger" /var/log/syslog; }
# h VERB PROPERTY [to TYPE VALUE]: hey on MediaPlayer's window 0, the reply's result or error line
h() {
	verb=$1 prop=$2
	shift 2
	timeout 5 hey MediaPlayer "$verb" "$prop" of Window 0 "$@" 2>&1 | grep -a -E '"result"|error|Error' | head -n 1
}
[ -n "${LIB:-}" ] && export LIBRARY_PATH="$LIB:%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"
for t in $(players); do kill -9 "$t"; done
before=$(dbg)
"$app" "$url" > /dev/null 2>&1 &
team=$!
say "started team $team on $url (mode $mode, APP=$app LIB=${LIB:-system})"
sleep 6
say "get Position: $(h get Position)"
case "$mode" in
seek|all) say "set Position 20 s: $(h set Position to int64 20000000)"; sleep 1 ;;
esac
case "$mode" in
seekby|all) say "set Seek +5 s: $(h set Seek to int64 5000000)"; sleep 1 ;;
esac
case "$mode" in
play|all) say "do Play: $(h do Play)"; sleep 1; say "get IsPlaying: $(h get IsPlaying)" ;;
esac
if [ "$mode" = all ]; then
	say "do Pause: $(h do Pause)"
	say "do Stop: $(h do Stop)"
	say "set Position 3 s: $(h set Position to int64 3000000)"
	sleep 1
fi
after=$(dbg)
[ "$after" -gt "$before" ] && fail "$((after - before)) debugger entries"
kill -0 "$team" 2>/dev/null || fail "team $team is gone"
p=$(h get Position)
say "get Position after: $p"
[ -n "$p" ] || fail "MediaPlayer does not answer"
for t in $(players); do kill -9 "$t"; done
say "result: $problems problems"

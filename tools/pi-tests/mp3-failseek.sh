#!/bin/sh
# mp3-failseek.sh MODE URL LABEL — MediaPlayer started on a URL that does not open (e.g. a 404), then one scripted
# command of MODE, as wp4-mp.sh sends them: seek (set Position to 20 s), seekby (set Seek +5 s), play (do Play), or
# all (seek, seekby, play, IsPlaying, Pause, Stop, seek to 3 s). Before the MP3 fix, a seek crashed in
# PlaybackManager::PlaylistFrameAtFrame() and Play in PlaybackManager::SetPlayMode() (no playing state until a file
# has opened). The commands all go out at once 3 s after the start, each by its own hey, and wait up to 40 s for
# their reply: while the controller tries to open the URL (~20 s for a 404) the window blocks on the controller's
# lock, and once the open has failed it shows a modal "could not be opened" alert (BAlert::Go() on the window
# thread), after which it answers nothing; commands queued before that are handled first. A command counts as
# handled only when its reply arrived. APP=PATH: that
# MediaPlayer binary (default the system one); LIB=DIR: DIR first in LIBRARY_PATH. Lines "MP3 <label> ...", the
# last one "MP3 <label> result: N problems" (a debugger entry, a vanished team, a command without a reply).
mode=${1:?usage: mp3-failseek.sh MODE URL LABEL}
url=${2:?usage: mp3-failseek.sh MODE URL LABEL}
label=${3:?usage: mp3-failseek.sh MODE URL LABEL}
app=${APP:-/boot/system/apps/MediaPlayer}
problems=0
say() { echo "MP3 $label $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
dbg() { grep -a -c "entered the debugger" /var/log/syslog; }
# c NAME VERB PROPERTY [to TYPE VALUE]: hey on MediaPlayer's window 0 in the background, its output in $out/NAME
out=/tmp/mp3-failseek-$$
mkdir -p "$out"
n=0
c() {
	n=$((n + 1))
	name="$n-$1"
	shift
	(timeout 40 hey MediaPlayer "$1" "$2" of Window 0 $3 $4 $5 > "$out/$name" 2>&1) &
	pids="$pids $!"
}
pids=
[ -n "${LIB:-}" ] && export LIBRARY_PATH="$LIB:%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"
for t in $(players); do kill -9 "$t"; done
before=$(dbg)
"$app" "$url" > /dev/null 2>&1 &
team=$!
say "started team $team on $url (mode $mode, APP=$app LIB=${LIB:-system})"
sleep 3
case "$mode" in
seek|all) c set-Position-20s set Position to int64 20000000 ;;
esac
case "$mode" in
seekby|all) c set-Seek+5s set Seek to int64 5000000 ;;
esac
case "$mode" in
play|all) c do-Play do Play ;;
esac
if [ "$mode" = all ]; then
	c do-Pause do Pause
	c do-Stop do Stop
fi
for p in $pids; do wait "$p"; done
for f in "$out"/*; do
	r=$(grep -a -E 'Reply BMessage|error|Error' "$f" | head -n 1)
	say "$(basename "$f"): ${r:-NO REPLY}"
	echo "$r" | grep -q "Reply BMessage" || fail "$(basename "$f"): no reply"
done
rm -rf "$out"
after=$(dbg)
[ "$after" -gt "$before" ] && fail "$((after - before)) debugger entries"
kill -0 "$team" 2>/dev/null || fail "team $team is gone"
for t in $(players); do kill -9 "$t"; done
say "result: $problems problems"

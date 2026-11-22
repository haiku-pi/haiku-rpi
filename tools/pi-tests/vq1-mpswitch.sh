#!/bin/sh
# vq1-mpswitch.sh N MODE CLIP LABEL — N MediaPlayer H.264 decodes back to back (VQ1, KNOWN-ISSUES C17): each
# player plays CLIP for PLAY s (default 4), is ended, and the next one starts GAP s (default 1) after the old
# team is gone. MODE: kill (kill -9 while decoding), quit (hey MediaPlayer quit), mix (alternating).
# Before the fix (sources/haiku branch vq1-vchiq-unwire) a decode's first bulk transfers could panic in
# unlock_memory_etc() ("Failed to unwire page", thread VCHIQ-0): libroot's free() cut its heap area in the middle
# and the kernel unmapped the wired pages of a VCHIQ bulk buffer above the cut — 3 in 120 starts of
# artifacts/wp3/clips/play-720p30-aac.mp4 over http (design/videocore-services.md §8.3); other clips did not.
# Every iteration is also written to the serial console ("VQ1 <label> i/N ..."), next to the kernel's lines; a PANIC
# leaves the Pi in the kernel debugger, so this script's own output simply stops: read the serial log.
# APP=PATH: another MediaPlayer. Lines "VQ1 <label> ...", the last "VQ1 <label> result: N of M players entered
# the debugger, K never showed the VideoCore decoder".
n=${1:?usage: vq1-mpswitch.sh N MODE CLIP LABEL}
mode=${2:?usage: vq1-mpswitch.sh N MODE CLIP LABEL}
clip=${3:?usage: vq1-mpswitch.sh N MODE CLIP LABEL}
label=${4:?usage: vq1-mpswitch.sh N MODE CLIP LABEL}
app=${APP:-/boot/system/apps/MediaPlayer}
play=${PLAY:-4}
gap=${GAP:-1}
say() { echo "VQ1 $label $*"; echo "VQ1 $label $*" > /dev/dprintf; }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
dbg() { grep -a -c "entered the debugger" /var/log/syslog; }
clocks() { grep -a -c "H.264 clock maximum" /var/log/syslog; }
for t in $(players); do kill -9 "$t"; done
dbgStart=$(dbg)
noVc=0
i=0
while [ $i -lt "$n" ]; do
	i=$((i + 1))
	case "$mode" in
	mix) [ $((i % 2)) = 1 ] && how=kill || how=quit ;;
	*) how=$mode ;;
	esac
	rmattr Media:Frame "$clip" 2> /dev/null	# MediaPlayer resumes a file where it last stopped
	c0=$(clocks)
	"$app" "$clip" > /dev/null 2>&1 &
	team=$!
	say "$i/$n started team $team"
	sleep "$play"
	[ "$(clocks)" -gt "$c0" ] || { noVc=$((noVc + 1)); say "$i/$n: no H.264 clock line (not on the VideoCore?)"; }
	if [ "$how" = kill ]; then
		kill -9 "$team"
	else
		timeout 5 hey MediaPlayer quit > /dev/null 2>&1
	fi
	# the next player only once this one is gone (MediaPlayer is single-launch)
	w=0
	while [ -n "$(players)" ] && [ $w -lt 50 ]; do sleep 0.1; w=$((w + 1)); done
	[ -z "$(players)" ] || { say "$i/$n: still running after 5 s, killed"; for t in $(players); do kill -9 "$t"; done; }
	say "$i/$n ended team $team ($how)"
	sleep "$gap"
done
say "result: $(($(dbg) - dbgStart)) of $n players entered the debugger, $noVc never showed the VideoCore decoder"

#!/bin/sh
# wakelat.sh — a UserBootscript: the scheduler under a video-player-like load (tools/haiku-tests/wakelat.c in
# /boot/home): 2 or 3 periodic threads that each work 16 of every 33 ms (about what Firefox's software
# WebRender and its compositor thread need per 720p frame) next to 0-3 busy threads, the periodic threads at
# priority 10 or 15. Serial lines "WLT WAKELAT ...", "WLT end".
out=/dev/dprintf
say() { echo "WLT $*" > $out; }
sleep 25
for c in "10 0 16000 3" "10 1 16000 3" "10 2 16000 3" "15 2 16000 3" "10 3 16000 3" "15 3 16000 3" \
	"10 2 16000 2" "15 2 16000 2" "10 2 2000 1" "15 4 2000 1"; do
	say "$(/boot/home/wakelat 33 300 $c)"
done
say end

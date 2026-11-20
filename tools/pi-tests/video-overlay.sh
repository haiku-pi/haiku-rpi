#!/bin/sh
# video-overlay.sh — decoded video on a YCbCr display plane (docs/design/video-overlay.md): the overlay test
# and MediaPlayer's cost per clip. Run in a bench session (scripts/pi-ssh.sh) from the directory holding the
# clips (tools/media-tests/gen-h264-clips.sh's play-*.mp4, artifacts/v1-overlay/clips/play-hevc*.mp4),
# teamstat and overlaytest (default /boot/home/h264):
#
#   video-overlay.sh PHASE [LABEL] [ENV]
#
#   ovl          overlaytest: yuv420 at 320x240 (BT.601) and 1920x1080 (BT.709), rgb32, and ycbcr422 (must
#                fail: no packed 4:2:2 on the display); each holds its last frame 15 s for an HDMI snapshot
#   play         MediaPlayer on the H.264 and HEVC play clips (20 s measured from 5 s after the start): the
#                decoder and output lines, dropped frames, the team's and the system's CPU, the frames shown
#                (the overlay plane's updates in the display driver's statistics). LABEL names the run, ENV
#                (e.g. FFMPEG_YUV420=0) goes into the player's environment
#   hold CLIP    MediaPlayer on CLIP for 40 s (for HDMI snapshots taken from the host meanwhile)
#   rate         MediaPlayer on play-1080p60: its position after 15 s (real time: ~15 s of video; slow motion at
#                23.98 fps: ~6 s) and the frames shown
#   noplane      six overlaytests hold all six overlay planes, then MediaPlayer on play-1080p30: no overlay, so
#                it must fall back to B_RGB32 drawn by app_server (one "video output now B_RGB32" line, the
#                same decoder)
#   mode         MediaPlayer on play-1080p30, the screen to 1280x720 and back while it plays (KNOWN-ISSUES F2)
# CLIP=name (without .mp4): another clip for noplane and mode.
# MP=PATH runs another MediaPlayer binary (its file name must stay "MediaPlayer"); CLIPS="a b" plays only those
# (names without .mp4).
# Lines start with "VOV "; each phase ends with "VOV <phase> result: N problems".
phase=${1:?usage: video-overlay.sh PHASE [LABEL] [ENV]}
label=${2:-run}
envset=${3:-}
dir=/boot/home/h264
mp=${MP:-/boot/system/apps/MediaPlayer}
cd "$dir" || exit 1
problems=0
say() { echo "VOV $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
forget_positions() { for f in "$dir"/*.mp4; do rmattr Media:Frame "$f" 2> /dev/null; done; }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
quit_players() {
	hey MediaPlayer quit > /dev/null 2>&1 &
	i=0
	while [ -n "$(players)" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	for t in $(players); do say "MediaPlayer $t did not quit: killed"; kill -9 "$t"; done
	sleep 1
}
start_player() {	# CLIP LOG
	forget_positions
	if [ -n "$envset" ]; then
		env "$envset" "$mp" "$dir/$1" > "$2" 2>&1 &
	else
		"$mp" "$dir/$1" > "$2" 2>&1 &
	fi
	team=$!
}
# play_one CLIP NAME SECS
play_one() {
	log="$dir/$label-$2.log"
	syslogStart=$(wc -l < /var/log/syslog)
	start_player "$1" "$log"
	sleep 5
	./teamstat -i "$3" "$team" | while read -r line; do say "$label $2 $line"; done
	quit_players
	grep -a -E "^AVCodecDecoder|rpivid: hardware|rpivid: [0-9]+ pictures|MediaTrackVideoSupplier|NodeManager|VideoConsumer|retrying|falling back" \
		"$log" | sort | uniq -c | head -n 12 | while read -r line; do say "$label $2 log: $line"; done
	say "$label $2 dropped frames (VideoProducer): $(grep -a -c 'VideoProducer: dropped frame' "$log")"
	tail -n +$((syslogStart + 1)) /var/log/syslog \
		| grep -a -o "plane [0-9]: [0-9]* updates in [0-9]* vblanks, [0-9]* late.*" \
		| while read -r line; do say "$label $2 shown: $line"; done
}

case "$phase" in
ovl)
	for args in "-s yuv420" "-s yuv420 -x 1920x1080" "-s rgb32 -x 1920x1080"; do
		say "overlaytest $args"
		./overlaytest $args -f 120 -h 15 2>&1 | sed "s/^/VOV /"
	done
	say "overlaytest -s ycbcr422 (must fail: not offered)"
	./overlaytest -s ycbcr422 -f 10 -h 1 > "$dir/ovl422.log" 2>&1
	rc=$?
	sed "s/^/VOV /" "$dir/ovl422.log"
	[ $rc = 0 ] && fail "a B_YCbCr422 overlay was allocated"
	;;
play)
	for clip in ${CLIPS:-play-720p30 play-1080p30 play-1080p60 play-hevc-720p30 play-hevc-1080p30 play-hevc10-1080p30}; do
		[ -f "$dir/$clip.mp4" ] || { fail "no $clip.mp4"; continue; }
		play_one "$clip.mp4" "$clip" 20
	done
	;;
hold)
	clip=${2:?hold CLIP}
	label=hold
	start_player "$clip" "$dir/hold.log"
	sleep 40
	quit_players
	grep -a -E "^AVCodecDecoder|rpivid: hardware" "$dir/hold.log" | sort | uniq -c | while read -r line; do say "hold log: $line"; done
	;;
rate)
	label=rate
	start_player play-1080p60.mp4 "$dir/rate.log"
	sleep 15
	p=$(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)
	say "rate: position after 15 s: $p us"
	quit_players
	[ -n "$p" ] && [ "$p" -gt 11000000 ] || fail "play-1080p60 is not played at real time"
	tail -n 30 /var/log/syslog | grep -a -o "plane [0-9]: .*" | while read -r l; do say "rate shown: $l"; done
	;;
noplane)
	pids=""
	for i in 1 2 3 4 5 6; do
		./overlaytest -s rgb32 -f 10 -h 40 > "$dir/noplane-$i.log" 2>&1 &
		pids="$pids $!"
		sleep 2
	done
	sleep 3
	label=noplane
	clip=${CLIP:-play-1080p30}
	play_one $clip.mp4 $clip 10
	for t in $pids; do kill $t 2> /dev/null; done
	grep -a -q "video output now B_RGB32" "$dir/noplane-$clip.log" || fail "no fallback seen"
	;;
mode)
	label=mode
	start_player ${CLIP:-play-1080p30}.mp4 "$dir/mode.log"
	sleep 6
	screenmode 1280 720 > /dev/null 2>&1
	say "mode: 1280x720"
	sleep 6
	screenmode 1920 1080 > /dev/null 2>&1
	say "mode: 1920x1080"
	sleep 8
	quit_players
	tail -n 40 /var/log/syslog | grep -a -o "plane [0-9]: .*" | while read -r l; do say "mode shown: $l"; done
	;;
*)
	echo "unknown phase $phase" >&2
	exit 2
	;;
esac
say "$phase result: $problems problems"

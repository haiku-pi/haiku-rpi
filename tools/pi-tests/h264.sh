#!/bin/sh
# h264.sh — H21 step 3 on the Pi (docs/design/vchiq.md §8): H.264 through the media kit on the VideoCore (ffmpeg6's
# h264_mmal, the ffmpeg plugin's fallback, the vchiq driver's H.264 clock). Run in a bench session (scripts/pi-ssh.sh)
# from the directory holding tools/media-tests/gen-h264-clips.sh's files and teamstat (default /boot/home/h264):
#
#   h264.sh PHASE [DIR]
#
#   info    the packages, the decoder in libavcodec, the device's clock line, the VideoCore's memory
#   ffmpeg  ffmpeg -c:v h264_mmal on the MP4 clips (avcC): every frame against ffmpeg's software decode on the host
#           (with the samples below 16 lowered by one, vchiq.md §7.4), then timed decodes h264_mmal / h264 (4 threads)
#   clock   step 2's mmal-h264 (/boot/home/mmal) with the H.264 clock held (the default) and left to the firmware
#           (driver setting "video_clock false"), and the clock measured during each
#   play    MediaPlayer on play-720p30, play-1080p30 and play-1080p60, the hardware decoder and the software one
#           (FFMPEG_H264_MMAL=0): the decoder in use, dropped frames, the team's and the system's CPU over 20 s, the
#           frames shown (the overlay plane's updates, from the display driver's statistics)
#   seek    pause, play, seek forward and back, quit, reopen; screenshots
#   two     two players at once (a second window of MediaPlayer, which is single-launch), then a player with
#           ffmpeg's h264_mmal in another team and a second window: three decoders
#   kill    a player killed mid-decode (kill -9), then a new one
#   long    a 5.5-minute play: the team's areas and memory, the system's memory and the VideoCore's before and after
#   hevc    MediaPlayer on HEVC (rpivid): still decoded by the block
#   web     WebPositive on video.html (a <video> of play-720p30.mp4)
# Lines start with "H264 "; each phase ends with "H264 <phase> result: N problems".
phase=${1:?usage: h264.sh PHASE [DIR]}
dir=${2:-/boot/home/h264}
cd "$dir" || exit 1
problems=0
say() { echo "H264 $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
gpu() {
	cat /dev/vchiq 2> /dev/null | grep -a -E "^gencmd get_mem gpu|H.264 clock" | sed "s/^/H264 $1 /"
	# the VideoCore's free relocatable memory (where its decoder's buffers are)
	[ -x /boot/home/mmal/vchiq-gcmd ] && timeout 20 /boot/home/mmal/vchiq-gcmd "get_mem reloc" 2>&1 \
		| grep -a -o "reloc=.*" | sed "s/^/H264 $1 free /"
}
shot() { screenshot -s "$dir/shot-$1.png" > /dev/null 2>&1 && say "screenshot $dir/shot-$1.png"; }
# MediaPlayer resumes a file where it last stopped (its "Media:Frame" attribute): every play starts at the start
forget_positions() { for f in "$dir"/*.mp4; do rmattr Media:Frame "$f" 2> /dev/null; done; }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
# wait_for TEXT FILE SECS: until FILE has TEXT (0) or SECS pass (1)
wait_for() {
	i=0
	while [ $i -lt "$3" ]; do
		grep -a -q "$1" "$2" 2> /dev/null && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}
# quit_players: every MediaPlayer, by its scripting first, then killed after 10 s
quit_players() {
	hey MediaPlayer quit > /dev/null 2>&1 &
	i=0
	while [ -n "$(players)" ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	for t in $(players); do say "MediaPlayer $t did not quit: killed"; kill -9 "$t"; done
	sleep 1
}
# report LOG LABEL: the decoder lines and the dropped frames of a player's output
report() {
	grep -a -E "^AVCodecDecoder|^\[h264_mmal|mmal:|rpivid" "$1" | sort | uniq -c | head -n 8 \
		| while read -r line; do say "$2 log: $line"; done
	say "$2 dropped frames (VideoProducer): $(grep -a -c 'VideoProducer: dropped frame' "$1")"
}
# play_one FILE LABEL SECS [ENV]: start a player, measure SECS from 5 s after its start, quit it
play_one() {
	log="$dir/$2.log"
	syslogStart=$(wc -l < /var/log/syslog)
	forget_positions
	if [ -n "$4" ]; then
		forget_positions
		env "$4" /boot/system/apps/MediaPlayer "$dir/$1" > "$log" 2>&1 &
	else
		forget_positions
		/boot/system/apps/MediaPlayer "$dir/$1" > "$log" 2>&1 &
	fi
	team=$!
	sleep 5
	./teamstat -i "$3" "$team" | while read -r line; do say "$2 $line"; done
	[ "$5" = shot ] && shot "$2"
	quit_players
	report "$log" "$2"
	# the frames shown: the display driver's statistics of the video's overlay plane, when the player closes it
	tail -n +$((syslogStart + 1)) /var/log/syslog | grep -a -o "plane [0-9]: [0-9]* updates in [0-9]* vblanks, [0-9]* late" \
		| while read -r line; do say "$2 shown: $line"; done
}

case "$phase" in
info)
	ls /boot/system/packages | grep -E "ffmpeg6|raspberrypi" | while read -r p; do say "package $p"; done
	ls -l /dev/vchiq | while read -r line; do say "device: $line"; done
	if command -v ffmpeg > /dev/null; then
		ffmpeg -hide_banner -decoders 2> /dev/null | grep -E " h264" | while read -r line; do say "decoder: $line"; done
	fi
	gpu info:
	;;
ffmpeg)
	for name in h264-720p h264-1080p; do
		timeout 120 ffmpeg -nostdin -y -loglevel info -c:v h264_mmal -i "$name.mp4" -fps_mode passthrough -f framemd5 \
			-pix_fmt yuv420p "$name.mmal.framemd5" > "$name.ffmpeg-mmal.txt" 2>&1 || fail "$name: ffmpeg h264_mmal"
		tr '\r' '\n' < "$name.ffmpeg-mmal.txt" | grep -a -E "mmal:|MMAL|rror" | head -n 5 | while read -r line; do say "$name: $line"; done
		grep -v "^#" "$name.mmal.framemd5" | awk -F', *' '{print $6}' > "$name.mmal.md5"
		total=$(grep -v "^#" "$name.framemd5" | wc -l)
		decoded=$(wc -l < "$name.mmal.md5")
		mapped=$(paste -d ' ' "$name.mmal.md5" "$name.below16.md5" | awk '$1 == $2' | wc -l)
		say "$name: $decoded of $total frames decoded, $mapped equal to ffmpeg's with the samples below 16 lowered"
		[ "$mapped" = "$total" ] && [ "$decoded" = "$total" ] || fail "$name: frames differ"
		for codec in "h264_mmal" "h264 -threads 4" "h264 -threads 1"; do
			TIMEFORMAT="%R s, CPU %U s user %S s system"
			t=$( { time timeout 120 ffmpeg -nostdin -loglevel error -c:v $codec -i "$name.mp4" -f null - > out.txt 2>&1; } 2>&1 ) \
				|| fail "$name: ffmpeg $codec"
			say "$name: ffmpeg -c:v $codec: $t"
		done
	done
	;;
clock)
	# (the system's MMAL, mmal-h264 from this directory: step 2's with mmaldec's settings as options)
	m=/boot/home/mmal
	settings=/boot/home/config/settings/kernel/drivers/vchiq
	mkdir -p "$(dirname $settings)"
	for mode in held firmware held; do
		if [ $mode = firmware ]; then echo "video_clock false" > $settings; else rm -f $settings; fi
		for clip in h264-720p h264-1080p; do
			for o in 1 3; do
				timeout 60 ./mmal-h264 -q -o $o "$m/clips/$clip.h264" > out.txt 2>&1 || fail "mmal-h264 $clip ($mode)"
				grep -a -E "^MMAL (time|cpu)" out.txt | while read -r line; do say "clock $mode $clip, $o output buffers: $line"; done
			done
		done
		timeout 60 ./mmal-h264 -q -f OPQV "$m/clips/h264-1080p.h264" > /dev/null 2>&1 &
		sleep 1
		timeout 20 "$m/vchiq-gcmd" "measure_clock h264" 2>&1 | grep "dequeue" | sed "s/^VCHIQTEST dequeue /H264 clock $mode during a decode: /"
		wait
	done
	rm -f $settings
	syslog_lines=$(grep -a "vchiq: H.264 clock" /var/log/syslog | tail -n 6)
	echo "$syslog_lines" | while read -r line; do say "syslog: $line"; done
	gpu clock:
	;;
play)
	for clip in play-720p30 play-1080p30 play-1080p60; do
		play_one $clip.mp4 "$clip-hw" 20 "" shot
		play_one $clip.mp4 "$clip-sw" 20 FFMPEG_H264_MMAL=0 shot
	done
	gpu play:
	;;
seek)
	log="$dir/seek.log"
	gpu "seek before:"
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/play-1080p30.mp4" > "$log" 2>&1 &
	sleep 6
	say "position at 6 s: $(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)"
	hey MediaPlayer do Pause of Window 0 > /dev/null 2>&1
	sleep 3
	p1=$(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)
	sleep 2
	p2=$(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)
	say "paused: position $p1 then $p2"
	[ "$p1" = "$p2" ] || fail "the position moved while paused"
	shot seek-paused
	hey MediaPlayer do Play of Window 0 > /dev/null 2>&1
	sleep 3
	hey MediaPlayer set Position of Window 0 to int64 40000000 > /dev/null 2>&1
	sleep 4
	p=$(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)
	say "after a seek to 40 s and 4 s of play: position $p"
	[ -n "$p" ] && [ "$p" -gt 42000000 ] && [ "$p" -lt 46000000 ] || fail "seek forward: position $p"
	shot seek-forward
	hey MediaPlayer set Position of Window 0 to int64 10000000 > /dev/null 2>&1
	sleep 4
	p=$(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)
	say "after a seek back to 10 s and 4 s of play: position $p"
	[ -n "$p" ] && [ "$p" -gt 12000000 ] && [ "$p" -lt 16000000 ] || fail "seek back: position $p"
	shot seek-back
	for i in 1 2 3 4 5 6; do
		hey MediaPlayer set Position of Window 0 to int64 $((i * 7000000)) > /dev/null 2>&1
		sleep 1
	done
	sleep 3
	quit_players
	report "$log" seek
	# close and reopen, five times
	for n in 1 2 3 4 5; do
		forget_positions
		/boot/system/apps/MediaPlayer "$dir/play-720p30.mp4" > "$dir/reopen-$n.log" 2>&1 &
		sleep 6
		quit_players
		frames=$(grep -a -o "mmal: [0-9]* frames decoded" "$dir/reopen-$n.log" | awk '{print $2}')
		say "reopen $n: $(grep -a '^AVCodecDecoder' "$dir/reopen-$n.log" | head -n 1), ${frames:-no} frames from the VideoCore"
		[ -n "$frames" ] && [ "$frames" -gt 60 ] || fail "reopen $n: no hardware decode"
	done
	gpu "seek after:"
	;;
two)
	gpu "two before:"
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/play-1080p30.mp4" > "$dir/two-a.log" 2>&1 &
	a=$!
	sleep 5
	# a second window of the same team (MediaPlayer is single-launch: the running one opens it)
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/play-720p30.mp4" > "$dir/two-b.log" 2>&1
	sleep 8
	say "windows: $(hey MediaPlayer count Window 2>&1 | grep -o -E 'result.*' | head -n 1); teams: $(players | tr '\n' ' ')"
	./teamstat -i 10 $a | while read -r line; do say "two windows: $line"; done
	gpu "two windows:"
	shot two-windows
	quit_players
	report "$dir/two-a.log" "two windows"
	# another team at the same time (MediaPlayer is single-launch: a second one hands its file to the first):
	# ffmpeg's h264_mmal decoding the 1080p file while the player plays it, then a third decoder (two windows)
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/play-1080p30.mp4" > "$dir/two-c.log" 2>&1 &
	c=$!
	sleep 5
	timeout 120 ffmpeg -nostdin -loglevel info -c:v h264_mmal -i "$dir/play-1080p30.mp4" -t 20 -f null - > "$dir/two-d.log" 2>&1 &
	d=$!
	sleep 3
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/play-720p30.mp4" > "$dir/two-e.log" 2>&1
	sleep 7
	./teamstat -i 10 $c $d | while read -r line; do say "player + ffmpeg: $line"; done
	gpu "player + ffmpeg:"
	shot player-ffmpeg
	wait $d
	say "ffmpeg exit $?: $(grep -a -E 'mmal:|frame=' "$dir/two-d.log" | tr '\r' '\n' | grep -a -E 'mmal:|frame=' | tail -n 2 | tr '\n' ' ')"
	quit_players
	report "$dir/two-c.log" "player + ffmpeg"
	[ -z "$(players)" ] || fail "a player is left"
	;;
kill)
	gpu "kill before:"
	for n in 1 2 3; do
		forget_positions
		/boot/system/apps/MediaPlayer "$dir/play-1080p30.mp4" > "$dir/kill-$n.log" 2>&1 &
		t=$!
		sleep $((4 + n))
		kill -9 $t
		sleep 2
		say "killed $t after $((4 + n)) s: $(grep -a -c 'mmal: VideoCore' "$dir/kill-$n.log") hardware decoder(s) were open"
	done
	grep -a "vchiq:" /var/log/syslog | tail -n 8 | while read -r line; do say "syslog: $line"; done
	cat /dev/vchiq 2> /dev/null | grep -a -E "^State|Service|clone|H.264 clock" | head -n 12 | while read -r line; do say "vchiq: $line"; done
	play_one play-720p30.mp4 "after-kill" 10
	grep -a -q "mmal: VideoCore" "$dir/after-kill.log" || fail "no hardware decode after the kills"
	gpu "kill after:"
	;;
long)
	gpu "long before:"
	log="$dir/long.log"
	forget_positions
	/boot/system/apps/MediaPlayer "$dir/long-720p30.mp4" > "$log" 2>&1 &
	t=$!
	sleep 15
	./teamstat -i 10 $t | while read -r line; do say "long at 15 s: $line"; done
	gpu "long at 25 s:"
	sleep 270
	./teamstat -i 10 $t | while read -r line; do say "long at 295 s: $line"; done
	gpu "long at 305 s:"
	shot long
	sleep 30
	say "position at 335 s: $(hey MediaPlayer get Position of Window 0 2>&1 | grep -o -E '[0-9]{4,}' | head -n 1)"
	quit_players
	report "$log" long
	gpu "long after:"
	;;
hevc)
	for clip in hd.mp4 fhd.mp4; do
		[ -f "$dir/$clip" ] || { fail "no $clip"; continue; }
		play_one "$clip" "hevc-${clip%.mp4}" 10
	done
	grep -a -q "rpivid: hardware HEVC decode" "$dir/hevc-fhd.log" "$dir/hevc-hd.log" || fail "HEVC not on the block"
	;;
web)
	log="$dir/web.log"
	/boot/system/apps/WebPositive "file://$dir/video.html" > "$log" 2>&1 &
	t=$!
	sleep 25
	./teamstat -i 10 $t | while read -r line; do say "web: $line"; done
	shot web
	hey WebPositive quit > /dev/null 2>&1
	sleep 5
	kill -9 $t 2> /dev/null
	report "$log" web
	;;
*)
	say "unknown phase $phase"
	exit 2
	;;
esac
say "$phase result: $problems problems"

#!/bin/sh
# rpivid.sh — a UserBootscript for the HEVC decoder block (drivers/video/rpivid,
# docs/design/hw-video-decode.md). Serial console lines: "RPV ".
#
# Stage 1: opening /dev/video/rpivid/0 switches the block's clock on and checks its version register;
#          reading it returns the identification ("RPV ident rpivid: version 0x202, clock ... MHz").
# Stage 2/3 (with the test tree: tools/media-tests/gen-hevc-clips.sh + tools/media-tests/build.sh,
#          mkimage-pi4.sh --add-tree artifacts/media-tests/hevc/non-packaged): sandbench checks the SAND
#          conversion and measures its variants ("RPV SND ..."); hevcdec decodes each clip on the block
#          and on the CPU and compares every frame ("RPV HEV result PASS ..."), then measures both
#          ("RPV HEV bench ...", "RPV HEV speed ...": frames/s and CPU time per frame); the device's
#          report counts the phase overlaps of the pipeline. Then MediaPlayer plays fhd.mp4 (1080p,
#          20 Mbit/s) for 15 s (the HDMI capture shows it) and its rpivid log lines follow.
#          About 4-5 minutes after the desktop: capture with --secs 480.
sleep 20
out=/dev/dprintf
say() { echo "RPV $*" > $out; }
say begin
ls /dev/video 2>&1 | while read -r line; do say "dev video: $line"; done
ls /dev/video/rpivid 2>&1 | while read -r line; do say "dev rpivid: $line"; done
cat /dev/video/rpivid/0 2>&1 | while read -r line; do say "ident $line"; done
grep -a "rpivid" /var/log/syslog | tail -n 10 | while read -r line; do say "syslog: $line"; done

clips=/boot/system/non-packaged/data/hevc-tests
tool=/boot/system/non-packaged/bin/hevcdec
if [ -x /boot/system/non-packaged/bin/sandbench ]; then
	say "sandbench"
	/boot/system/non-packaged/bin/sandbench 2>&1 | while read -r line; do say "$line"; done
fi
if [ -x "$tool" ] && [ -d "$clips" ]; then
	for clip in intra.265 ipb.265 weighted.265 main10.265 hd.mp4 fhd.mp4 fhd10.mp4 uhd.mp4 uhd10.mp4; do
		[ -f "$clips/$clip" ] || continue
		say "decoding $clip"
		"$tool" "$clips/$clip" 2>&1 | while read -r line; do say "$line"; done
	done
	if [ -f "$clips/fhd.mp4" ]; then
		# the pictures write-combining instead of cached + invalidated after each decode
		say "decoding fhd.mp4, pictures uncached"
		FFMPEG_RPIVID_UNCACHED=1 "$tool" -bench-only -hw-only "$clips/fhd.mp4" 2>&1 \
			| while read -r line; do say "uncached $line"; done
	fi
	cat /dev/video/rpivid/0 2>&1 | while read -r line; do say "ident $line"; done

	movie=fhd.mp4
	[ -f "$clips/$movie" ] || movie=hd.mp4
	if [ -f "$clips/$movie" ]; then
		say "MediaPlayer $movie"
		/boot/system/apps/MediaPlayer "$clips/$movie" > /tmp/mediaplayer.log 2>&1 &
		player=$!
		sleep 15
		# quit, so that the decoder closes and its statistics line follows
		hey MediaPlayer quit > /dev/null 2>&1
		sleep 3
		kill $player 2>/dev/null
		grep -a "rpivid" /tmp/mediaplayer.log | head -n 12 | while read -r line; do say "player: $line"; done
		cat /dev/video/rpivid/0 2>&1 | while read -r line; do say "ident $line"; done
	fi
fi
grep -a "rpivid" /var/log/syslog | tail -n 10 | while read -r line; do say "syslog: $line"; done
say end

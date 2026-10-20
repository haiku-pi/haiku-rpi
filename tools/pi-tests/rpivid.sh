#!/bin/sh
# rpivid.sh — a UserBootscript for the HEVC decoder block (drivers/video/rpivid,
# docs/design/hw-video-decode.md). Serial console lines: "RPV ".
#
# Stage 1: opening /dev/video/rpivid/0 switches the block's clock on and checks its version register;
#          reading it returns the identification ("RPV ident rpivid: version 0x202, clock ... MHz").
# Stage 2/3 (with the test tree: tools/media-tests/gen-hevc-clips.sh + tools/media-tests/build.sh,
#          mkimage-pi4.sh --add-tree artifacts/media-tests/hevc/non-packaged): hevcdec decodes each clip
#          on the block and on the CPU and compares every frame ("RPV HEV result PASS ..."); then
#          MediaPlayer plays hd.mp4 for 15 s (the HDMI capture shows it) and its rpivid log lines follow.
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
if [ -x "$tool" ] && [ -d "$clips" ]; then
	for clip in intra.265 ipb.265 weighted.265 main10.265 hd.mp4; do
		[ -f "$clips/$clip" ] || continue
		say "decoding $clip"
		"$tool" "$clips/$clip" 2>&1 | while read -r line; do say "$line"; done
	done
	cat /dev/video/rpivid/0 2>&1 | while read -r line; do say "ident $line"; done

	if [ -f "$clips/hd.mp4" ]; then
		say "MediaPlayer hd.mp4"
		/boot/system/apps/MediaPlayer "$clips/hd.mp4" > /tmp/mediaplayer.log 2>&1 &
		player=$!
		sleep 15
		kill $player
		grep -a "rpivid" /tmp/mediaplayer.log | head -n 10 | while read -r line; do say "player: $line"; done
		cat /dev/video/rpivid/0 2>&1 | while read -r line; do say "ident $line"; done
	fi
fi
grep -a "rpivid" /var/log/syslog | tail -n 10 | while read -r line; do say "syslog: $line"; done
say end

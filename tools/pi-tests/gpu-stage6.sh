#!/bin/sh
# gpu-stage6.sh — a UserBootscript for GPU stage 6: full-screen GL on a firmware plane (page flips) and
# overlays (docs/design/gpu-stage6.md §8). Images from tools/pi-tests/gpu-stage6-image.sh: A = the
# packaged display driver, accelerant and app_server (no overlays: GL presents as in stage 5), B = the
# stage6 ones (overlays keyed by the desktop's alpha), C = B with the overlays above the desktop.
# Files under /boot/home/stage6: glflip, glview, present-bench, overlaytest, bitmapcheck; libgl/libGL.so.1
# (libglvnd stage6, through LIBRARY_PATH); egl/libEGL_mesa.so.0 + egl/50_mesa.json (Mesa stage6, through
# __EGL_VENDOR_LIBRARY_FILENAMES) — both only if there (an image whose packaged Mesa has stage 6 needs
# neither); clip.mp4 (if there: MediaPlayer plays it in a window, on an overlay).
# Serial console lines "GS6 ...": the components in use, present-bench's copy rows, bitmapcheck's hashes,
# overlaytest (HDMI: bars, a yellow window over them), glflip vsynced (1200 frames), unsynced, with a
# window over it, and through the window (HAIKU_EGL_OVERLAY=0) for comparison; Mesa's "egl_haiku:"
# rate and overlay lines. The display driver's "bcm2711_display: plane N: ..." lines come on the same
# console. On image C also sandprobe (SAND128 NV12 on a plane, three layouts, 5 s each: HDMI). "GS6 end"
# last. ~4 min after the desktop.
out=/dev/dprintf
say() { echo "GS6 $*" > $out; }
sleep 25
d=/boot/home/stage6
[ -e $d/libgl/libGL.so.1 ] && export LIBRARY_PATH="$d/libgl:$LIBRARY_PATH"
[ -e $d/egl/50_mesa.json ] && export __EGL_VENDOR_LIBRARY_FILENAMES=$d/egl/50_mesa.json
export HAIKU_EGL_FPS=1

say "app_server: $(ps | grep -o '[^ ]*servers/app_server' | head -n 1)"
say "screen: $(screenmode 2>&1 | head -n 1)"
for f in /boot/system/non-packaged/add-ons/kernel/drivers/dev/graphics/bcm2711_display \
		/boot/system/non-packaged/add-ons/accelerants/bcm2711_display.accelerant \
		/boot/home/config/settings/kernel/drivers/bcm2711_display; do
	[ -e "$f" ] && say "present: $f"
done
# which driver runs, and how (its boot lines)
grep -a -E 'loaded driver .*bcm2711_display|bcm2711_display: (overlays|no overlays|vertical blank)|v3d: cannot import' \
	/var/log/syslog 2> /dev/null | tail -n 4 | while read -r line; do say "syslog: $line"; done

# run NAME SECONDS COMMAND... — its lines to the console, then its exit status
run() {
	name=$1
	limit=$2
	shift 2
	log=/tmp/gs6-$name.txt
	timeout -s KILL $limit "$@" > $log 2>&1 < /dev/null
	status=$?
	grep -a -v '^$' $log | while read -r line; do say "$name: $line"; done
	say "$name: exit $status"
}

# the CPU copies of a frame, app_server's front buffer writers among them (alpha forced: keyed)
run bench 60 $d/present-bench -W 1920 -H 1080 -n 10 -s c
run bench-720 60 $d/present-bench -W 1280 -H 720 -n 20 -s c
run bench-480 60 $d/present-bench -W 640 -H 480 -n 40 -s c
run bitmapcheck 120 $d/bitmapcheck 1
run overlay 120 $d/overlaytest -f 240 -h 4
# a video in MediaPlayer's window (its overlay path: 4 bitmaps, transfer flips), then gone
if [ -e $d/clip.mp4 ]; then
	/boot/system/apps/MediaPlayer $d/clip.mp4 > /tmp/gs6-media.txt 2>&1 &
	player=$!
	sleep 15
	say "media: $(grep -a -c 'bcm2711_display: plane' /var/log/syslog 2> /dev/null) plane lines in the syslog so far"
	kill $player
	sleep 2
	grep -a -v '^$' /tmp/gs6-media.txt | tail -n 5 | while read -r line; do say "media: $line"; done
fi
# the exit test: 1200 vsynced frames at 60.00/s with no missed flip, then unsynced above 60
run flip-vsync 60 $d/glflip -w -n 1200 -i 1
run flip-free 60 $d/glflip -w -n 1200 -i 0
run flip-cover 60 $d/glflip -w -n 600 -i 1 -o
run flip-window 60 env HAIKU_EGL_OVERLAY=0 $d/glflip -w -n 600 -i 0
run glview 30 $d/glview -W 512 -s 5
# after the GL overlays went: keying starts again with the next overlay
run overlay-again 60 $d/overlaytest -s rgb32 -f 60 -h 1
# image C (overlays above the desktop): can the firmware scan the HEVC decoder's SAND128 pictures?
if grep -a -q 'bcm2711_display: overlays: .* above the desktop' /var/log/syslog 2> /dev/null; then
	run sand 60 $d/sandprobe
fi
say "temp: $(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 2> /dev/null)"
say end

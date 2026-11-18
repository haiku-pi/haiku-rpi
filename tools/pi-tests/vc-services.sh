#!/bin/sh
# vc-services.sh — the VideoCore's services beyond H.264 decoding in the media kit
# (docs/design/videocore-services.md): H.264 in Firefox (ffmpeg6's h264_vc), JPEG decode/encode and H.264 encode
# on the VideoCore (mmal-codec) against the CPU (jpegtime), the camera. Run in a bench session (scripts/pi-ssh.sh)
# from the directory holding the files (default /boot/home/vc):
#
#   vc-services.sh PHASE [ARGS]
#
#   probe              the firmware's MMAL components and their encodings, camera_info, gencmd get_camera
#   jpeg               every jpeg/*.jpg: the VideoCore (mmal-codec jpegdec, 5 times) and the CPU (jpegtime, 5 times);
#                      the 4032x3024 one's I420 decode written to jpeg/out-*.yuv (compared on the host)
#   jpegenc            src-*.yuv's first frame and photo-4032x3024.yuv to JPEG at quality 85 (enc-*.jpg)
#   h264enc            src-1280x720.yuv / src-1920x1080.yuv (30 frames, looped) to H.264, 300 frames, 4 / 8 Mbit/s
#                      (enc-*.h264), then the 1080p encode while MediaPlayer decodes a 1080p clip (h264_mmal)
#   ffenc              ffmpeg (with lib/'s libavcodec) encodes the raw clips with h264_mmal (ffenc-*.mp4), and
#                      transcodes 20 s of play-1080p30.mp4 (h264_vc -> h264_mmal)
#   venc               the media kit encodes (tools/media-tests/venc, BMediaFile as MediaConverter): H.264 (h264_mmal,
#                      through plugins/ffmpeg - a build with the H.264 encoder entry) and MPEG-4 (software)
#   firefox CLIP LABEL [ENV]
#                      Firefox (with lib/ - the test libavcodec - first in LIBRARY_PATH) plays CLIP looped and muted:
#                      the Firefox teams' CPU over 15 s from 15 s after the start, the frames decoded and dropped
#                      (getVideoPlaybackQuality, every 5 s), the H.264 clock lines and MMAL services; ENV (e.g.
#                      FFMPEG_H264_MMAL=0) in Firefox's environment; LABEL ending in "-log": with
#                      MOZ_LOG=FFmpegVideo:4 (the decoder Firefox picked; every frame logged, so not for timing)
# Lines start with "VCS "; each phase ends with "VCS <phase> result: N problems".
phase=${1:?usage: vc-services.sh PHASE [ARGS]}
dir=${VCS_DIR:-/boot/home/vc}
cd "$dir" || exit 1
problems=0
say() { echo "VCS $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }
gcmd() { [ -x ./vchiq-gcmd ] && timeout 20 ./vchiq-gcmd "$1" 2>&1 | grep -a "dequeue" | sed "s/^VCHIQTEST dequeue /VCS gencmd $1: /"; }
run() { "$@" 2>&1 | while IFS= read -r line; do say "$line"; done; }

case "$phase" in
probe)
	run ./mmal-codec probe
	gcmd "get_camera"
	gcmd "get_mem reloc"
	gcmd "get_mem gpu"
	gcmd "version"
	;;
jpeg)
	for f in jpeg/*.jpg; do
		b=$(basename "$f" .jpg)
		run ./mmal-codec jpegdec -n 5 -d "jpeg/out-$b.yuv" "$f"
		run ./jpegtime -n 5 "$f"
	done
	ls -l jpeg/out-*.yuv | while read -r line; do say "$line"; done
	# translators/JPEGTranslator (a test build, e.g. Haiku's v4-vc): taken before the system's one (same name, user
	# directory first); the translator's times and pixels again
	if [ -f translators/JPEGTranslator ]; then
		t=/boot/home/config/non-packaged/add-ons/Translators
		mkdir -p $t && cp translators/JPEGTranslator $t/
		for f in jpeg/*.jpg; do
			./jpegtime -n 5 "$f" 2>&1 | grep -a "translator" | while IFS= read -r line; do say "test translator: $line"; done
		done
		rm -f $t/JPEGTranslator
	fi
	;;
jpegenc)
	run ./mmal-codec jpegenc -n 5 -q 85 4032x3024 photo-4032x3024.yuv enc-4032x3024.jpg
	run ./mmal-codec jpegenc -n 10 -q 85 1920x1080 src-1920x1080.yuv enc-1920x1080.jpg
	;;
h264enc)
	run ./mmal-codec h264enc -n 300 -b 4000 -r 30 -g 60 1280x720 src-1280x720.yuv enc-1280x720.h264
	run ./mmal-codec h264enc -n 300 -b 8000 -r 30 -g 60 1920x1080 src-1920x1080.yuv enc-1920x1080.h264
	run ./mmal-codec h264enc -n 300 -b 8000 -r 30 -g 60 -p baseline 1920x1080 src-1920x1080.yuv enc-1920x1080-base.h264
	if [ -f play-1080p30.mp4 ]; then
		/boot/system/apps/MediaPlayer "$dir/play-1080p30.mp4" > mp.log 2>&1 &
		sleep 6
		gcmd "get_mem reloc"
		run ./mmal-codec h264enc -n 300 -b 8000 -r 30 -g 60 1920x1080 src-1920x1080.yuv enc-busy.h264
		hey MediaPlayer quit > /dev/null 2>&1
		sleep 2
		grep -a -E "AVCodecDecoder" mp.log | sort | uniq -c | while read -r line; do say "with MediaPlayer: $line"; done
	fi
	;;
ffenc)
	# ffmpeg's command line with the test libavcodec: h264_mmal (encoder) from raw frames and from an MP4
	# (decoded by h264_vc: the VideoCore decodes and encodes at once), the software decoder alongside
	for spec in "1280x720 4M" "1920x1080 8M"; do
		set -- $spec
		start=$(date +%s)
		LIBRARY_PATH="$dir/lib:$LIBRARY_PATH" timeout 300 ffmpeg -nostdin -y -hide_banner -loglevel info \
			-f rawvideo -pix_fmt yuv420p -s "$1" -r 30 -stream_loop 9 -i "src-$1.yuv" -frames:v 300 \
			-c:v h264_mmal -b:v "$2" "ffenc-$1.mp4" > "ffenc-$1.txt" 2>&1 || fail "ffmpeg h264_mmal $1"
		say "ffenc $1: $(( $(date +%s) - start )) s; $(grep -a -o 'frame= *[0-9]* fps=[0-9.]*' "ffenc-$1.txt" | tail -n 1)"
		grep -a -E "mmal:|Error|error" "ffenc-$1.txt" | head -n 4 | while IFS= read -r line; do say "ffenc $1: $line"; done
	done
	start=$(date +%s)
	LIBRARY_PATH="$dir/lib:$LIBRARY_PATH" timeout 300 ffmpeg -nostdin -y -hide_banner -c:v h264_vc -i play-1080p30.mp4 \
		-t 20 -c:v h264_mmal -b:v 6M -an transcode-1080p.mp4 > transcode.txt 2>&1 || fail "transcode"
	say "transcode 1080p 20 s (h264_vc -> h264_mmal): $(( $(date +%s) - start )) s;" \
		"$(grep -a -o 'frame= *[0-9]* fps=[0-9.]*' transcode.txt | tail -n 1)"
	grep -a -E "mmal:|h264_mmal|Error" transcode.txt | head -n 4 | while IFS= read -r line; do say "transcode: $line"; done
	;;
venc)
	# the media kit (BMediaFile, as MediaConverter): plugins/ffmpeg (a test build with the H.264 encoder entry)
	# before the system's plugin, lib/'s libavcodec (h264_mmal); MPEG-4 (FFmpeg's software encoder) to compare
	p=/boot/home/config/non-packaged/add-ons/media/plugins
	[ -f plugins/ffmpeg ] && mkdir -p $p && cp plugins/ffmpeg $p/
	for spec in "h264 1280x720" "h264 1920x1080" "mpeg4 1280x720" "mpeg4 1920x1080"; do
		set -- $spec
		LIBRARY_PATH="$dir/lib:$LIBRARY_PATH" timeout 300 ./venc -n 300 -s "$2" -c "$1" "venc-$1-$2.mp4" 2>&1 \
			| grep -a -E "^VENC|mmal" | grep -v "VENC encoder" | while IFS= read -r line; do say "$line"; done
	done
	LIBRARY_PATH="$dir/lib:$LIBRARY_PATH" ./venc -n 1 -s 320x240 -c none venc-list.mp4 2>&1 | grep -a "VENC encoder" \
		| while IFS= read -r line; do say "$line"; done
	rm -f $p/ffmpeg venc-list.mp4
	;;
firefox)
	clip=${2:?firefox CLIP LABEL [ENV]}
	label=${3:?firefox CLIP LABEL [ENV]}
	ffx=/boot/system/apps/Firefox/Firefox
	profile=$dir/ffx-profile
	mkdir -p "$profile"
	cat > "$profile/user.js" << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
user_pref("media.autoplay.default", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
PREFS
	cat > "$dir/ffv.html" << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>video</title></head>
<body style="margin:0;background:#000"><video id="v" width="1280" height="720" muted loop autoplay
 src="file://$dir/$clip"></video>
<script>
const v = document.getElementById("v"), t0 = performance.now();
setInterval(() => { const q = v.getVideoPlaybackQuality();
  console.log("VIDEO " + ((performance.now() - t0) / 1000).toFixed(1) + " s: " + v.videoWidth + "x" + v.videoHeight
    + " t=" + v.currentTime.toFixed(1) + " frames " + q.totalVideoFrames + " dropped " + q.droppedVideoFrames); }, 5000);
</script></body></html>
EOF
	log="$dir/ff-$label.log"
	syslogStart=$(wc -l < /var/log/syslog)
	logs=
	case "$label" in *-log) logs="FFmpegVideo:4,PlatformDecoderModule:4" ;; esac
	env ${4:-VCS_NONE=1} LIBRARY_PATH="$dir/lib:$LIBRARY_PATH" MOZ_LOG="$logs" MOZ_CRASHREPORTER_DISABLE=1 \
		$ffx --no-remote --profile "$profile" "file://$dir/ffv.html" > "$log" 2>&1 &
	sleep 15
	teams=$(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }')
	say "$label: Firefox teams $(echo $teams)"
	./teamstat -i 15 $teams | while IFS= read -r line; do say "$label $line"; done
	cat /dev/vchiq 2> /dev/null | grep -a -E "H.264 clock|Service [0-9]+:.*(mmal|MMAL)|fourcc" | head -n 6 \
		| while IFS= read -r line; do say "$label vchiq: $line"; done
	hey Firefox quit > /dev/null 2>&1
	sleep 8
	for t in $(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }'); do kill -9 "$t" 2> /dev/null; done
	grep -a "VIDEO" "$log" | sed 's/^.*VIDEO/VIDEO/' | head -n 12 | while IFS= read -r line; do say "$label $line"; done
	grep -a -E "software codec|h264_vc|h264_mmal|mmal:|VideoCore" "$log" | sed -e 's/^\[[^]]*\]: //' \
		| cut -c1-160 | sort | uniq -c | sort -rn | head -n 8 | while IFS= read -r line; do say "$label log: $line"; done
	tail -n +$((syslogStart + 1)) /var/log/syslog | grep -a -E "vchiq|mmal" | cut -c1-160 | tail -n 6 \
		| while IFS= read -r line; do say "$label syslog: $line"; done
	grep -a -c "entered the debugger" /var/log/syslog | while read -r n; do say "$label debugger entries so far: $n"; done
	;;
*)
	say "unknown phase $phase"
	exit 2
	;;
esac
say "$phase result: $problems problems"

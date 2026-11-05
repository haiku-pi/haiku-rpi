#!/bin/bash
# mmal.sh — the MMAL checks on the Pi (H21 step 2, docs/design/vchiq.md §7): H.264 decoded by the VideoCore
# (vc.ril.video_decode) through libmmal and /dev/vchiq. From the directory holding scripts/build-mmal.sh's
# mmal-h264, lib/ and clips/ (*.h264 and ffmpeg's *.framemd5), and step 1's vchiq_test (default /boot/home/mmal):
#
#   mmal.sh [DIR] [RUNS]
#
# 1. a 4 MiB bulk echo through the firmware's test service (a 1080p I420 frame is 3.1 MB; step 1 went to 1 MiB);
# 2. for each clip: a decode hashing every frame, compared frame by frame with ffmpeg's software decode, as it is
#    and with the samples below 16 lowered by one (what the VideoCore outputs for them, docs/design/vchiq.md §7.4:
#    the check), then RUNS (default 3) timed decodes without hashing (frames/s, CPU), and one with the frames left
#    on the VideoCore (opaque output: the decoder's own rate, no copies);
# 3. ffmpeg's own software decode of each clip, if ffmpeg is installed (time and CPU, for comparison);
# 4. the VideoCore's memory and temperature (gencmd through cat /dev/vchiq) before and after, the H.264 block's
#    clock during a decode (step 1's vchiq-gcmd, if there).
# Lines start with "MMAL "; the last one is "MMAL result: N problems".
dir=${1:-/boot/home/mmal}
runs=${2:-3}
cd "$dir" || exit 1
# (an ssh session has no LIBRARY_PATH: then the system's default after ours)
export LIBRARY_PATH="$dir/lib:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
problems=0
fail() { echo "MMAL FAIL: $*"; problems=$((problems + 1)); }
gencmd() { cat /dev/vchiq 2> /dev/null | grep -E "^gencmd (get_mem|measure_temp)" | sed "s/^/MMAL $1 /"; }

gencmd before:
if [ -x ./vchiq_test ]; then
	./vchiq_test -b 4096 10 > out.txt 2>&1 || fail "vchiq_test -b 4096 10"
	echo "MMAL bulk 4 MiB: $(tail -n 1 out.txt)"
fi

for clip in clips/*.h264; do
	name=$(basename "$clip" .h264)
	./mmal-h264 -e -m "$clip" > "$name.mmal.txt" 2>&1 || fail "$name: decode with hashes"
	grep -E "^MMAL (component|input|output|first|event|decoded|time|cpu|result)" "$name.mmal.txt" \
		| sed "s/^MMAL /MMAL $name: /"
	grep "^MMAL framemd5" "$name.mmal.txt" | awk '{print $4}' > "$name.mmal.md5"
	grep -v "^#" "clips/$name.framemd5" | awk -F', *' '{print $6}' > "$name.ffmpeg.md5"
	total=$(wc -l < "$name.ffmpeg.md5")
	decoded=$(wc -l < "$name.mmal.md5")
	equal=$(paste -d ' ' "$name.mmal.md5" "$name.ffmpeg.md5" | awk '$1 == $2' | wc -l)
	mapped=$(paste -d ' ' "$name.mmal.md5" "clips/$name.below16.md5" | awk '$1 == $2' | wc -l)
	echo "MMAL $name: bit-exact: $equal of $total frames equal to ffmpeg's; $mapped of $total with the samples" \
		"below 16 lowered by one ($decoded decoded)"
	[ "$mapped" = "$total" ] && [ "$decoded" = "$total" ] \
		|| { fail "$name: frames differ from ffmpeg's"; paste -d ' ' "$name.mmal.md5" "clips/$name.below16.md5" \
			| awk '$1 != $2 { print "MMAL   | frame " NR - 1 ": " $1 " != " $2 }' | head -n 3; }
	for ((run = 1; run <= runs; run++)); do
		./mmal-h264 -q "$clip" > out.txt 2>&1 || fail "$name: timed decode $run"
		grep -E "^MMAL (time|cpu)" out.txt | sed "s/^MMAL /MMAL $name run $run: /"
	done
	./mmal-h264 -q -f OPQV "$clip" > out.txt 2>&1 || fail "$name: opaque decode"
	grep -E "^MMAL (time|cpu)" out.txt | sed "s/^MMAL /MMAL $name opaque: /"
	if command -v ffmpeg > /dev/null; then
		for threads in 1 4; do
			TIMEFORMAT="%R s, CPU %U s user %S s system"
			t=$( { time ffmpeg -nostdin -loglevel error -threads $threads -i "$clip" -f null - > out.txt 2>&1; } \
				2>&1 ) || fail "$name: ffmpeg"
			echo "MMAL $name: ffmpeg software decode, $threads threads: $t"
		done
	fi
done

if [ -x ./vchiq-gcmd ]; then
	./mmal-h264 -q -f OPQV clips/$(ls clips | grep -m 1 'h264$') > /dev/null 2>&1 &
	sleep 1
	./vchiq-gcmd "measure_clock h264" "measure_clock core" "measure_clock arm" 2>&1 | grep "dequeue" \
		| sed 's/^VCHIQTEST dequeue /MMAL during a decode: /'
	wait
fi
gencmd after:
echo "MMAL result: $problems problems"

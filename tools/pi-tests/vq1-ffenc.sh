#!/bin/sh
# vq1-ffenc.sh N CLIP LABEL — VQ1's encode coverage: N ffmpeg runs back to back, each decoding CLIP on the
# VideoCore (h264_vc) and encoding it again there (h264_mmal, 6 Mbit/s) for SECS s (default 4) of video; odd runs are
# killed (kill -9) after 2 s, mid-transfer, even runs end by themselves. CLIP testsrc2=size=WxH:rate=R: encode
# ffmpeg's test pattern instead (no decoder; a 1080p decode + 1080p encode ran out of VideoCore memory on 11-22). The same bulk transfers into malloc()ed
# buffers as MediaPlayer's decoder (vchiq create_pagelist()), in both directions. Each run is also written to the
# serial console. Lines "VQ1 <label> ...", the last "VQ1 <label> result: E of N/2 complete runs failed, D debugger entries".
n=${1:?usage: vq1-ffenc.sh N CLIP LABEL}
clip=${2:?usage: vq1-ffenc.sh N CLIP LABEL}
label=${3:?usage: vq1-ffenc.sh N CLIP LABEL}
secs=${SECS:-4}
say() { echo "VQ1 $label $*"; echo "VQ1 $label $*" > /dev/dprintf; }
dbg() { grep -a -c "entered the debugger" /var/log/syslog; }
out=/tmp/vq1-ffenc
mkdir -p $out
dbgStart=$(dbg)
errors=0
i=0
while [ $i -lt "$n" ]; do
	i=$((i + 1))
	case "$clip" in
	testsrc2*)	# encode only: ffmpeg's test pattern (CLIP testsrc2=size=WxH:rate=R, lavfi's syntax)
		set -- -f lavfi -i "$clip" ;;
	*)	set -- -c:v h264_vc -i "$clip" ;;
	esac
	ffmpeg -nostdin -y -hide_banner "$@" -t "$secs" -c:v h264_mmal -b:v 6M -an \
		$out/enc.mp4 > $out/enc-$i.txt 2>&1 &
	pid=$!
	say "$i/$n started ffmpeg $pid"
	if [ $((i % 2)) = 1 ]; then
		sleep 2
		kill -9 $pid
		wait $pid 2> /dev/null
		say "$i/$n killed"
	else
		wait $pid
		rc=$?
		frames=$(grep -a -o 'frame= *[0-9]*' $out/enc-$i.txt | tail -n 1 | tr -d ' ')
		[ $rc = 0 ] || { errors=$((errors + 1)); grep -a -E "mmal|Error" $out/enc-$i.txt | head -n 3; }
		say "$i/$n exit $rc, $frames"
	fi
	sleep 1
done
say "result: $errors of $((n / 2)) complete runs failed, $(($(dbg) - dbgStart)) debugger entries"

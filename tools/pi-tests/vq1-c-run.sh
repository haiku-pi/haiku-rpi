#!/usr/bin/env bash
# vq1-c-run.sh IMAGE TAG [PHASE...] — VQ1's checks of one image in one network session (vq1-run.sh with KEEP=1, then
# the no-regression checks). Phases (default all, in this order):
#   vcut     vchiq_test_cut x10 (the deterministic VCHIQ case; panics without the kernel fix)
#   kill     MediaPlayer back to back on a local 1080p30 file, kill -9 (30)   quit   the same, `hey quit` (30)
#   urlkill  the same over http (wp4-httpd.py on 8095), kill (20)             thrmix over http at 1500 kB/s (8096), mixed (20)
#   enc      ffmpeg h264_mmal encodes of testsrc2 1080p30 back to back, odd runs killed (20)
#   audio    h264.sh audio: MediaPlayer with AAC on the VideoCore and on the CPU (CPU, frames shown, dropped)
#   ffv      ffv0.sh: Firefox plays h264-720p.mp4 and h264-1080p.mp4 (frames decoded / dropped, CPU)
# Labels TAG-<phase>. Needs wp4-httpd.py serving artifacts/media-tests/h264 on 10.42.0.1:8095 and artifacts/wp3/clips
# on 8096 for urlkill/thrmix. The session is stopped at the end.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
img=${1:?usage: vq1-c-run.sh IMAGE TAG [PHASE...]}; tag=${2:?}
shift 2
phases=${*:-vcut kill quit urlkill thrmix enc audio ffv}
R="$root/tools/pi-tests/vq1-run.sh"
export KEEP=1 PI_SESSION_LABEL=vq1
ssh=("$root/scripts/pi-ssh.sh")
date
for p in $phases; do
	case $p in
	vcut) "$R" "$img" vchiqcut 10 10 "$tag-vcut" ;;
	kill) "$R" "$img" kill 30 15 "$tag-kill" ;;
	quit) "$R" "$img" quit 30 15 "$tag-quit" ;;
	urlkill) URL=http://10.42.0.1:8095/f "$R" "$img" kill 20 10 "$tag-urlkill" play-720p30-aac.mp4 ;;
	thrmix) URL=http://10.42.0.1:8096/s1500 "$R" "$img" mix 20 10 "$tag-thrmix" play-720p30-aac.mp4 ;;
	enc) "$R" "$img" enc 20 10 "$tag-enc" testsrc2=size=1920x1080:rate=30 ;;
	audio)
		"$R" "$img" kill 1 1 "$tag-boot" > /dev/null	# a session, if none is up yet
		"${ssh[@]}" mkdir -p /boot/home/h264
		"${ssh[@]}" put "$root"/artifacts/media-tests/h264/play-{720p30,1080p30}-aac.mp4 "$root/artifacts/v7/bin/teamstat" \
			"$root/tools/pi-tests/h264.sh" /boot/home/h264/
		timeout 600 "${ssh[@]}" "sh /boot/home/h264/h264.sh audio /boot/home/h264" | grep -a "^H264"
		;;
	ffv)
		"$R" "$img" kill 1 1 "$tag-boot" > /dev/null
		"${ssh[@]}" mkdir -p /boot/home/ffv
		"${ssh[@]}" put "$root"/artifacts/media-tests/web/non-packaged/data/web-video/h264-{720p,1080p}.mp4 \
			"$root/tools/pi-tests/ffv0.sh" /boot/home/ffv/
		for c in h264-720p h264-1080p; do
			timeout 300 "${ssh[@]}" "sh /boot/home/ffv/ffv0.sh $c.mp4 $tag-$c" | grep -a "^FFV0" | grep -a -v " prof "
		done
		;;
	*) echo "vq1-c-run: no phase $p" >&2 ;;
	esac
done
"${ssh[@]}" "grep -a 'entered the debugger' /var/log/syslog | grep -a -v -c 'VQ1 '" | sed 's/^/VQ1C debugger entries: /'
"$root/scripts/pi-session.sh" stop | tail -n 1
date

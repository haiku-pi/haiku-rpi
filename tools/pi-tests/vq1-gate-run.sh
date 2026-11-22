#!/usr/bin/env bash
# vq1-gate-run.sh IMAGE [ITEM...] — host side of VQ1's merge gate (tools/pi-tests/vq1-gate.sh): a network session
# (scripts/pi-session.sh --label vq1b) of IMAGE, the gate's files copied to /boot/home/vq1 (+ /boot/home/ffv,
# /boot/home/vq1/blender), MP3's trigger clip served by wp4-httpd.py on 10.42.0.1:8097 for the run, the gate run
# over ssh, the session stopped. Output: the gate's "VQ1G" lines, then the serial log's PANIC lines (if any).
# PKG=FILE: a package for the gate's pkgman item.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
img=$(realpath "${1:?usage: vq1-gate-run.sh IMAGE [ITEM...]}")
shift
export PI_SESSION_LABEL=vq1b
ssh=("$root/scripts/pi-ssh.sh")
python3 "$root/tools/pi-tests/wp4-httpd.py" "$root/artifacts/wp3/clips" 10.42.0.1 8097 > /tmp/vq1-gate-httpd.log 2>&1 &
httpd=$!
trap 'kill $httpd 2> /dev/null' EXIT
"$root/scripts/pi-session.sh" start --image "$img" --label vq1b --minutes 120 > /dev/null || exit 1
ulog=$(ls -t "$root"/artifacts/uart/*-session-vq1b.log | head -n 1)
echo "VQ1GRUN session up (serial log $ulog)"
"${ssh[@]}" mkdir -p /boot/home/vq1/blender /boot/home/ffv
"${ssh[@]}" put "$root"/tools/pi-tests/vq1-{gate,mpswitch,vchiqcut}.sh "$root"/artifacts/vq1/bin/{pshcut,vchiq_test_cut} \
	"$root/artifacts/gl-build/gl-tests/clientptr" ${PKG:+"$PKG"} /boot/home/vq1/
"${ssh[@]}" put "$root"/tools/pi-tests/blender-{b7-view.sh,b7-view.py,m5-scene.py} /boot/home/vq1/blender/
"${ssh[@]}" put "$root"/artifacts/media-tests/web/non-packaged/data/web-video/h264-1080p.mp4 \
	"$root/tools/pi-tests/ffv0.sh" /boot/home/ffv/
timeout 5400 "${ssh[@]}" "sh /boot/home/vq1/vq1-gate.sh http://10.42.0.1:8097/f/play-720p30-aac.mp4 $*" | grep -a "^VQ1G"
echo "VQ1GRUN serial: $(grep -a -c 'PANIC' "$ulog") PANIC lines, $(grep -a -c 'pkgman exit 0' "$ulog") session pkgman installs ok"
grep -a -A3 "PANIC" "$ulog" | head -n 8
"$root/scripts/pi-session.sh" stop | tail -n 1

#!/usr/bin/env bash
# avsync-measure.sh OUT.mkv SECS | --analyze FILE — A/V sync of the flash+beep clip
# (tools/media-tests/gen-avsync-clip.sh) as the Pi shows it: SECS of the HDMI capture card's video and audio
# (HDMI_GRABBER, and its USB audio device: HDMI_AUDIO in local.conf, default hw:CARD=Video,DEV=0) into OUT.mkv,
# then --analyze: each flash's start (the picture's mean brightness crossing half way, in a centre crop) against
# the nearest beep's start (audio amplitude above a threshold), audio minus video in ms, per flash and the median.
# Positive: the sound comes late. FILE can also be the clip itself (should be ~0: checks the method).
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib/bench.sh" 2> /dev/null || true
[ -f "$(dirname "$0")/../../local.conf" ] && . "$(dirname "$0")/../../local.conf"
if [ "${1:-}" != --analyze ]; then
	out=${1:?usage: avsync-measure.sh OUT.mkv SECS | --analyze FILE}
	secs=${2:?usage: avsync-measure.sh OUT.mkv SECS}
	timeout --foreground $((secs + 20)) ffmpeg -hide_banner -loglevel error -y \
		-thread_queue_size 1024 -f v4l2 -input_format yuyv422 -video_size 1920x1080 -i "${HDMI_GRABBER:-/dev/video4}" \
		-thread_queue_size 1024 -f alsa -i "${HDMI_AUDIO:-hw:CARD=Video,DEV=0}" -t "$secs" \
		-c:v libx264 -preset ultrafast -crf 30 -c:a pcm_s16le "$out" < /dev/null
	set -- --analyze "$out"
fi
f=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ffmpeg -hide_banner -loglevel error -i "$f" -map 0:v:0 \
	-vf "crop=iw/4:ih/4:iw*3/8:ih*3/8,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$tmp/v.txt" \
	-f null - < /dev/null
ffmpeg -hide_banner -loglevel error -i "$f" -map 0:a:0 -ac 1 -ar 48000 -f s16le "$tmp/a.raw" < /dev/null
vstart=$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$f")
astart=$(ffprobe -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$f")
python3 - "$tmp/v.txt" "$tmp/a.raw" "$vstart" "$astart" << 'PY'
import sys, array, statistics
vfile, afile, vstart, astart = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
frames = []
t = None
for line in open(vfile):
    if line.startswith("frame:"):
        t = float(line.split("pts_time:")[1])
    elif "YAVG=" in line and t is not None:
        frames.append((t, float(line.split("=")[1])))
lo = min(y for _, y in frames); hi = max(y for _, y in frames); mid = (lo + hi) / 2
flashes = [frames[i][0] for i in range(1, len(frames)) if frames[i][1] > mid >= frames[i - 1][1]]
a = array.array("h"); a.frombytes(open(afile, "rb").read())
peak = max(abs(x) for x in a) or 1
thr = peak * 0.3
beeps, last = [], -1.0
for i, x in enumerate(a):
    if abs(x) > thr:
        ts = astart + i / 48000.0
        if ts - last > 0.5:
            beeps.append(ts)
        last = ts
diffs = []
for fv in flashes:
    if not beeps:
        break
    b = min(beeps, key=lambda b: abs(b - fv))
    if abs(b - fv) < 0.45:
        diffs.append((b - fv) * 1000)
print("avsync: %d flashes, %d beeps, %d pairs (video range %.0f-%.0f, peak %d)" % (len(flashes), len(beeps), len(diffs), lo, hi, peak))
if diffs:
    print("avsync: audio - video ms: median %.1f, min %.1f, max %.1f; each: %s" % (statistics.median(diffs), min(diffs), max(diffs), " ".join("%.0f" % d for d in diffs[:40])))
PY

#!/usr/bin/env bash
# g1-speckles.sh [--image IMG] — KNOWN-ISSUES G1: do the HDMI "speckles" come with memory load alone (the HVS
# running short of bandwidth, which a monitor would show too) or only while a GL program runs? A network
# session of IMG (default the regular image); HDMI frames (scripts/lib/bench.sh hdmi_snap) of the static
# desktop: 3 idle, 3 while tools/haiku-tests/memhog.c copies memory on 4 CPUs, 3 while GLTeapot runs. Each frame
# is compared with the first idle one: pixels that differ by more than 64 in a channel, outside the Deskbar
# (top right) and, for the GL program, outside its window's area, are counted as speckles. G1_GL: the GL
# command (default GLTeapot; e.g. G1_GL='glview -W 1000 -s 40' on the mega image).
# Frames and counts: artifacts/g1/<ts>/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/lib/bench.sh"
img="$root/artifacts/images/haiku-pi4-regular.img"
[ "${1:-}" = --image ] && img="$(realpath "$2")"
out="$root/artifacts/g1/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc"
"$g" --sysroot="$root/artifacts/sysroot-arm64" -O2 -o "$out/memhog" "$root/tools/haiku-tests/memhog.c"
ssh="$root/scripts/pi-ssh.sh"
"$root/scripts/pi-session.sh" start --minutes 20 --image "$img" --label g1 > /dev/null
"$ssh" put "$out/memhog" /boot/home/ > /dev/null
sleep 20
for i in 1 2 3; do hdmi_snap "$out/idle-$i.png"; sleep 3; done
"$ssh" '/boot/home/memhog 25 4 > /tmp/memhog.txt 2>&1 &' > /dev/null
sleep 5
for i in 1 2 3; do hdmi_snap "$out/memhog-$i.png"; sleep 4; done
sleep 12
"$ssh" 'cat /tmp/memhog.txt' > "$out/memhog.txt" 2>&1 || true
glcmd="${G1_GL:-/boot/system/demos/GLTeapot}"
"$ssh" "$glcmd > /dev/null 2>&1 &" > /dev/null
sleep 8
for i in 1 2 3; do hdmi_snap "$out/glteapot-$i.png"; sleep 3; done
"$ssh" 'kill $(ps | grep -a -E "GLTeapot|glview" | grep -v grep | awk "{print \$2}") 2> /dev/null' > /dev/null 2>&1 || true
"$root/scripts/pi-session.sh" stop > /dev/null 2>&1 || true
python3 - "$out" << 'PY'
import sys, glob, os
from PIL import Image, ImageChops
d = sys.argv[1]
ref = Image.open(os.path.join(d, 'idle-1.png')).convert('RGB')
w, h = ref.size
def count(p, mask_box=None):
	im = Image.open(p).convert('RGB')
	diff = ImageChops.difference(ref, im).load()
	n = 0
	for y in range(h):
		for x in range(w):
			if x > w - 200 and y < 120:
				continue	# the Deskbar (clock)
			if mask_box and mask_box[0] <= x < mask_box[2] and mask_box[1] <= y < mask_box[3]:
				continue
			r, g, b = diff[x, y]
			if r > 64 or g > 64 or b > 64:
				n += 1
	return n
# GLTeapot's window: the bounding box of what differs a lot in the first GLTeapot frame (its window is solid)
gl = sorted(glob.glob(os.path.join(d, 'glteapot-*.png')))
box = None
if gl:
	bb = ImageChops.difference(ref, Image.open(gl[0]).convert('RGB')).convert('L').point(lambda v: 255 if v > 64 else 0)
	# take the largest region: approximate with the bounding box after dropping isolated dots (a 9x9 min filter)
	from PIL import ImageFilter
	solid = bb.filter(ImageFilter.MinFilter(9))
	box = solid.getbbox()
	if box:
		box = (box[0] - 8, box[1] - 40, box[2] + 8, box[3] + 8)
with open(os.path.join(d, 'counts.txt'), 'w') as f:
	for p in sorted(glob.glob(os.path.join(d, '*.png'))):
		name = os.path.basename(p)
		n = count(p, box if name.startswith('glteapot') else None)
		line = f'G1 {name}: {n} speckle pixels ({100.0 * n / (w * h):.3f} %)'
		print(line)
		f.write(line + '\n')
	print(f'G1 GLTeapot window masked: {box}')
PY
cat "$out/memhog.txt" 2>/dev/null | grep MEMHOG || true
echo "g1-speckles: $out"

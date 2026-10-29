#!/usr/bin/env bash
# mega-smoke.sh [--image IMG] [--secs N] — start every Test Apps entry of the mega image on the bench Pi and
# see that it runs and draws: a network session of IMG (default artifacts/images/haiku-pi4-mega.img; the card
# is not touched), the image's first-boot setup (tools/mega/first-boot.sh: the Test Apps folder, the Wine
# prefix), then tools/mega/smoke-pi.sh. For each entry: still running after N s (default 25), and how much of
# the screen differs from the bare desktop (a share of pixels; a program that draws nothing scores ~0).
# Results: artifacts/mega-smoke/<ts>/ (smoke.txt, the screenshots, the programs' ~/mega-logs).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-mega.img" secs=25
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	*) sed -n '2,7p' "$0" >&2; exit 2 ;;
	esac
done
out="$root/artifacts/mega-smoke/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
ssh="$root/scripts/pi-ssh.sh"
"$root/scripts/pi-session.sh" start --minutes 120 --image "$img" --label mega-smoke
trap '"$root/scripts/pi-session.sh" stop > /dev/null 2>&1 || true' EXIT
"$ssh" put "$root/tools/mega/first-boot.sh" "$root/tools/mega/smoke-pi.sh" /boot/home/
# first-boot.sh waits 15 s for the desktop, then sets up the folder and Wine (~2 min)
"$ssh" 'sh /boot/home/first-boot.sh; tail -n 5 /boot/home/mega-logs/first-boot.log' | tee "$out/first-boot.txt"
# detached on the Pi (an ssh connection may drop while a game runs), its lines polled into smoke.txt
"$ssh" "rm -rf /boot/home/smoke; mkdir -p /boot/home/smoke; nohup sh /boot/home/smoke-pi.sh $secs \
	> /boot/home/smoke-out.txt 2>&1 < /dev/null &"
lines=0 drops=0
while :; do
	sleep 20
	if ! "$ssh" cat /boot/home/smoke-out.txt > "$out/smoke.txt.new" 2> /dev/null; then
		drops=$((drops + 1))
		echo "mega-smoke: no ssh answer ($drops)" >&2
		[ $drops -lt 30 ] && continue
		echo "mega-smoke: the Pi stopped answering" >&2; exit 1
	fi
	mv "$out/smoke.txt.new" "$out/smoke.txt"
	n=$(grep -c '^SMOKE ' "$out/smoke.txt" || true)
	if [ "$n" -gt "$lines" ]; then
		grep '^SMOKE ' "$out/smoke.txt" | tail -n +$((lines + 1))
		lines=$n
	fi
	grep -q '^SMOKE end' "$out/smoke.txt" && break
done
[ $drops -gt 0 ] && echo "mega-smoke: ssh did not answer $drops times" | tee -a "$out/smoke.txt"
"$ssh" get /boot/home/smoke /boot/home/mega-logs "$out/" > /dev/null
python3 - "$out" <<'EOF'
import sys, os
from PIL import Image, ImageChops
out = sys.argv[1]
base = Image.open(os.path.join(out, "smoke", "00.png")).convert("RGB")
for line in open(os.path.join(out, "smoke.txt")):
	if not line.startswith("SMOKE ") or line.startswith("SMOKE end"):
		continue
	nn = line.split()[1]
	path = os.path.join(out, "smoke", nn + ".png")
	if not os.path.exists(path):
		print(line.rstrip(), "| no screenshot")
		continue
	shot = Image.open(path).convert("RGB")
	if shot.size != base.size:
		print(line.rstrip(), "| screen %dx%d (mode changed)" % shot.size)
		continue
	diff = ImageChops.difference(shot, base).convert("L").point(lambda v: 255 if v > 24 else 0)
	share = sum(diff.histogram()[255:]) / (shot.size[0] * shot.size[1])
	print(line.rstrip(), "| %.1f %% of the screen changed" % (100 * share))
EOF

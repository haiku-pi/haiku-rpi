#!/usr/bin/env bash
# mega-smoke.sh [--image IMG] [--secs N] [--label L] [--no-tracker] — start every Test Apps entry of the mega image
# on the bench Pi and see that it runs and draws: a network session of IMG (default
# artifacts/images/haiku-pi4-mega.img; the card is not touched; session label L, default mega-smoke), the image's
# first-boot setup (tools/mega/first-boot.sh: the Test Apps folder, the Wine prefix), then tools/mega/smoke-pi.sh
# (each entry by exec from a shell). For each entry: still running after N s (default 25), and how much of the
# screen differs from the bare desktop (a share of pixels; a program that draws nothing scores ~0).
# Then the way a double-click starts them (unless --no-tracker): tools/pi-tests/ta1-sweep.sh opens every Test Apps
# entry and the Deskbar entries the image adds through Tracker (tools/haiku-tests/trackeropen.cpp, built here);
# each must show a window and still show it 10 s later ("TRACKER result"; exit 3 otherwise).
# Results: artifacts/mega-smoke/<ts>/ (smoke.txt, tracker.txt, the screenshots, the programs' ~/mega-logs).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-mega.img" secs=25 label=mega-smoke tracker=1
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--no-tracker) tracker=0; shift ;;
	*) sed -n '2,11p' "$0" >&2; exit 2 ;;
	esac
done
out="$root/artifacts/mega-smoke/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
ssh="$root/scripts/pi-ssh.sh"
if [ "$tracker" = 1 ]; then
	g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++"
	"$g" --sysroot="$root/artifacts/sysroot-arm64" -O2 -I "$root/sources/haiku/headers/private/interface" \
		-I "$root/sources/haiku/headers/private/app" -o "$out/trackeropen" "$root/tools/haiku-tests/trackeropen.cpp" -lbe
fi
"$root/scripts/pi-session.sh" start --minutes 120 --image "$img" --label "$label"
trap '"$root/scripts/pi-session.sh" stop > /dev/null 2>&1 || true' EXIT
"$ssh" put "$root/tools/mega/first-boot.sh" "$root/tools/mega/smoke-pi.sh" /boot/home/
# first-boot.sh waits 15 s for the desktop, then sets up the folder and Wine (~2 min)
"$ssh" 'sh /boot/home/first-boot.sh; tail -n 5 /boot/home/mega-logs/first-boot.log' | tee "$out/first-boot.txt"
# detached on the Pi (an ssh connection may drop while a game runs), its lines polled into smoke.txt
"$ssh" "rm -rf /boot/home/smoke; mkdir -p /boot/home/smoke; nohup sh /boot/home/smoke-pi.sh $secs \
	> /boot/home/smoke-out.txt 2>&1 < /dev/null &"
# poll REMOTE-FILE LOCAL-FILE TAG: copy the Pi's output file until its "TAG end" line, printing new TAG lines
poll() {
	local lines=0 drops=0 n
	while :; do
		sleep 20
		if ! "$ssh" cat "$1" > "$2.new" 2> /dev/null; then
			drops=$((drops + 1))
			echo "mega-smoke: no ssh answer ($drops)" >&2
			[ $drops -lt 30 ] && continue
			echo "mega-smoke: the Pi stopped answering" >&2; exit 1
		fi
		mv "$2.new" "$2"
		n=$(grep -c "^$3 " "$2" || true)
		if [ "$n" -gt "$lines" ]; then
			grep "^$3 " "$2" | tail -n +$((lines + 1))
			lines=$n
		fi
		grep -q "^$3 end" "$2" && break
	done
	[ $drops -gt 0 ] && echo "mega-smoke: ssh did not answer $drops times" | tee -a "$2"
	return 0
}
poll /boot/home/smoke-out.txt "$out/smoke.txt" SMOKE
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
[ "$tracker" = 1 ] || exit 0

# the Tracker path (a double-click, a Deskbar menu item): docs/design/tracker-launch.md
"$ssh" put "$out/trackeropen" "$root/tools/pi-tests/ta1-sweep.sh" /boot/home/
"$ssh" "rm -rf /boot/home/ta1; nohup sh /boot/home/ta1-sweep.sh 90 10 > /boot/home/tracker-out.txt 2>&1 < /dev/null &"
poll /boot/home/tracker-out.txt "$out/tracker.txt" TA1
"$ssh" get /boot/home/ta1 "$out/tracker-shots" > /dev/null || true
total=$(grep -c '^TA1 [0-9]' "$out/tracker.txt" || true)
good=$(grep '^TA1 [0-9]' "$out/tracker.txt" | grep 'window after' | grep -c 'running, window shown' || true)
# the sweep lists the Test Apps entries as smoke-pi.sh does: as many as the shell pass started
apps=$(grep -c '^TA1 [0-9]* Test Apps/' "$out/tracker.txt" || true)
shell=$(sed -n 's/^SMOKE end //p' "$out/smoke.txt")
echo "TRACKER result: $good of $total entries showed a window and kept it ($apps Test Apps entries, the shell pass $shell)" \
	| tee -a "$out/tracker.txt"
[ "$total" -gt 0 ] && [ "$good" = "$total" ] && [ "$apps" = "$shell" ] || exit 3

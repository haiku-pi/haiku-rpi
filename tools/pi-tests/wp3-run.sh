#!/bin/bash
# wp3-run.sh LABEL MODE CLIP [ENV...] — run tools/pi-tests/wp3-seek.sh (in /boot/home/wp1, the kit of wp1-run.sh setup,
# plus `wp3-run.sh setup`) on the session Pi; an HDMI frame LABEL-NAME.png the moment the script prints "SNAP NAME".
# Output in artifacts/wp3/runs/LABEL.out.
#   tools/pi-tests/wp3-run.sh setup          copies wp3-seek.sh, the seek probe (artifacts/wp3/bin/seekprobe), the
#                                            clips of artifacts/wp3/clips and, if WP3_LIB is set, that library as
#                                            /boot/home/wp1/wp3lib/libWebKitLegacy.so.1
#   tools/pi-tests/wp3-run.sh P1 paused play-720p30.mp4 LIB=/boot/home/wp1/wp3lib
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
out=$R/artifacts/wp3/runs
D=/boot/home/wp1
mkdir -p "$out"
ssh_() { "$R/scripts/pi-ssh.sh" "$@"; }
if [ "${1:-}" = setup ]; then
	ssh_ "mkdir -p $D/wp3lib"
	ssh_ put "$R/tools/pi-tests/wp3-seek.sh" "$R/artifacts/wp3/bin/seekprobe" "$R"/artifacts/wp3/clips/*.mp4 "$D/"
	[ -n "${WP3_LIB:-}" ] && ssh_ put "$WP3_LIB" "$D/wp3lib/libWebKitLegacy.so.1"
	ssh_ "cd $D && chmod +x seekprobe && ls -l wp3-seek.sh seekprobe *.mp4 wp3lib"
	exit 0
fi
label=$1 mode=$2 clip=$3; shift 3
ssh_ "cd $D && env $* sh wp3-seek.sh $mode '$clip' $label" 2>&1 | while IFS= read -r line; do
	echo "$line"
	case "$line" in
	*" SNAP "*) name=${line##* SNAP }
		"$R/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null 2>&1 && echo "snap $label-$name.png" ;;
	esac
done | tee "$out/$label.out"

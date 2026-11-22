#!/bin/bash
# wp2-run.sh LABEL MODE ARG [ENV...] — run tools/pi-tests/wp2-browse.sh (in /boot/home/wp1, the kit of wp1-run.sh setup) on the
# session Pi; an HDMI frame LABEL-NAME.png the moment the script prints "SNAP NAME". Output in artifacts/wp2/runs/LABEL.out.
#   tools/pi-tests/wp2-run.sh S1 site https://en.wikipedia.org/wiki/Haiku_(operating_system)
#   tools/pi-tests/wp2-run.sh T1 type 'Hello Haiku 2026'
#   tools/pi-tests/wp2-run.sh S2 site https://example.com/ LIB=/boot/home/wp1/wp3lib   (ENV: for wp2-browse.sh)
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
out=$R/artifacts/wp2/runs
mkdir -p "$out"
label=$1 mode=$2 arg=$3; shift 3
"$R/scripts/pi-ssh.sh" "cd /boot/home/wp1 && env $* sh wp2-browse.sh $mode '$arg' $label" 2>&1 | while IFS= read -r line; do
	echo "$line"
	case "$line" in
	*" SNAP "*) name=${line##* SNAP }
		"$R/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null 2>&1 && echo "snap $label-$name.png" ;;
	esac
done | tee "$out/$label.out"

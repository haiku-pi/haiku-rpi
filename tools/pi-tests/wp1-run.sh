#!/bin/bash
# wp1-run.sh LABEL MODE CLIP [@SECS:NAME...] [ENV...] — run tools/pi-tests/wp1-video.sh on the session Pi (ssh in the
# foreground, nothing polled meanwhile), HDMI frames from the host at SECS after the start as LABEL-NAME.png, and a
# key census of them (tools/pi-tests/key-census.py); output in artifacts/wp1/runs/LABEL.out.
#   tools/pi-tests/wp1-run.sh setup        copies the kit to /boot/home/wp1 first: wp1-video.sh, teamstat, uiinject,
#                                          the clips, artifacts/wp1/t1/libWebKitLegacy.so.1.10.0 (as lib/libWebKitLegacy.so.1)
#                                          and artifacts/wp1/control/'s (as control/libWebKitLegacy.so.1)
#   tools/pi-tests/wp1-run.sh M720 measure play-720p30.mp4 @22:play LIB=/boot/home/wp1/lib
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
out=$R/artifacts/wp1/runs
D=/boot/home/wp1
mkdir -p "$out"
ssh_() { "$R/scripts/pi-ssh.sh" "$@"; }
if [ "${1:-}" = setup ]; then
	k=$R/artifacts/wp1/kit
	rm -rf "$k"
	mkdir -p "$k/lib" "$k/control"
	cp "$R/tools/pi-tests/wp1-video.sh" "$R/artifacts/v1-overlay/teamstat" "$R/artifacts/s1/bin/uiinject" \
		"$R"/artifacts/media-tests/h264/play-{720p30,1080p30,1080p60}.mp4 \
		"$R"/artifacts/v1-overlay/clips/play-{hevc-720p30,hevc-1080p30,854x480}.mp4 \
		"$R"/artifacts/wp1/clips/play-hevc-*-fs.mp4 "$k/"
	cp "${WP1_LIB:-$R/artifacts/wp1/t1/libWebKitLegacy.so.1.10.0}" "$k/lib/libWebKitLegacy.so.1"
	cp "$R/artifacts/wp1/control/libWebKitLegacy.so.1.10.0" "$k/control/libWebKitLegacy.so.1"
	ssh_ "mkdir -p $D/lib $D/control"
	ssh_ put "$k"/*.sh "$k"/*.mp4 "$k/teamstat" "$k/uiinject" "$D/"
	ssh_ put "$k/lib/libWebKitLegacy.so.1" "$D/lib/"
	ssh_ put "$k/control/libWebKitLegacy.so.1" "$D/control/"
	ssh_ "cd $D && chmod +x teamstat uiinject && ls -l . lib control | head -30"
	exit 0
fi
label=$1 mode=$2 clip=$3; shift 3
snaps=() envs=()
for a in "$@"; do case "$a" in @*) snaps+=("${a#@}") ;; *) envs+=("$a") ;; esac; done
ssh_ "cd $D && env ${envs[*]} sh wp1-video.sh $mode '$clip' $label" > "$out/$label.out" 2>&1 &
pid=$!
t0=$(date +%s)
shots=()
for s in "${snaps[@]}"; do
	at=${s%%:*} name=${s#*:}
	while [ $(( $(date +%s) - t0 )) -lt "$at" ]; do sleep 0.5; done
	if "$R/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null 2>&1; then
		echo "snap $label-$name at $(( $(date +%s) - t0 )) s"
		shots+=("$out/$label-$name.png")
	fi
done
wait $pid
cat "$out/$label.out"
if [ ${#shots[@]} -gt 0 ]; then
	python3 "$R/tools/pi-tests/key-census.py" "${shots[@]}" | tee -a "$out/$label.out"
fi

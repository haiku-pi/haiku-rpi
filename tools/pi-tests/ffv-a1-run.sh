#!/bin/bash
# ffv-a1-run.sh LABEL MODE CLIP [@SECS:NAME...] [ENV...] — run tools/pi-tests/ffv-a1.sh on the session Pi (ssh in the
# foreground, nothing polled meanwhile), HDMI frames from the host at SECS after the start as LABEL-NAME.png;
# output artifacts/ffa1/LABEL.out. The files (tools/pi-tests/ffv-a1.sh, the clips, overlaytest,
# uiinject, extracted packages) go to /boot/home/ffa first. Example (option 0 package extracted to /boot/home/ffa/o0):
#   tools/pi-tests/ffv-a1-run.sh P720a measure play-720p30.mp4 @30:play FFX=/boot/home/ffa/o0/apps/Firefox/Firefox
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
label=$1 mode=$2 clip=$3; shift 3
out=$R/artifacts/ffa1
D=/boot/home/ffa
snaps=() envs=()
for a in "$@"; do case "$a" in @*) snaps+=("${a#@}") ;; *) envs+=("$a") ;; esac; done
"$R/scripts/pi-ssh.sh" "cd $D && env ${envs[*]} sh ffv-a1.sh $mode $clip $label" > "$out/$label.out" 2>&1 &
pid=$!
t0=$(date +%s)
for s in "${snaps[@]}"; do
	at=${s%%:*} name=${s#*:}
	while [ $(( $(date +%s) - t0 )) -lt "$at" ]; do sleep 0.5; done
	"$R/scripts/hdmi-snap.sh" "$out/$label-$name.png" > /dev/null 2>&1 && echo "snap $label-$name at $(( $(date +%s) - t0 )) s"
done
wait $pid
cat "$out/$label.out"

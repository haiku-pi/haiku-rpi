#!/bin/bash
# ffv-colour.sh PREFIX CLIP... — Firefox's overlay colours against its software path (docs/design/firefox-video-overlay.md
# §9.8): each colour bar clip (tools/media-tests/gen-colour-clips.sh, copied to /boot/home/ffa) played twice by
# tools/pi-tests/ffv-a1.sh measure in the session Pi's Firefox, on the plane (default) and in software (OVL=0), an HDMI
# frame of each 24 s after the start; prints the overlay's state (the HVO lines: frames on the plane, the encoding
# Firefox passed, the reasons for software), the display driver's plane lines (image type, encoding) and
# tools/pi-tests/colour-bars.py's comparison (plane against software: "max diff"). Labels PREFIX<n>p / PREFIX<n>s;
# output artifacts/ffa1/. Run with PI_SESSION_LABEL set (scripts/pi-ssh.sh).
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
prefix=${1:?usage: ffv-colour.sh PREFIX CLIP...}
shift
i=0
for clip in "$@"; do
	i=$((i + 1))
	for m in p s; do
		l=$prefix$i$m
		extra=()
		[ $m = s ] && extra=(OVL=0)
		"$R/tools/pi-tests/ffv-a1-run.sh" "$l" measure "$clip" @24:bars WAIT=20 SECS=3 "${extra[@]}" > /dev/null 2>&1
		# the profile is 10+ MB; the session disk is small
		"$R/scripts/pi-ssh.sh" "rm -rf /boot/home/ffa/ffa-profile-$l" > /dev/null 2>&1
		echo "== $l $clip"
		grep -a "No space\|HVO show\|HVO encoding\|log last\|driver plane\|debugger" "$R/artifacts/ffa1/$l.out" \
			| sed "s/^FFA $l //" | cut -c1-230
		ref=()
		[ $m = s ] && ref=("$R/artifacts/ffa1/${prefix}${i}p-bars.png")
		python3 "$R/tools/pi-tests/colour-bars.py" "$R/artifacts/ffa1/$l-bars.png" "${ref[@]}" | tail -n 2
	done
done

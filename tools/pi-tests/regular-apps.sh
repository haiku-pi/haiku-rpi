#!/bin/sh
# regular-apps.sh — a UserBootscript for the regular image (jam -sHAIKU_PI_GL=1 @pi-mmc): opens a few
# of its applications side by side for the HDMI frames (ActivityMonitor, GLTeapot on the V3D, Pulse,
# the Media preferences) and reports what the media server found. Serial console lines: "REG ".
sleep 20
out=/dev/dprintf
say() { echo "REG $*" > $out; }
for app in /boot/system/apps/ActivityMonitor /boot/system/non-packaged/apps/GLTeapot \
		/boot/system/apps/Pulse /boot/system/preferences/Media; do
	if [ -e "$app" ]; then
		"$app" > /dev/null 2>&1 &
		say "started $app"
	else
		say "missing $app"
	fi
	sleep 4
done
sleep 20
say "teams: $(ps | awk 'NR > 1 {print $1}' | sed 's|.*/||' | sort | tr '\n' ' ')"
say end

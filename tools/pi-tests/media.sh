#!/bin/sh
# media.sh — a UserBootscript for media playback (the ffmpeg6 package, the media kit's ffmpeg plugin,
# the PWM audio driver): `decode` decodes a system sound (Ogg Vorbis) through the codec plugins, then
# MediaPlayer plays it (window on HDMI, samples to the headphone jack: the driver's "measured" line).
# Serial console lines: "MED ", "DEC ".
sleep 25
out=/dev/dprintf
say() { echo "MED $*" > $out; }
sound="$(ls /boot/system/data/sounds/*/*.ogg 2>/dev/null | head -n 1)"
say "sound: $sound"
/boot/system/non-packaged/bin/decode "$sound" > $out 2>&1
say "decode exit $?"
/boot/system/apps/MediaPlayer "$sound" > /dev/null 2>&1 &
player=$!
sleep 15
kill $player
grep -a -i -E 'ffmpeg|plugin|decoder|MediaPlayer' /var/log/syslog | tail -n 15 \
	| while read -r line; do say "syslog: $line"; done
say end

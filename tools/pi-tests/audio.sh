#!/bin/sh
# audio.sh — a UserBootscript for the BCM2711 PWM audio driver (drivers/audio/bcm2711_pwm, the 3.5 mm
# jack): is the hmulti device there, did media_server take it, does the DMA stream at the expected
# rate? The driver logs its own measurements (syslog → serial: "bcm2711_pwm: ..."). Then plays a few
# seconds of a system sound if a player exists. Serial console lines: "AUD ".
sleep 25
out=/dev/dprintf
say() { echo "AUD $*" > $out; }
say "devices: $(ls -R /dev/audio 2>&1 | tr '\n' ' ')"
say "teams: $(ps | awk 'NR > 1 {print $1}' | sed 's|.*/||' | grep -i media | tr '\n' ' ')"
sound=$(ls /boot/system/data/sounds/*/* 2>/dev/null | head -n 1)
for player in /boot/system/bin/playsound /boot/system/bin/playfile; do
	if [ -x $player ] && [ -n "$sound" ]; then
		say "playing $sound with $player"
		$player "$sound" > $out 2>&1
		say "player exit $?"
		break
	fi
done
sleep 10
say end

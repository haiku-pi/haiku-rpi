#!/bin/sh
# audio.sh — a UserBootscript for the BCM2711 PWM audio driver (drivers/audio/bcm2711_pwm, the 3.5 mm
# jack): is the hmulti device there, did media_server take it, does the DMA stream at the expected
# rate? The driver logs its own measurements (kernel syslog → serial: "bcm2711_pwm: ..."); `tone` plays
# a sine through the media kit. Serial console lines: "AUD ", "TONE ".
sleep 25
out=/dev/dprintf
say() { echo "AUD $*" > $out; }
say "devices: $(ls -R /dev/audio 2>&1 | tr '\n' ' ')"
say "teams: $(ps | awk 'NR > 1 {print $1}' | sed 's|.*/||' | grep -i media | tr '\n' ' ')"
# a sine through the media kit: mixer -> default output -> the driver (tools/media-tests/tone.cpp)
/boot/system/non-packaged/bin/tone -s 5 > $out 2>&1
say "tone exit $?"
sleep 5
# the media server and its add-ons log to the userland syslog only
grep -a -i -E 'multi|mixer|audio|bcm2711' /var/log/syslog | tail -n 40 | while read -r line; do
	say "syslog: $line"
done
say end

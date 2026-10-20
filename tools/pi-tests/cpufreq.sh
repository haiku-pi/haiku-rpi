#!/bin/sh
# cpufreq.sh — a UserBootscript for the ARM clock following the load (bcm2835_cpufreq): the measured
# clocks and the temperature (/dev/power/bcm2835_thermal/0) while the desktop idles, while four busy
# loops run, and idle again; and how long a short burst of work takes when it starts from an idle
# (low) clock, against the same work with the clock already up. Serial console lines: "CPF ".
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --bootscript tools/pi-tests/cpufreq.sh --out artifacts/images/haiku-pi4-cpufreq.img
#
# A good run: "idle" samples at the minimum ARM clock (600 MHz), "busy" samples at the maximum
# (1500), "idle again" back at the minimum, with the temperature lower when idle; "burst from idle"
# within a few percent of "burst at speed".
sleep 30
out=/dev/dprintf
say() { echo "CPF $*" > $out; }
sample() {
	sed -n 's/^ *Current Temperature: */temp /p; s/^ *Clocks: *//p' /dev/power/bcm2835_thermal/0 2> /dev/null \
		| tr '\n' ' '
}
grep -a "bcm2835_cpufreq" /var/log/syslog | tail -n 2 | while read -r l; do say "syslog: $l"; done

for i in 1 2 3 4 5 6; do sleep 10; say "idle ${i}0 s: $(sample)"; done
# the same from one sleeping process (starting sed above is itself a burst the clock follows)
python3.14 - << 'PY'
import re, time
out = open('/dev/dprintf', 'w')
for i in range(6):
    time.sleep(10)
    text = open('/dev/power/bcm2835_thermal/0').read()
    temp = re.search(r'Current Temperature: (\S+)', text).group(1)
    clocks = re.search(r'Clocks: (.*)', text).group(1)
    t = time.perf_counter(); n = 0
    while time.perf_counter() - t < 0.01:
        n += 1
    out.write(f'CPF quiet {(i + 1) * 10} s: temp {temp} C {clocks}; 10 ms loop {n}\n'); out.flush()
PY

burst() {
	python3.14 -c 'import time; t = time.perf_counter(); sum(range(5 * 10**6)); print("%.3f" % (time.perf_counter() - t))'
}
say "burst from idle: $(burst) s"

pids=""
for i in 1 2 3 4; do
	sh -c 'while :; do :; done' &
	pids="$pids $!"
done
for i in 1 2 3; do sleep 10; say "busy ${i}0 s: $(sample)"; done
say "burst at speed (4 loops running): $(burst) s"
kill $pids
sleep 1
say "burst right after the load: $(burst) s"
say "10 ms loop at speed (after 0.5 s of spinning): $(python3.14 -c '
import time
t = time.perf_counter()
while time.perf_counter() - t < 0.5: pass
t = time.perf_counter(); n = 0
while time.perf_counter() - t < 0.01: n += 1
print(n)')"

for i in 1 2 3 4 5 6; do sleep 10; say "idle again ${i}0 s: $(sample)"; done
say end

#!/bin/sh
# armdbg.sh — a UserBootscript for user debugging on arm64 (breakpoints, single steps, watchpoints):
# tools/haiku-tests/armdbg.c through the debug nub API (each case PASS/FAIL), the same program
# without a debugger (a brk raises SIGILL, as before user debugging), then Haiku's Debugger in its
# command line interface on tools/haiku-tests/dbgtarget.c — stopped at main(), `next` over 3
# instructions and a call (the CLI has no source loaded: it steps instructions), a breakpoint on
# add3() (hit from twice()), `step` twice, `finish` back into twice(), the breakpoint hit again,
# the program's own output — its output; then Terminal, WebPositive and Firefox (if there) start to
# their window (launchtime). scripts/armdbg-image.sh puts it and the programs on an image. Serial
# lines "ARMDBG ...", the last "ARMDBG end".
sleep 20
out=/dev/dprintf
say() { echo "ARMDBG $*" > $out; }
cd /boot/home || { say "no /boot/home"; say end; exit 1; }

say "$(uname -a)"
say "kernel: $(grep -a 'hardware breakpoints' /var/log/syslog | tail -n 1 | sed 's/.*arm64: //')"

for round in 1 2 3; do
	./armdbg > /tmp/armdbg.txt 2>&1
	rc=$?
	sed "s/^/ARMDBG nub$round: /" /tmp/armdbg.txt > $out
	say "nub$round: rc $rc"
done

./armdbg nodebug > /tmp/armdbg.txt 2>&1
rc=$?
sed "s/^/ARMDBG /" /tmp/armdbg.txt > $out
say "nodebug: rc $rc"

# Debugger's command line interface, fed with pauses (its commands do not wait for the thread)
if [ -x ./dbgtarget ]; then
	rm -rf /boot/home/config/settings/Debugger	# no breakpoints from an earlier run
	(
		sleep 15; echo "bt"
		for i in 1 2 3 4; do sleep 3; echo "next"; done
		sleep 4; echo "bt"
		sleep 3; echo "break add3"
		sleep 2; echo "continue"
		sleep 5; echo "bt"
		sleep 3; echo "step"
		sleep 3; echo "step"
		sleep 3; echo "finish"
		sleep 5; echo "bt"
		sleep 3; echo "continue"
		sleep 5; echo "continue"
		sleep 5; echo "quit"
	) | /boot/system/apps/Debugger --cli ./dbgtarget > /tmp/armdbg-cli.txt 2>&1 &
	cli=$!
	sleep 100
	kill $cli 2>/dev/null
	tr -d '\r' < /tmp/armdbg-cli.txt | sed "s/^/ARMDBG cli: /" > $out
	say "cli: $(wc -l < /tmp/armdbg-cli.txt) lines"
else
	say "cli: no ./dbgtarget"
fi

# no regression: applications start and show their window (Firefox, if the image has it)
for app in /boot/system/apps/Terminal /boot/system/apps/WebPositive /boot/system/apps/Firefox/Firefox; do
	[ -e "$app" ] || continue
	say "$(./launchtime -q "$app" 120 2>&1 < /dev/null | tr '\n' ' ')"
done

say "debugger entries in the syslog: $(grep -ac 'debug_server' /var/log/syslog)"
say end

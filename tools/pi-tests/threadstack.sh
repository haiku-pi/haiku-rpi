#!/bin/sh
# threadstack.sh — a UserBootscript for thread creation cost and correctness (tools/haiku-tests/threadbench.c,
# threadstress.c, forkbench.c in /boot/home; scripts/image-add.sh puts them and this script on a copy of an
# image): threadbench three times, forkbench, threadstress, then Terminal, StyledEdit, ShowImage, DeskCalc and
# Devices launched to their first window (launchtime, if there). /boot/home/threadstack-rounds may hold
# threadstress's thread count (default 3000; QEMU: fewer); with /boot/home/threadstack-benchonly only the
# benchmarks run; /boot/home/threadstack-only may name the one threadstress test to run (then no benchmarks). Serial lines "THREADSTACK ...", the last "THREADSTACK end".
sleep 20
out=/dev/dprintf
say() { echo "THREADSTACK $*" > $out; }
cd /boot/home || exit 1
rounds=3000
[ -r threadstack-rounds ] && rounds=$(cat threadstack-rounds)
only=
[ -r threadstack-only ] && only=$(cat threadstack-only)

if [ -z "$only" ]; then
	for round in 1 2 3; do
		./threadbench 2000 64 2>&1 | while read -r line; do say "round $round $line"; done
	done
	./forkbench 200 2>&1 | while read -r line; do say "$line"; done
fi
if [ -e threadstack-benchonly ]; then
	say end
	exit 0
fi

# a crashing threadstress child must not wait for the debug server's alert
ds=/boot/home/config/settings/system/debug_server/settings
if [ ! -e $ds ]; then
	mkdir -p $(dirname $ds)
	printf 'executable_actions {\n\tthreadstress log\n}\n' > $ds
fi
./threadstress "$rounds" $only 2>&1 | while read -r line; do say "$line"; done

if [ -x ./launchtime ]; then
	for app in /boot/system/apps/Terminal /boot/system/apps/StyledEdit /boot/system/apps/ShowImage \
			/boot/system/apps/DeskCalc /boot/system/apps/Devices; do
		./launchtime -q "$app" 120 < /dev/null 2>&1 | while read -r line; do say "$line"; done
		sleep 2
	done
fi
say end

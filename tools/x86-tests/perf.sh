#!/bin/sh
# perf.sh — H22 timing (docs/design/x86-64-check.md §4.6), run by scripts/x86-perf.sh. Boot 1 (the first boot:
# package activation work) prints the kernel's system_time() when Tracker and Deskbar run and restarts; boot 2
# prints it again, waits 10 s, then: each application launched twice (cold, then warm: launchtime -q), forkbench,
# threadbench, tlsbench, dlopentime of libbe, libtracker and a translator; then powers off.
# Serial lines "X86T perf ...".
G=perf
X86T_LINES=60
. /boot/home/x86t/lib.sh
state=/boot/home/perf.state
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
say "info boot$n $($X86T_DIR/systime)"
if [ $n = 1 ]; then
	sleep 2
	shutdown -r
	exit 0
fi
sleep 10
cd $X86T_DIR || { finish; exit 1; }
for app in Terminal StyledEdit ShowImage DeskCalc Devices MediaPlayer WebPositive; do
	for round in cold warm; do
		./launchtime -q /boot/system/apps/$app 120 < /dev/null > /tmp/lt.txt 2>&1
		say "info launch $app $round $(grep -a -o 'window after [0-9]* ms' /tmp/lt.txt)"
		sleep 1
	done
done
t forkbench 300 - ./forkbench 200
t threadbench 300 - ./threadbench 2000 64
cd $X86T_DIR/tls
export LIBRARY_PATH="%A:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
t tlsbench 300 - ./tlsbench 20 ./libtlsbench2.so
cd $X86T_DIR
for lib in /boot/system/lib/libbe.so /boot/system/lib/libtracker.so \
		/boot/system/add-ons/Translators/PNGTranslator; do
	t dlopentime-${lib##*/} 120 - ./dlopentime $lib 20
done
finish

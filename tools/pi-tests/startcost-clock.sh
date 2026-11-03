#!/bin/sh
# startcost-clock.sh LABEL [CMD...] — over ssh (scripts/pi-session.sh): forkbench (tools/haiku-tests/forkbench.c in
# /boot/home) with the ARM clock sampled every 0.25 s from /dev/power/bcm2835_thermal/0 while it runs; CMD first
# (e.g. `true`). H20 C0b: a program start costs 4.7 ms at 1500 MHz and 6.6-8.0 ms when the clock governor leaves the
# ARM at 750-1200 MHz. To hold the clock at the maximum for an A/B: sh -c 'while :; do :; done' & in the same shell.
# Lines "C LABEL FORKBENCH <case> <us> us/op" and "C LABEL clocks: <count> <Clocks line>...".
cd /boot/home || exit 1
l=$1; shift
rm -f /tmp/clk-stop
( while [ ! -f /tmp/clk-stop ]; do grep -a Clocks /dev/power/bcm2835_thermal/0; sleep 0.25; done ) > /tmp/clk-$l.txt &
s=$!
"$@"
# (stdout is a pipe: Haiku's _exit() flushes stdio (libroot _exit.c, _IO_cleanup()), so each fork+exit child
# prints forkbench's buffered first line again, hence the grep)
./forkbench 200 | grep -v thread | sed "s/^/C $l /"
touch /tmp/clk-stop; wait $s; rm -f /tmp/clk-stop
echo "C $l clocks: $(sort /tmp/clk-$l.txt | uniq -c | tr -s ' \n' ' ')"

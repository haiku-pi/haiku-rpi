#!/bin/sh
# dwarf5.sh — a UserBootscript for the Debugger's DWARF 5 support (design/debugger-dwarf5.md): Haiku's
# Debugger, command line interface, on tools/haiku-tests/dbgtarget.c (-O0) and dbgtarget-cxx.cpp (-O2,
# a std::thread: libstdc++ frames) each built with -gdwarf-4 and with -gdwarf-5. Each session stops in a
# function (add3() called from twice(); dbg::leaf() in the thread), prints the stack trace, the
# variables of two frames, and saves a debug report (frames with source file:line and variables).
# The Debugger under test is /boot/home/dwarf5/Debugger with lib/libdebugger.so next to it (the
# runtime loader looks in the application's lib/ first); two last sessions run the system's Debugger
# on the -gdwarf-5 C program and the -gdwarf-4 C++ program for comparison. The programs' sources are
# in src/ (where their debug information says). scripts/dwarf5-image.sh puts all on an image.
# Serial lines "DWARF5 <session> cli: ..." and "DWARF5 <session> report: ...", the last "DWARF5 end".
sleep 20
out=/dev/dprintf
say() { echo "DWARF5 $*" > $out; }
dir=/boot/home/dwarf5
cd $dir || { say "no $dir"; say end; exit 1; }
say "$(uname -a)"

# wait_for FILE PATTERN COUNT SECONDS: until FILE has COUNT lines matching PATTERN
wait_for() {
	n=0
	while [ $n -lt $4 ]; do
		[ "$(grep -c "$2" "$1" 2> /dev/null)" -ge "$3" ] && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

# session LABEL DEBUGGER PROGRAM FUNCTION CONTINUES "VARIABLES" "FRAME 1 VARIABLES"
session() {
	label=$1 debugger=$2 program=$3 function=$4 continues=$5 vars=$6 vars1=$7
	log=/tmp/dwarf5-$label.txt
	report=/tmp/dwarf5-$label.report
	rm -rf /boot/home/config/settings/Debugger "$log" "$report"
	(
		wait_for $log "thread stopped" 1 120
		# the image's debug information may still be loading: try again
		i=0
		while [ $i -lt 60 ]; do
			echo "break $function"
			sleep 2
			grep -q "^Breakpoint at" $log && break
			i=$((i + 1))
		done
		stops=1
		while [ $continues -gt 0 ]; do
			echo continue
			stops=$((stops + 1))
			wait_for $log "thread stopped" $stops 120
			continues=$((continues - 1))
		done
		# the thread that stopped last (the C++ program's is not the main thread)
		echo "thread $(grep 'thread stopped' $log | tail -n 1 | sed 's/.*stopped: \([0-9]*\).*/\1/')"
		sleep 2
		echo bt
		sleep 10
		echo variables
		sleep 3
		for v in $vars; do echo "print $v"; sleep 3; done
		echo "frame 1"
		sleep 2
		echo variables
		sleep 3
		for v in $vars1; do echo "print $v"; sleep 3; done
		echo "save-report $report"
		wait_for $log "saved debug report\|Failed to write" 1 180
		echo quit
		sleep 1
		echo k
		sleep 5
	) | $debugger --cli ./$program > $log 2>&1 &
	pid=$!
	n=0
	while kill -0 $pid 2> /dev/null && [ $n -lt 240 ]; do sleep 1; n=$((n + 1)); done
	kill $pid 2> /dev/null
	tr -d '\r' < $log | sed "s/^/DWARF5 $label cli: /" > $out
	if [ -f $report ]; then
		sed "s/^/DWARF5 $label report: /" $report > $out
	else
		say "$label: no report"
	fi
	[ $n -ge 240 ] && say "$label: did not end, killed"
	say "$label: $n s"
}

for v in 4 5; do
	session c-dw$v $dir/Debugger c-dw$v add3 2 "value result" "value first"
	session cxx-dw$v $dir/Debugger cxx-dw$v dbg::leaf 1 "value label scaled" \
		"values accumulator label"
done
session old-c-dw5 /boot/system/apps/Debugger c-dw5 add3 2 "value result" "value first"
session old-cxx-dw4 /boot/system/apps/Debugger cxx-dw4 dbg::leaf 1 "value label scaled" \
	"values accumulator label"

say "debugger entries in the syslog: $(grep -ac 'debug_server' /var/log/syslog)"
say end

#!/bin/sh
# shutdown-respawn.sh — UserBootscript: does the system launch_daemon start its services again while a shutdown is
# in progress (design/tracker-shutdown-crash.md, "launch_daemon restart loop")?
#   scripts/qemu-x86.sh --desktop --bootscript tools/x86-tests/shutdown-respawn.sh \
#       [--add teamcrash:/boot/home/teamcrash] [--add MODEFILE:/boot/home/shutdown-respawn.mode] \
#       --until 'RESP done' --secs 150
# MODEFILE holds the mode:
#   loop (default): net_server, mount_server, syslog_daemon and power_daemon are stopped (SIGSTOP), then
#     `shutdown -r`. In the system-app phase the registrar asks package_daemon to quit and then waits 3 s for each
#     stopped server (kAppQuitTimeout); unfixed, the launch_daemon starts package_daemon again all that time, and
#     each start is refused: "package_daemon: ... failed to init server application: System shutting down"
#     lines. The second boot prints "RESP done". Fixed: no such line.
#   guard: needs teamcrash (tools/haiku-tests/teamcrash.c, cross-built). A program crashes 1 s into the shutdown,
#     so debug_server's alert holds it; 10 s later package_daemon is killed and its teams are listed for 10 s.
#     Unfixed: a new package_daemon team appears. Fixed: none. Ends at "RESP done" in the same boot.
# Serial lines "RESP ".
say() { echo "RESP $*" > /dev/dprintf; }
mode=$(cat /boot/home/shutdown-respawn.mode 2> /dev/null || echo loop)
state=/boot/home/shutdown-respawn.boot
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
say "mode $mode, boot $n"
if [ $n -gt 1 ]; then
	say "done"
	exit 0
fi
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
sleep 5

if [ "$mode" = loop ]; then
	for server in net_server mount_server syslog_daemon power_daemon; do
		team=$(ps | grep -v grep | grep servers/$server | awk '{print $2}')
		say "stopping $server $team"
		kill -STOP $team
	done
	shutdown -r
	say "shutdown returned $?"
	exit 0
fi

sleep 1 &
/boot/home/teamcrash $! > /dev/null 2>&1 < /dev/null &
# The registrar may kill this script's team while it quits the user applications; the watch runs in its own.
(
	sleep 10
	pd=$(ps | grep -v grep | grep servers/package_daemon | awk '{print $2}')
	if [ -n "$pd" ]; then
		say "killing package_daemon $pd"
		kill -9 $pd
	fi
	i=1
	while [ $i -le 10 ]; do
		sleep 1
		say "t=$i package_daemon teams: $(ps | grep -v grep | grep servers/package_daemon | awk '{print $2}' | tr '\n' ' ')"
		i=$((i + 1))
	done
	say "done"
) > /dev/null 2>&1 < /dev/null &
shutdown -r
say "shutdown returned $?"

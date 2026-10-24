#!/bin/sh
# diag-boot.sh — a UserBootscript for a boot that has no ssh (scripts/netboot-cycle.sh --bootscript): runs a
# list of commands, each under a time limit, and reports exit codes and output on the serial console ("PID "
# lines), then the process list. For finding which program fails or hangs on a candidate image.
out=/dev/dprintf
say() { echo "PID $*" > $out; }
run() {
	timeout 30 "$@" > /tmp/diag.txt 2>&1
	say "[$?] $*"
	head -n 4 /tmp/diag.txt | while read -r line; do say "    $line"; done
}
sleep 5
say "start"
run /bin/true
run /bin/sh -c true
run ls /boot/home
run pkgman list-repos
run pkgman install -y /boot/home/openssh.hpkg
run listimage 1
say "processes:"
ps | while read -r line; do say "  $line"; done
say "done"

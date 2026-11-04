#!/bin/sh
# smoke.sh — the H22 smoke boot's UserBootscript (scripts/qemu-x86.sh --bootscript): waits for Tracker,
# prints what booted to the serial line ("SMOKE " lines, via /dev/dprintf), then "SMOKE desktop up";
# scripts/qemu-x86.sh --until 'SMOKE desktop up' takes the screenshot and ends the run.
out=/dev/dprintf
say() { echo "SMOKE $*" > $out; }
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
say "uname $(uname -a)"
say "cpus $(sysinfo -cpu 2> /dev/null | grep -a -c '^CPU #')"
say "boot $(df -h /boot 2> /dev/null | tail -n 1)"
say "teams $(ps 2> /dev/null | wc -l)"
sleep 10
say "desktop up"

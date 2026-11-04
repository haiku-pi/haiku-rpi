#!/bin/sh
# boot.sh — H22 test group BOOT (docs/design/x86-64-check.md §4.3): the desktop came up (Tracker and Deskbar),
# the CPU count, no 10 s wait for the boot device, the disks and network interfaces found, the kernel modules
# loaded (to compare two images' driver sets), then power-off (ACPI). Serial lines "X86T boot ...".
G=boot
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
say "result desktop PASS rc=0 Tracker and Deskbar running"
say "info $(uname -a)"
say "info cpus $(sysinfo -cpu 2> /dev/null | grep -a -c '^CPU #') teams $(ps 2> /dev/null | grep -a -c -E '^/|^[a-z_]+ ')"
say "info boot volume $(df /boot | awk '$1 == "Device:" { print $2 }')"
say "info memory $(sysinfo -mem 2> /dev/null | grep -a -i -m 1 'max' | tr -s ' ')"
say "info disks $(find /dev/disk -name raw 2> /dev/null | sort | tr '\n' ' ')"
say "info nets $(ls /dev/net/*/ 2> /dev/null | tr '\n' ' ') $(ls -d /dev/net/* | tr '\n' ' ')"
say "info modules $(listimage 1 2> /dev/null | awk '{print $NF}' | grep -a / | sed 's|.*/||' | sort | tr '\n' ' ')"
say "info devices $(listdev 2> /dev/null | grep -a -c 'device ')"
if grep -a -q 'waiting for the boot device' /var/log/syslog 2> /dev/null; then
	say "result bootwait FAIL rc=1 the kernel waited for the boot device"
else
	say "result bootwait PASS rc=0 no wait for the boot device"
fi
say "info syslog errors $(grep -a -i -c -E 'error|fail' /var/log/syslog 2> /dev/null)"
grep -a -i -E 'error|fail' /var/log/syslog 2> /dev/null | head -n 20 | while IFS= read -r l; do say "out syslog: $l"; done
sleep 3
finish

#!/bin/sh
# nodns.sh — H22 NET without a name server (scripts/x86-test.sh nodns IMAGE --nic none): the host's own name and
# localhost must resolve at once from the hosts file; before haiku 25c9881600/58022c954a (ICMPv6 errors, the
# own name from the hosts file) the resolver's query to [::]:53 waited ~14 s for its time-outs. PASS: each lookup
# under 2 s. Serial lines "X86T nodns ...".
G=nodns
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
say "info resolv.conf: $(tr '\n' ' ' < /etc/resolv.conf 2> /dev/null)"
for name in "$(hostname)" localhost; do
	timeout 120 ./resolvetime "$name" > /tmp/rt.txt 2>&1
	rc=$?
	say "out resolve: $(cat /tmp/rt.txt)"
	slow=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "ms," || $i == "ms") if ($(i - 1) + 0 > 2000) print $(i - 1) }' /tmp/rt.txt)
	if [ $rc = 0 ] && grep -q 'gethostbyname ok' /tmp/rt.txt && [ -z "$slow" ]; then
		say "result resolve-$name PASS rc=$rc"
	else
		say "result resolve-$name FAIL rc=$rc slow: ${slow:-none}"
	fi
done
finish

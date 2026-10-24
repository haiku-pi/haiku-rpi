#!/bin/sh
# ffdns.sh — a UserBootscript showing what Firefox waits for in its 2-s and 5-s select() time-outs on a
# card boot without a network: Firefox under strace (all threads, to a file), quit after 30 s; for the
# first four such selects, the 30 syscalls of the same thread before it. Serial lines "FDN ...".
out=/dev/dprintf
say() { echo "FDN $*" > $out; }
ff=/boot/system/apps/Firefox
sleep 25
find $ff -type f -exec cat {} + > /dev/null
say "resolv.conf: $(cat /boot/system/settings/network/resolv.conf 2>&1 | tr '\n' '|')"
strace -T -s -t --no-color -o /tmp/ff.strace $ff/Firefox > /dev/null 2>&1 < /dev/null &
sleep 30
hey Firefox quit > /dev/null 2>&1
sleep 8
for t in $(ps | grep -a '[a]pps/Firefox/Firefox' | awk '{print $(NF-3)}'); do kill -9 $t; done
grep -a -n -E 'select\(.*0x1e8480|select\(.*0x4c4b40' /tmp/ff.strace | head -4 | while IFS=: read n rest; do
	thread=$(echo "$rest" | grep -o '^\[ *[0-9]*\]')
	say "=== line $n $thread"
	head -n $n /tmp/ff.strace | grep -a -F "$thread" | tail -30 | cut -c1-260 | while read line; do say "$line"; done
done
say done

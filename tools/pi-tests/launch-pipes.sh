#!/bin/sh
# launch-pipes.sh — UserBootscript: which running teams hold pipe descriptors (design/renkuos-fixes.md, the
# launch_daemon environment pipe). launch_daemon reads a job's environment from a shell through a pipe; a program
# it starts meanwhile from another thread inherits that pipe unless it is close-on-exec. Lists, for every team, the
# descriptors on the device of a pipe of this script's own (dev:inode; /dev/null and /dev/dprintf printed to tell them apart).
# Serial lines "LPIPE ...", the last "LPIPE end <n> descriptors in <m> teams".
out=/dev/dprintf
say() { echo "LPIPE $*" > $out; }
sleep 25
# the pipe file system's device: stdout of the "sleep 30" below is a pipe
pipe=$(sleep 30 | fdinfo sleep 2> /dev/null | awk '$1 == "1" { print $3; exit }')
dev=${pipe%%:*}
# /dev/null, the servers' standard descriptors, to tell apart from pipes on the same device
null=$(stat -L -c '%d:%i' /dev/null 2> /dev/null)
dprintf=$(stat -L -c '%d:%i' /dev/dprintf 2> /dev/null)
say "a pipe: ${pipe:-?}; /dev/null $null, /dev/dprintf $dprintf"
[ -n "$dev" ] || { say "end ? descriptors in ? teams"; exit 0; }
fdinfo 2> /dev/null | awk -v dev="$dev" -v self="$$" '
	/^Team: / { team = $0; next }
	{ split($3, a, ":"); if (a[1] == dev) print team " fd " $1 " " $2 " " $3 }' \
	| grep -v -E 'fdinfo|awk|sleep|launch-pipes|UserBootscript|grep' > /tmp/lpipes.txt
n=$(wc -l < /tmp/lpipes.txt)
teams=$(sed 's/ fd .*//' /tmp/lpipes.txt | sort -u | wc -l)
while read -r line; do say "$line"; done < /tmp/lpipes.txt
say "end $n descriptors in $teams teams"

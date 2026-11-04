#!/bin/sh
# pmexit-loop.sh — UserBootscript (design/tracker-shutdown-crash.md): run /boot/home/pmexit (tools/haiku-tests/pmexit.cpp)
# /boot/home/pmx.count times (default 500) while another process creates and removes the
# ancestors of the path it watches. A fault leaves no exit status (the team was exiting anyway) and usually no
# debug_server entry ("Failed to install debugger: ... invalid team"): count it with a kernel that logs user
# faults (the C15DIAG diff of that document). Serial lines "PMX ".
out=/dev/dprintf
say() { echo "PMX $*" > $out; }
mkdir -p /boot/home/config/settings/system/debug_server
echo 'default_action kill' > /boot/home/config/settings/system/debug_server/settings
chmod +x /boot/home/pmexit
n=$(cat /boot/home/pmx.count 2> /dev/null || echo 500)
sleep 10
say "start n=$n"
( while :; do mkdir -p /boot/home/pmx/a/b; touch /boot/home/pmx/a/b/settings_file; rm -rf /boot/home/pmx/a; done ) &
churn=$!
i=1 bad=0
while [ $i -le $n ]; do
	/boot/home/pmexit $(( (i % 10) * 5000 + 1000 ))
	rc=$?
	if [ $rc != 0 ]; then bad=$((bad + 1)); say "run $i exit $rc"; fi
	[ $((i % 50)) = 0 ] && say "progress $i bad $bad"
	i=$((i + 1))
done
kill $churn
say "done n=$n bad=$bad"

#!/bin/sh
# gcc-syslibs.sh — a UserBootscript for a rebuilt gcc_syslibs (scripts/build-gcc-syslibs.sh: libstdc++ and
# libgcc_s with GNU hash, libstdc++ with -Bsymbolic-functions). Put on an image with scripts/image-add.sh,
# with tools/haiku-tests/cxxrt.cpp built twice into /boot/home (cxxrt; cxxrt-rootfirst: libroot.so first
# in its DT_NEEDED, so libroot's copy of libsupc++ serves the program's throws and catches):
#   which gcc_syslibs is active and the libraries' hashes, cxxrt (exceptions, exception_ptr, a replaced
#   operator new, threads), the runtime libraries Tracker and Deskbar have loaded, and launches of C++
#   applications to their first window (launchtime, tools/haiku-tests/launchtime.cpp, in /boot/home).
# Serial lines "CXXRT ...", the last "CXXRT end". CXXRT_LAUNCHES (default 3) launches per app.
sleep 25
out=/dev/dprintf
say() { echo "CXXRT $*" > $out; }
cd /boot/home || exit 1
n=${CXXRT_LAUNCHES:-3}

say "package $(ls /boot/system/packages | grep '^gcc_syslibs' | tr '\n' ' ')"
say "sha256 libstdc++ $(sha256sum /boot/system/lib/libstdc++.so.6.0.32 | cut -c1-16)" \
	"libgcc_s $(sha256sum /boot/system/lib/libgcc_s.so.1 | cut -c1-16)"
say "cxxrt: $(./cxxrt 2>&1 | tr '\n' ' ')"
say "cxxrt-rootfirst: $(./cxxrt-rootfirst 2>&1 | tr '\n' ' ')"
for team in Tracker Deskbar; do
	say "$team: $(listimage $team 2>&1 | grep -E 'libstdc|libgcc_s' | awk '{print $NF}' | tr '\n' ' ')"
done

for app in Terminal StyledEdit MediaPlayer ShowImage DeskCalc Debugger; do
	i=1
	while [ $i -le $n ]; do
		./launchtime -q /boot/system/apps/$app 120 > /tmp/cxxrt-lt.txt 2>&1 < /dev/null
		w=$(grep -o 'window after [0-9]*' /tmp/cxxrt-lt.txt | grep -o '[0-9]*$')
		say "launch $app-$i: window ${w:-none} ms"
		sleep 2
		i=$((i + 1))
	done
done
/boot/system/apps/Terminal &
sleep 6
say "Terminal: $(listimage Terminal 2>&1 | grep -E 'libstdc|libgcc_s' | awk '{print $NF}' | tr '\n' ' ')"
say "debugger entries: $(grep -c 'debug_server\|Debugger' /var/log/syslog 2>/dev/null)"
say end

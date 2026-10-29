#!/bin/sh
# x86-cpubench.sh [ROUNDS] — CPU-bound 32-bit x86 code under Wine's x86 emulator (Box64 unless the registry names
# another): tools/wine-tests/cpubench.c as /boot/home/cpubench-x86.exe (ms per part) and 7-Zip's own benchmark
# (`7zr b -mmt1`, one thread, from the mega image's Windows programs: compressing/decompressing MIPS), ROUNDS
# times each (default 3). For A/B runs of an emulator change (e.g. Box64's suspend doorbell checks, W9). Run over
# ssh (scripts/pi-ssh.sh 'sh /boot/home/x86-cpubench.sh 5'); lines "XBENCH ...".
rounds=${1:-3}
export WINEDEBUG=-all
z=/boot/system/non-packaged/data/windows-apps/7z
say() { echo "XBENCH $*"; }
say "begin: $(ls /boot/system/packages | grep '^wine_x86-' | tr '\n' ' ')"
cd /boot/home
wine cmd /c exit > /dev/null 2>&1	# the wineserver and the prefix up before the first timing
i=0
while [ $i -lt "$rounds" ]; do
	i=$((i + 1))
	say "cpubench $i: $(wine cpubench-x86.exe 2>&1 | tr -d '\r' | grep -v 'BOX64' | tr '\n' ' ')"
done
i=0
while [ $i -lt "$rounds" ]; do
	i=$((i + 1))
	say "7zr $i: $(cd $z && wine 7zr.exe b -mmt1 2>&1 | tr -d '\r' | grep -E '^(Avr|Tot):' | tr -s ' ' | tr '\n' ' ')"
done
wineserver -w
say end

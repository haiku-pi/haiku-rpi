#!/bin/sh
# relr.sh — a UserBootscript for packed relative relocations (DT_RELR; scripts/relr-image.sh puts it,
# the test programs and launchtime on a copy of an image): relrtest (correctness: the program's, a
# linked and a dlopen()ed library's pointers), then times — the first of each right after the boot, so
# cold — dlopen() of relrbig.c's half a million pointers with RELA entries and with DT_RELR, dlopen()
# of system libraries (RELA or DT_RELR: whatever the image was built with), and the launches of
# Terminal, GLTeapot and Firefox to their first window (the packaged Firefox; with the image's
# /boot/home/ffx-rela and /boot/home/ffx-relr, the same Firefox with libxul.so linked each way, in
# turn). Serial lines "RELR ...", the last "RELR end". RELR_LAUNCHES (default 5) launches per app.
sleep 25
out=/dev/dprintf
say() { echo "RELR $*" > $out; }
cd /boot/home || exit 1
n=${RELR_LAUNCHES:-5}

say "$(./relrtest /boot/home 2>&1 | tr '\n' ' ')"

dlopen() {	# LABEL LIBRARY ROUNDS: first (cold) and the median of the rest
	./dlopentime "$2" "$3" > /tmp/relr-dl.txt 2>&1
	first=$(head -n 1 /tmp/relr-dl.txt | sed 's/.*dlopen \([0-9.]*\) ms.*/\1/')
	median=$(tail -n +2 /tmp/relr-dl.txt | sed 's/.*dlopen \([0-9.]*\) ms.*/\1/' | sort -n \
		| awk '{v[NR] = $1} END {print v[int((NR + 1) / 2)]}')
	say "dlopen $1: first $first ms, median $median ms ($(($3 - 1)) more)"
}
dlopen big-rela /boot/home/librelrbig-rela.so 21
dlopen big-relr /boot/home/librelrbig-relr.so 21
for lib in libbe.so libtracker.so libmedia.so libnetwork.so libtranslation.so; do
	dlopen $lib /boot/system/lib/$lib 21
done

launch() {	# LABEL APP: window and quit times
	./launchtime -q "$2" 120 > /tmp/relr-lt.txt 2>&1 < /dev/null
	w=$(grep -o 'window after [0-9]*' /tmp/relr-lt.txt | grep -o '[0-9]*$')
	say "launch $1: window ${w:-none} ms"
	sleep 3
}
i=1
while [ $i -le $n ]; do
	launch Terminal-$i /boot/system/apps/Terminal
	launch GLTeapot-$i /boot/system/demos/GLTeapot
	launch Firefox-$i /boot/system/apps/Firefox/Firefox
	for v in rela relr; do
		[ -x /boot/home/ffx-$v/Firefox ] && launch Firefox-$v-$i /boot/home/ffx-$v/Firefox
	done
	i=$((i + 1))
done
say end

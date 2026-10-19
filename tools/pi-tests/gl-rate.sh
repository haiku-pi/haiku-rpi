#!/bin/sh
# gl-rate.sh — a UserBootscript: the frame rate of a GL window (glview, mkimage-pi4.sh --add-bin) at
# several sizes, for each present path: the GPU blit into the imported bitmap and the CPU copy
# (HAIKU_EGL_NO_IMPORT). Serial console lines: "GLR " (markers, clocks), glview's own output.
sleep 20
out=/dev/dprintf
say() { echo "GLR $*" > $out; }
for path in import copy; do
	for size in 400 600 800 1000; do
		say "$path $size"
		if [ $path = copy ]; then
			HAIKU_EGL_NO_IMPORT=1 glview -W $size -s 5 > $out 2>&1
		else
			glview -W $size -s 5 > $out 2>&1
		fi
		say "$path-$size-exit $?"
	done
done
say "$(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0)"
say end

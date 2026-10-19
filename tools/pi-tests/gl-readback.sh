#!/bin/sh
# gl-readback.sh — a UserBootscript for the GPU stage 5 correctness check: the glview frame read back
# from the screen (glview -H) for the three present paths — CPU copy (HAIKU_EGL_NO_IMPORT, the
# reference), GPU blit into the imported bitmap, and softpipe — at 256 and 800 pixels. Serial console
# lines: "GLT " (markers), "GLW " (glview: "screen ... N pixels differ, largest difference D").
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
for size in 256 800; do
	ref=/tmp/glview-$size.raw
	rm -f $ref
	say "copy $size (reference)"
	HAIKU_EGL_NO_IMPORT=1 $bin/glview -W $size -s 2 -H $ref > $out 2>&1
	say "copy-$size-exit $?"
	say "import $size"
	$bin/glview -W $size -s 2 -H $ref > $out 2>&1
	say "import-$size-exit $?"
	say "softpipe $size"
	LIBGL_ALWAYS_SOFTWARE=1 $bin/glview -W $size -s 2 -H $ref > $out 2>&1
	say "softpipe-$size-exit $?"
done
say end

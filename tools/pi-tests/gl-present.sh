#!/bin/sh
# gl-present.sh — a UserBootscript for GPU stage 5 (present without copying): glview windows of 256 and
# 800 pixels, each with the frame blitted by the GPU into the window bitmap's own (imported) memory
# and, for comparison, copied by the CPU (HAIKU_EGL_NO_IMPORT). Serial console lines: "GLT " (markers),
# "GLW " (glview: fps, checks).
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
for size in 256 800; do
	say "import $size"
	$bin/glview -W $size -s 5 > $out 2>&1
	say "import-$size-exit $?"
	say "copy $size"
	HAIKU_EGL_NO_IMPORT=1 $bin/glview -W $size -s 5 > $out 2>&1
	say "copy-$size-exit $?"
done
say end

#!/bin/sh
# v3d-recovery.sh — a UserBootscript for test images: the V3D driver's failure paths. A job that
# hangs must be ended by the watchdog and the GPU reset, after which jobs work again; a client
# killed with a job in flight must leak nothing. "V3R " markers + v3dtest's own lines.
sleep 20
out=/dev/dprintf
say() { echo "V3R $*" > $out; }
say begin
for t in clear hang clear areas orphan; do
	say "step $t"
	v3dtest -d $t > /dev/null 2>&1
	say "step $t exit $?"
done
sleep 2
say "step areas-after-orphan"
v3dtest -d areas > /dev/null 2>&1
say "step clear-after-all"
v3dtest -d clear > /dev/null 2>&1
say "step clear-after-all exit $?"
say end

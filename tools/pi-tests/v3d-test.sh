#!/bin/sh
# v3d-test.sh — a UserBootscript for test images: runs the V3D driver tests (v3dtest, from
# src/tests/add-ons/kernel/drivers/v3d) one at a time after the desktop is up, so a hang points
# at its step. Lines on the serial console: "V3T " markers + v3dtest's own (v3dtest -d).
sleep 20
out=/dev/dprintf
say() { echo "V3T $*" > $out; }
say begin
for t in info bo clear wait syncobj; do
	say "step $t"
	v3dtest -d $t > /dev/null 2>&1
	say "step $t exit $?"
done
say "step leak-check"
v3dtest -d areas > /dev/null 2>&1
say end

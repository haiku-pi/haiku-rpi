#!/bin/sh
# vulkan.sh — a UserBootscript for test images with the GL stack and Vulkan (scripts/build-gl-stack.sh,
# added with mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged): after the desktop is up,
# lists the Vulkan devices (vktest -i, with the loader's driver search logged), runs vktest (headless
# render + timestamps + compute + indirect dispatch on V3DV), and gltri once, as the GL regression
# check (the v3d kernel driver's sync files changed GL's fence path too). Serial console lines: "VK "
# (vktest's and the markers here), "GLT " (gltri's); the loader's and Mesa's messages go to the same
# place.
#
#   scripts/mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged \
#       --bootscript tools/pi-tests/vulkan.sh --out artifacts/images/haiku-pi4-vulkan.img
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
icd=/boot/system/non-packaged/add-ons/vulkan/icd.d
say() { echo "VK $*" > $out; }
run() {
	# a hung GPU job must not stall the boot script forever
	if command -v timeout > /dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi
}

say "boot-begin dri: $(ls /dev/dri 2>&1) icd: $(ls $icd 2>&1)"

# (variables go through env: an assignment before a shell function call would stay set afterwards in
# bash's POSIX mode)

# 1. discovery: the loader finds the ICD through its search path
run env VK_LOADER_DEBUG=error,warn,driver $bin/vktest -i > $out 2>&1
rc=$?
say "list-exit $rc"
if [ $rc != 0 ]; then
	# the same with the ICD named explicitly: tells a discovery problem from a driver problem
	run env VK_DRIVER_FILES="$(ls $icd/broadcom_icd.*.json | head -n 1)" VK_LOADER_DEBUG=all \
		$bin/vktest -i > $out 2>&1
	rc2=$?
	say "list-explicit-icd-exit $rc2"
	if [ $rc2 = 0 ]; then
		say "icd-discovery FAIL (the driver works when named)"
	fi
fi

# 2. the tests: render + copy (semaphore, fence), timestamp queries, compute, indirect dispatch
run env VK_LOADER_DEBUG=error,warn $bin/vktest > $out 2>&1
rc=$?
say "test-exit $rc"
if [ $rc != 0 ]; then
	# serialised submissions: does it depend on synchronisation between the queues?
	run env V3D_DEBUG=sync VK_LOADER_DEBUG=error,warn $bin/vktest > $out 2>&1
	say "test-sync-exit $?"
fi

# 3. throughput: the same again, plus 100 render submissions in flight (re-submitted while pending)
run env VK_LOADER_DEBUG=error,warn $bin/vktest -n 100 > $out 2>&1
say "frames-exit $?"

# 4. GL still works (its fences are sync files now, and it has timer queries)
run $bin/gltri -n 100 > $out 2>&1
say "gltri-exit $?"

say end

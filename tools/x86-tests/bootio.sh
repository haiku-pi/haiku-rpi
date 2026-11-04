#!/bin/sh
# bootio.sh — write integrity on the boot disk itself (scripts/x86-test.sh bootio IMAGE --disk nvme|...): boot 1
# copies the first 80 MB of /boot/system/apps and /boot/system/lib (the boot volume has ~130 MB free) into
# /boot/home/bootio (unaligned, partial-block writes through the boot disk's driver: the NVMe bounce path),
# compares MD5s and restarts; boot 2 compares the copy read back from the disk again. Serial lines "X86T bootio ...".
G=bootio
. /boot/home/x86t/lib.sh
state=/boot/home/bootio.state
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
waitfor -m application/x-vnd.Be-TRAK
list=/boot/home/bootio.list
md5tree() { (cd "$1" && xargs md5sum < $list) > "$2" 2> /dev/null; }
if [ $n = 1 ]; then
	(cd /boot/system && find apps lib -type f | sort | while IFS= read -r f; do
		tot=$((${tot:-0} + $(stat -c %s "$f"))); [ $tot -gt 80000000 ] && break; echo "$f"; done) > $list
	md5tree /boot/system /boot/home/bootio-src.md5
	mkdir -p /boot/home/bootio
	start=$(date +%s)
	(cd /boot/system && tar -cf - -T $list) | (cd /boot/home/bootio && tar -xf -)
	rc=$?
	sync
	md5tree /boot/home/bootio /tmp/dst.md5
	files=$(wc -l < /boot/home/bootio-src.md5)
	if [ $rc = 0 ] && [ "$files" -gt 100 ] && cmp -s /boot/home/bootio-src.md5 /tmp/dst.md5; then
		say "result copy PASS rc=0 $files files in $(( $(date +%s) - start )) s, MD5s equal"
	else
		say "result copy FAIL rc=$rc $(diff /boot/home/bootio-src.md5 /tmp/dst.md5 | head -n 3 | tr '\n' ' ')"
	fi
	sleep 2
	shutdown -r
	exit 0
fi
md5tree /boot/home/bootio /tmp/dst2.md5
if cmp -s /boot/home/bootio-src.md5 /tmp/dst2.md5; then
	say "result after-restart PASS rc=0 MD5s equal after a restart"
else
	say "result after-restart FAIL rc=1 $(diff /boot/home/bootio-src.md5 /tmp/dst2.md5 | head -n 3 | tr '\n' ' ')"
fi
finish

#!/bin/sh
# fragwrite.sh [DIR] — write a badly fragmented file and sync it: the kernel-stack overflow of 10-23 (the
# iterative file I/O nested once per few file extents with synchronous I/O, as remote_disk's; a network boot)
#
# Fills the volume of DIR (default /boot/home/fragtest) so that the only free space left is thousands of
# 4 KiB holes, writes a 30 MB file into them (~7500 extents), syncs it, checks it, and frees everything.
# Prints "FRAG ok" or "FRAG bad"; on a kernel with the bug the sync panics (unhandled page fault on the
# page writer's or the syncing thread's stack bottom).
dir=${1:-/boot/home/fragtest}
rm -rf "$dir"
mkdir -p "$dir/small"
echo "FRAG small files"
i=0
while [ $i -lt 20000 ]; do
	head -c 4096 /dev/zero > "$dir/small/$i" || break
	i=$((i + 1))
done
sync
echo "FRAG fill"
dd if=/dev/zero of="$dir/fill" bs=1048576 2> /dev/null
sync
echo "FRAG holes"
i=0
while [ $i -lt 20000 ]; do
	rm -f "$dir/small/$i"
	i=$((i + 2))
done
sync
df "$dir" | grep -i "free"
echo "FRAG write"
head -c 31457280 /dev/urandom > "$dir/frag" 2> /dev/null
sum1=$(md5sum < "$dir/frag")
echo "FRAG sync"
sync
echo "FRAG synced"
sum2=$(md5sum < "$dir/frag")
[ "$sum1" = "$sum2" ] && echo "FRAG ok" || echo "FRAG bad"
rm -rf "$dir"
sync
echo "FRAG end"

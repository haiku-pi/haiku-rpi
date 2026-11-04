#!/bin/sh
# usb-bfs.sh [DEV] — run on Haiku in a bench session (scripts/pi-ssh.sh): a BFS file system on the USB disk,
# end to end (docs/design/usb-storage-integrity.md): mkfs, mount, copy the system packages onto it (md5 of
# every file), unmount, mount again, compare the md5s, checkfs, unmount. DEV default: the first
# /dev/disk/usb/*/0/raw. Destroys what is on DEV.
dev=${1:-$(ls /dev/disk/usb/*/0/raw 2>/dev/null | head -n 1)}
mnt=/usbbfs
[ -n "$dev" ] && [ -e "$dev" ] || { echo "UB no USB disk"; exit 1; }
echo "UB dev=$dev"
same() { [ "$(md5sum < "$1")" = "$(md5sum < "$2")" ]; }	# (no cmp or diff in the base system)
mkfs -t bfs -q "$dev" usbbfs > /dev/null 2>&1; echo "UB mkfs exit=$?"
mkdir -p $mnt
mount -t bfs "$dev" $mnt; echo "UB mount exit=$?"
mkdir -p $mnt/pkgs
cp /boot/system/packages/*.hpkg $mnt/pkgs/; echo "UB copy exit=$? $(du -sh $mnt/pkgs | cut -f1) in $(ls $mnt/pkgs | wc -l) files"
(cd /boot/system/packages && md5sum *.hpkg) > /tmp/usbbfs-src.md5
(cd $mnt/pkgs && md5sum *.hpkg) > /tmp/usbbfs-copy.md5
same /tmp/usbbfs-src.md5 /tmp/usbbfs-copy.md5 && echo "UB md5 after copy: same" || echo "UB md5 after copy: DIFFERENT"
sync
unmount $mnt; echo "UB unmount exit=$?"
mount -t bfs "$dev" $mnt; echo "UB remount exit=$?"
(cd $mnt/pkgs && md5sum *.hpkg) > /tmp/usbbfs-remount.md5
same /tmp/usbbfs-src.md5 /tmp/usbbfs-remount.md5 && echo "UB md5 after remount: same" || echo "UB md5 after remount: DIFFERENT"
checkfs -c $mnt 2>&1 | sed 's/^/UB checkfs: /'
unmount $mnt; echo "UB final unmount exit=$?"
echo "UB done"

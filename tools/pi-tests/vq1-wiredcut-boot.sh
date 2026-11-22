#!/bin/sh
# vq1-wiredcut-boot.sh — a UserBootscript for scripts/qemu-virt.sh (VQ1): wiredcut (tools/haiku-tests/wiredcut.c,
# put on the image as /boot/home/wiredcut) against the boot disk's raw device, its result and the kernel's VQ1
# lines on the serial console ("WC ..."), then shutdown. ARGS in /boot/home/wiredcut.args (default "200 8 3000").
sleep 10
say() { echo "WC $*" > /dev/dprintf; }
dev=$(ls -d /dev/disk/virtual/virtio_block/*/raw 2> /dev/null | head -n 1)
[ -n "$dev" ] || dev=$(ls -d /dev/disk/*/*/raw /dev/disk/*/*/*/raw 2> /dev/null | head -n 1)
args=$(cat /boot/home/wiredcut.args 2> /dev/null || echo "200 8 3000")
say "device $dev, args $args"
/boot/home/wiredcut "$dev" $args 2>&1 | while read -r line; do say "$line"; done
say "debugger entries: $(grep -a -c 'entered the debugger' /var/log/syslog)"
say end
sleep 2
shutdown -q

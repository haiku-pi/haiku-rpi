#!/bin/sh
# session.sh — the UserBootscript of an interactive bench session (scripts/pi-session.sh): starts sshd with the
# session's key (/boot/home/session.pub, put on the disk by pi-session.sh) so the bench host can log in
# (scripts/pi-ssh.sh). The openssh package comes onto the disk with it. Password logins stay off.
# Serial console lines: "PIS ".
out=/dev/dprintf
say() { echo "PIS $*" > $out; }
sleep 5
# OpenSSH installed by pkgman (a package only copied into system/packages is activated without its sshd user
# and host keys, and sshd then refuses to start)
if [ ! -x /boot/system/bin/sshd ]; then
	pkgman install -y /boot/home/openssh.hpkg > /tmp/pkgman.txt 2>&1
	say "openssh: pkgman exit $?"
fi
[ -f /boot/system/settings/ssh/ssh_host_ed25519_key ] || ssh-keygen -A > /dev/null 2>&1
# Haiku's OpenSSH keeps ~/.ssh in ~/config/settings/ssh
for d in /boot/home/config/settings/ssh /boot/home/.ssh; do
	mkdir -p $d
	cp /boot/home/session.pub $d/authorized_keys
done
/boot/system/bin/sshd -o PermitRootLogin=prohibit-password -o PasswordAuthentication=no -o StrictModes=no \
	-E /boot/home/sshd.log > /tmp/sshd.txt 2>&1
rc=$?
[ $rc = 0 ] || head -n 5 /tmp/sshd.txt /boot/home/sshd.log 2> /dev/null | while read -r line; do say "sshd: $line"; done
say "sshd: exit $rc, $(ifconfig 2> /dev/null | grep -a -o 'inet addr: [0-9.]*' | grep -v 127.0.0.1 | tr '\n' ' ')"
# no screen saver: work over ssh is no input to Haiku, and after a few idle minutes screen_blanker covers the
# screen (black screenshots that look like a program's fault); it comes back within seconds, so every 5 s
( while sleep 5; do
	for t in $(ps | awk '$1 ~ /screen_blanker$/ { print $2 }'); do kill $t; done
done ) > /dev/null 2>&1 &

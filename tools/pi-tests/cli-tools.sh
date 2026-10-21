#!/bin/sh
# cli-tools.sh — a UserBootscript for the command-line tool packages (scripts/build-packages.sh: nano, wget,
# rsync, vim, openssh, git, htop_rivoreo): pkgman installs them from a repository the bench host serves
# (scripts/make-repo.sh + scripts/serve-repo.sh, http://10.42.0.1:8090/arm64), then each one runs once.
# Ethernet with a static address, as pkgman.sh (an SD boot has no DHCP server on the Pi LAN).
# Serial console lines: "CLI "; per tool "CLI <tool> PASS|FAIL ...", then "CLI summary: N failed", "CLI end".
sleep 15
out=/dev/dprintf
say() { echo "CLI $*" > $out; }
failed=0
check() {	# NAME COMMAND... — PASS when the command exits 0; its first output line is shown
	name="$1"; shift
	result="$("$@" 2>&1 < /dev/null)"
	if [ $? -eq 0 ]; then
		say "$name PASS $(echo "$result" | head -n 1 | cut -c1-120)"
	else
		failed=$((failed + 1))
		say "$name FAIL $(echo "$result" | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
	fi
}
repo=http://10.42.0.1:8090/arm64
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up
route add /dev/net/genet/0 inet default gw 10.42.0.1
sleep 3
say "add-repo: $(pkgman add-repo $repo 2>&1 | tr '\n' ' ' | cut -c1-200)"
pkgman install -y nano wget rsync vim openssh git htop_rivoreo < /dev/null > /tmp/pkgman.txt 2>&1
say "install: exit $?"
tail -n 12 /tmp/pkgman.txt | while read -r line; do say "  $line"; done

check nano nano --version
check wget-version wget --version
check wget-http wget -q -O /tmp/repo.info $repo/repo.info
check rsync-version rsync --version
mkdir -p /tmp/rs-src && echo data > /tmp/rs-src/a
check rsync-copy rsync -a /tmp/rs-src/ /tmp/rs-dst/
check rsync-result cat /tmp/rs-dst/a
check vim vim --version
check vim-edit vim -E -s -c 'call setline(1, "edited by vim")' -c 'wq' /tmp/vim.txt
check vim-result cat /tmp/vim.txt
check ssh ssh -V
check ssh-keygen ssh-keygen -q -t ed25519 -N '' -f /tmp/test_key
check sshd-config /boot/system/bin/sshd -t
check git-version git --version
mkdir -p /tmp/repo && cd /tmp/repo
check git-init git init -q
echo hello > file
check git-add git add file
check git-commit git -c user.name=pi -c user.email=pi@example.invalid commit -q -m first
check git-log git log --oneline
cd /
check htop htop --version

say "summary: $failed failed"
say end

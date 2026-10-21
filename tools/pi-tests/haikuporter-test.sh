#!/bin/sh
# haikuporter-test.sh — a UserBootscript for the development image with a HaikuPorts tree (mkimage-pi4.sh
# --add-tree of a staged tree: /boot/system/non-packaged/haikuports — artifacts/haikuports-min, just the
# test ports (the whole tree costs haikuporter ~9 min of recipe parsing per port on the Pi) — sources pre-fetched into the
# ports' download/ directories on the host; the tools of scripts/build-bootstrap-tools.sh and the python
# modules of scripts/build-python-modules.sh also added): builds ports natively with haikuporter, one by
# one, activates each package and runs the program it provides. Serial console lines: "HPT ".
sleep 15
out=/dev/dprintf
say() { echo "HPT $*" > $out; }
# the cross-built python3.10 package: see devtools-test.sh
export LIBRARY_PATH="$LIBRARY_PATH:/boot/system/develop/lib"
export PYTHONHOME=/boot/system
# its missing compression modules (scripts/build-python-modules.sh)
export PYTHONPATH=/boot/system/non-packaged/lib/python3.10/lib-dynload
tree=/boot/system/non-packaged/haikuports
# no network here, so no NTP: a clock at 1970 makes every source file "newer than now", and make then
# remakes what the tarball ships prebuilt (gperf's manual: texi2pdf). Set it from the image instead:
# mkimage-pi4.sh writes this script into it, so the file's time is when the image was made.
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
say "clock: $(date)"
cat > /boot/home/config/settings/haikuports.conf <<CONF
TREE_PATH="$tree"
PACKAGER="haiku-pi build farm <build@haiku-pi.invalid>"
TARGET_ARCHITECTURE="arm64"
CONF
say "python: $(python3 -c 'import zlib, bz2, lzma; d = b"haiku" * 1000; print("zlib bz2 lzma round trip", all(m.decompress(m.compress(d)) == d for m in (zlib, bz2, lzma)))' 2>&1 | tail -n 1)"
say "tools: $(for t in patch tar gzip xz bzip2 diff; do $t --version 2>&1 | head -n 1 | tr '\n' ';'; done)"
cd /tmp && echo haiku > t.txt && tar -cJf t.tar.xz t.txt && rm t.txt && tar -xf t.tar.xz \
	&& say "tools: tar+xz round trip $(cat t.txt)"; cd /
# the bootstrap haikuporter's chroot setup copies the font settings unconditionally (under set -e);
# newer ones check that they exist first
mkdir -p /boot/system/settings/fonts
# port|command line that runs what it built
for test in \
	"hoedown|echo '# Hello *Haiku* on the Pi' | hoedown" \
	"gperf|printf 'haiku\\npi\\n' | gperf | grep -c in_word_set"
do
	port=${test%%|*}
	say "building $port"
	start=$(date +%s)
	haikuporter -G -y -j4 --no-source-packages $port > /boot/home/haikuporter-$port.log 2>&1
	rc=$?
	say "$port: haikuporter-exit $rc in $(( $(date +%s) - start )) s"
	# what led to a failure (the full tree's license and architecture complaints, and the clean-up's
	# "removing ..." lines, are noise)
	grep -v -E '^removing |No match found for license|Valid license filenames|cannot be built for architecture|\.recipe\)$' \
		/boot/home/haikuporter-$port.log | grep -n -B 40 'Build has failed' | head -n 60 \
		| while read -r line; do say "fail: $line"; done
	grep -v '^removing ' /boot/home/haikuporter-$port.log | tail -n 15 \
		| while read -r line; do say "log: $line"; done
	for p in $tree/packages/$port-*.hpkg; do
		[ -e "$p" ] || continue
		say "package: $(basename $p) $(stat -c %s $p) bytes"
		say "install: $(pkgman install -y "$p" < /dev/null 2>&1 | tail -n 1)"
	done
	# activation by package_daemon: wait for the command to appear
	waited=0
	while [ $waited -lt 30 ] && ! command -v $port > /dev/null 2>&1; do sleep 2; waited=$((waited + 2)); done
	say "$port run (after ${waited} s): $(sh -c "${test#*|}" 2>&1)"
done
say end

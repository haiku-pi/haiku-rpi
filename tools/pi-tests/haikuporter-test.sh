#!/bin/sh
# haikuporter-test.sh — a UserBootscript for the development image with a HaikuPorts tree (mkimage-pi4.sh
# --add-tree of a staged tree: /boot/system/non-packaged/haikuports, sources pre-fetched into the
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
cat > /boot/home/config/settings/haikuports.conf <<CONF
TREE_PATH="$tree"
PACKAGER="haiku-pi build farm <build@haiku-pi.invalid>"
TARGET_ARCHITECTURE="arm64"
CONF
say "python: $(python3 -c 'import zlib, bz2, lzma; d = b"haiku" * 1000; print("zlib bz2 lzma round trip", all(m.decompress(m.compress(d)) == d for m in (zlib, bz2, lzma)))' 2>&1 | tail -n 1)"
say "tools: $(for t in patch tar gzip xz bzip2 diff; do $t --version 2>&1 | head -n 1 | tr '\n' ';'; done)"
cd /tmp && echo haiku > t.txt && tar -cJf t.tar.xz t.txt && rm t.txt && tar -xf t.tar.xz \
	&& say "tools: tar+xz round trip $(cat t.txt)"; cd /
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
	tail -n 25 /boot/home/haikuporter-$port.log | while read -r line; do say "log: $line"; done
	for p in $tree/packages/$port-*.hpkg; do
		[ -e "$p" ] || continue
		say "package: $(basename $p) $(stat -c %s $p) bytes"
		cp "$p" /boot/system/packages/
	done
	sleep 3
	say "$port run: $(sh -c "${test#*|}" 2>&1)"
done
say end

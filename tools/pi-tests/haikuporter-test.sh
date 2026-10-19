#!/bin/sh
# haikuporter-test.sh — a UserBootscript for the development image with a HaikuPorts tree (mkimage-pi4.sh
# --add-tree of a staged tree: /boot/system/non-packaged/haikuports, sources pre-fetched into the
# ports' download/ directories on the host): builds a port natively with haikuporter (PORT, default
# hoedown), activates the package and runs it. Serial console lines: "HPT ".
sleep 15
out=/dev/dprintf
say() { echo "HPT $*" > $out; }
port=${PORT:-hoedown}
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
say "building $port"
start=$(date +%s)
haikuporter -C -G -y -j4 --no-source-packages $port > /boot/home/haikuporter.log 2>&1
rc=$?
say "haikuporter-exit $rc in $(( $(date +%s) - start )) s"
tail -n 25 /boot/home/haikuporter.log | while read -r line; do say "log: $line"; done
for p in $tree/packages/*.hpkg; do
	[ -e "$p" ] || continue
	say "package: $(basename $p) $(stat -c %s $p) bytes"
	cp "$p" /boot/system/packages/
done
sleep 3
say "run: $(echo '# Hello *Haiku* on the Pi' | hoedown 2>&1)"
say end

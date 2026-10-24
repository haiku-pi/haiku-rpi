#!/bin/sh
# photocraft-cli.sh — a UserBootscript for Photocraft's command-line tool (scripts/build-photocraft.sh):
# decode, encode, filters and document info on two test images from the Photocraft tree (a 1600-wide
# JPEG screenshot and the 1024x1024 PNG app icon), each result's MD5. Image:
#   scripts/mkimage-pi4.sh --add-tree artifacts/photocraft/non-packaged --bootscript tools/pi-tests/photocraft-cli.sh
# Serial console lines: "PCC "; per operation "PCC <op>: exit N md5 <output's md5>" and
# "PCC <op>: ms N" (wall time); "PCC end". The same script runs on the host build
# (scripts/build-photocraft.sh hosttest, PCC_* variables below): every line but the "ms" ones should
# be equal (artifacts/photocraft/host-results.txt).
sleep "${PCC_SLEEP:-20}"
out="${PCC_OUT:-/dev/dprintf}"
bin="${PCC_BIN:-/boot/system/non-packaged/bin/photocraft-cli}"
data="${PCC_DATA:-/boot/system/non-packaged/data/photocraft-test}"
tmp="${PCC_TMP:-/tmp/photocraft-test}"
say() { echo "PCC $*" >> "$out"; }	# (>>: on the host, out is a file)
now() { date +%s%N | cut -c1-13; }	# ms
md5() { md5sum < "$1" | cut -c1-32; }
# op LABEL RESULT ARGS...: run photocraft-cli ARGS; RESULT is the file it writes, or "-" for its
# standard output
op() {
	label=$1 result=$2
	shift 2
	t0=$(now)
	"$bin" "$@" > stdout.txt 2> stderr.txt
	status=$?
	t1=$(now)
	[ "$result" = - ] && result=stdout.txt
	if [ -f "$result" ]; then say "$label: exit $status md5 $(md5 "$result")"
	else say "$label: exit $status no output"; fi
	say "$label: ms $((t1 - t0))"
	head -c 300 stderr.txt | while IFS= read -r l; do say "$label stderr: $l"; done
}
say begin
rm -rf "$tmp"
mkdir -p "$tmp"
cp "$data"/* "$tmp/" || say "no test data in $data"
cd "$tmp" || exit 1
op version - --version
head -n 1 stdout.txt | while IFS= read -r l; do say "version: $l"; done
op commands - commands
op info-jpg - info photocraft-masks.jpg --compact
say "info-jpg: $(head -c 200 stdout.txt)"
op info-png - info photocraft-1024.png --compact
op jpg-to-png masks.png convert photocraft-masks.jpg masks.png
op png-to-jpg icon.jpg convert photocraft-1024.png icon.jpg --quality 85
op png-to-webp icon.webp convert photocraft-1024.png icon.webp
op png-to-tiff icon.tif convert photocraft-1024.png icon.tif --tiff-compression lzw
op tiff-to-png icon-tif.png convert icon.tif icon-tif.png
op invert inverted.png run photocraft-1024.png --cmd image.adjustments.invert --out inverted.png
op gaussian-blur blurred.png run photocraft-1024.png --cmd filter.blur.gaussianBlur --params '{"radius":8}' \
	--out blurred.png
op unsharp-mask sharpened.png run photocraft-masks.jpg --cmd filter.sharpen.unsharpMask \
	--params '{"amount":120,"radius":2,"threshold":0}' --out sharpened.png
op new-doc new.png run --new '{"width":640,"height":480,"background":"white"}' --cmd image.adjustments.invert \
	--out new.png
say end

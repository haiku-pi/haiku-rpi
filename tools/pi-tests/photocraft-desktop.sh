#!/bin/sh
# photocraft-desktop.sh — a UserBootscript for Photocraft's desktop integration on Haiku
# (docs/design/photocraft.md, P4) without Photocraft's window, so it runs in QEMU too: the same rfd (file
# panels, alerts), arboard (system clipboard) and fontdb (system fonts) through
# tools/photocraft-desktop-test, keys typed into the panels by keyinject, the clipboard checked with Haiku's
# own `clipboard` and `screenshot -c`, and libxkbcommon's Compose table for Haiku's locale name. Image:
#   scripts/build-wayland.sh libxkbcommon   (libxkbcommon 1.13.2-2: the X11 locale database)
#   scripts/build-photocraft.sh --only gui  (photocraft-desktop-test, keyinject, wlview, photocraft)
#   scripts/stage-packages.sh --wine-runtime
#   scripts/mkimage-pi4.sh --out artifacts/images/photocraft-desktop.img --add-tree artifacts/wayland-stage \
#       --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-desktop.sh
#   scripts/qemu-virt.sh --image artifacts/images/photocraft-desktop.img --secs 420
# Serial console lines: "PCD <step>: ..." ("PDT <command>: <answer>" from the test program), "PCD end".
# Expected (positive markers):
#   text: clipboard -p prints what arboard set; arboard reads what `clipboard -c` set; UTF-8 intact
#   html: html "<b>PDT</b> html" and its text alternative
#   image: set 64x48 → `clipboard -d` lists image/bitmap and image/png; read back with the same FNV hash;
#     screenshot -c → read as the screen's size
#   files: Tracker-style refs (r<dev>_<node>) in `clipboard -d`; both paths read back
#   clear: get_text → "The clipboard contents were not available in the requested format..."
#   dialogs (each: the panel/alert found by keyinject, a screenshot /boot/home/pcd-<step>.png, the answer):
#     open-typed   photocraft-masks.jpg (type-ahead "photocraft-m", Return)
#     open-filter-jpg  photocraft-masks.jpg, open-filter-png  photocraft-1024.png (Down selects the first entry
#                  the filter shows, Return; the Tracker's type-ahead would match hidden entries too)
#     open-cancel  cancelled (Escape)
#     save         <tmp>/pcd saved.png (the suggested name, Return)
#     folder       the panel's folder itself (Return with nothing selected)
#     sync-open    photocraft-masks.jpg (blocking rfd::FileDialog)
#     alert-yes    Yes (Return: the default button); alert-escape: Cancel (Escape)
#     no-wayland   cancelled at once, "rfd: no BApplication" on stderr
#   fonts: the faces in /boot/system/data/fonts (QEMU 10-25: 12 faces, 6 Noto families), not 0
#   compose: xkbcli-compile-compose for LC_CTYPE (en.UTF-8 on a default system): thousands of sequences,
#     <dead_acute> <e> → "é", no "couldn't find a Compose file"
sleep "${PCD_SLEEP:-25}"
out="${PCD_OUT:-/dev/dprintf}"
bin="${PCD_BIN:-/boot/system/non-packaged/bin}"
data="${PCD_DATA:-/boot/system/non-packaged/data/photocraft-test}"
tmp="${PCD_TMP:-/tmp/photocraft-desktop}"
pdt="$bin/photocraft-desktop-test"
say() { echo "PCD $*" >> "$out"; }
# the stack comes as a tree in non-packaged (scripts/stage-packages.sh): the packages' compiled-in data
# roots are /boot/system/data/X11/{xkb,locale}
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export XLOCALEDIR=/boot/system/non-packaged/data/X11/locale
export PATH=$bin:$PATH
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
rm -rf "$tmp"
mkdir -p "$tmp"
cd "$tmp" || exit 1

# STEP COMMAND ARGS...: the test program, its output reported
run() {
	step=$1
	shift
	"$pdt" "$@" > "$tmp/$step.txt" 2>&1
	rc=$?
	while IFS= read -r l; do say "$step: $l"; done < "$tmp/$step.txt"
	say "$step: exit $rc"
}

# STEP TITLE KEYS COMMAND ARGS...: the test program shows a dialog; once a window of its team whose title
# has TITLE is there, a screenshot, then KEYS typed into it (keyinject: "~" Return, "^[" Escape, "^>" Down);
# the answer within 15 s
dialog() {
	step=$1 title=$2 keys=$3
	shift 3
	"$pdt" "$@" > "$tmp/$step.txt" 2>&1 &
	pid=$!
	found=no
	waited=0
	while [ $waited -lt 20 ] && kill -0 $pid 2> /dev/null; do
		if keyinject $pid "$title" "" > /dev/null 2>&1; then found=yes; break; fi
		sleep 1
		waited=$((waited + 1))
	done
	say "$step: window \"$title\": $found after $waited s"
	sleep 1
	screenshot -s "/boot/home/pcd-$step.png" > /dev/null 2>&1
	[ $found = yes ] && keyinject $pid "$title" "$keys" > /dev/null 2>&1
	waited=0
	while [ $waited -lt 15 ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		say "$step: still running after 15 s"
		kill -9 $pid 2> /dev/null
		wait $pid 2> /dev/null
	else
		wait $pid
		say "$step: exit $?"
	fi
	grep -a -E 'PDT|rfd|rror|panic' "$tmp/$step.txt" | head -n 20 | while IFS= read -r l; do say "$step: $l"; done
}

say begin
say "bin: $(ls "$bin" | tr '\n' ' ')"
say "LC_CTYPE=$LC_CTYPE"

# clipboard: text both ways (Haiku's clipboard command as the second tool)
run text-set clip-text-set "PDT text: Zażółć gęślą jaźń, 1 2 3"
say "text-set: clipboard -p: $(clipboard -p 2>&1)"
clipboard -c "set by the clipboard command" > /dev/null 2>&1
run text-get clip-text-get
run html-set clip-html-set "<b>PDT</b> html" "PDT html"
run html-get clip-html-get
# image: arboard's, read back, and as Haiku sees it; then a native one (Screenshot's image/bitmap)
run image-set clip-image-set 64 48
clipboard -d 2>&1 | grep -a -E 'image/|text/|_cspace|_frame|"r[0-9]' | head -n 10 | while IFS= read -r l; do say "image-set: clipboard -d: $l"; done
run image-get clip-image-get
screenshot -c > /dev/null 2>&1
sleep 2
run image-screen clip-image-get
# files: as the Tracker copies them
run files-set clip-files-set "$data/photocraft-masks.jpg" "$data/photocraft-1024.png"
clipboard -d 2>&1 | grep -a -E 'entry_ref|[rm][0-9]+_[0-9]+|uri-list' | head -n 6 | while IFS= read -r l; do say "files-set: clipboard -d: $l"; done
run files-get clip-files-get
run clear clip-clear
run clear-get clip-text-get

# file panels and alerts
dialog open-typed Open "photocraft-m~" open "$data"
dialog open-filter-jpg Open "^>~" open "$data" jpg
dialog open-filter-png Open "^>~" open "$data" png
dialog open-cancel Open "^[" open "$data"
dialog save Save "~" save "$tmp" "pcd saved.png" png
dialog folder "Select a folder" "~" folder "$data"
dialog sync-open "Sync open" "photocraft-m~" sync-open "$data"
dialog alert-yes "PDT alert" "~" alert "PDT alert" "Go on?" yesno
dialog alert-escape "PDT alert" "^[" alert "PDT alert" "Go on?" yesnocancel
run no-wayland --no-wayland open "$data"

# fonts: fontdb's system fonts (Haiku's font folders, patches/photocraft/fontdb-0.23.0)
run fonts fonts

# Compose: the table for this system's locale (LC_CTYPE), as winit asks libxkbcommon for it
compose=/boot/system/non-packaged/lib/xkbcommon/xkbcli-compile-compose
[ -x "$compose" ] || compose=/boot/system/lib/xkbcommon/xkbcli-compile-compose
"$compose" --locale "${LC_CTYPE:-C}" > "$tmp/compose.txt" 2> "$tmp/compose.err"
say "compose: $compose --locale ${LC_CTYPE:-C}: exit $?, $(grep -a -c '^<' "$tmp/compose.txt") sequences"
grep -a -E '^<dead_acute> <e> ' "$tmp/compose.txt" | head -n 1 | while IFS= read -r l; do say "compose: $l"; done
head -n 5 "$tmp/compose.err" | while IFS= read -r l; do say "compose: stderr: $l"; done
sync
say end

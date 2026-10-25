#!/bin/sh
# photocraft-package.sh — a UserBootscript: the photocraft package installed (in /boot/system/packages, or
# activated from /boot/home/config/packages) on an image that has its requirements (mesa 26.2.5-6,
# wayland_server 0.1.20251004-10, libxkbcommon 1.13.2-2, wayland, xkeyboard_config). Checks: activated (the
# files are there), the Deskbar entry, the command; a start of the program without any environment
# variables (`env -i` + the system's own boot environment); then "Open with" as the Tracker does it
# (tools/haiku-tests/mimeapps --launch: BRoster::Launch with a B_REFS_RECEIVED message) on /boot/home/pck.jpg —
# the launcher must start bin/PhotoCraft with the document's path as its argument — and the registrar's MIME
# entry for the launcher (made at its first start) with image/jpeg listing it among its supporting apps.
# Image: scripts/image-add.sh on a release image, with the packages in /boot/system/packages, this script as
# /boot/home/config/settings/boot/UserBootscript, tools/haiku-tests/mimeapps as /boot/home/mimeapps and a JPEG
# as /boot/home/pck.jpg. On the Pi the window opens (screenshots /boot/home/photocraft-package*.png); in QEMU
# it stops at "No suitable graphics adapter" after its Wayland surface (no GPU).
# Serial lines: "PCK ...", "PCK end".
sleep "${PCK_SLEEP:-30}"
out="${PCK_OUT:-/dev/dprintf}"
say() { echo "PCK $*" >> "$out"; }
say begin
say "packages: $(ls /boot/system/packages /boot/home/config/packages 2> /dev/null | grep -E 'photocraft|mesa-|wayland|xkb' | tr '\n' ' ')"
say "launcher: $(ls -l /boot/system/apps/PhotoCraft/PhotoCraft 2>&1 | awk '{print $5, $NF}')"
say "program: $(ls -l /boot/system/apps/PhotoCraft/bin/PhotoCraft 2>&1 | awk '{print $5, $NF}')"
say "command: $(ls -l /boot/system/bin/photocraft 2>&1 | sed 's/.* -> //')"
say "deskbar: $(ls -l /boot/system/data/deskbar/menu/Applications/PhotoCraft 2>&1 | sed 's/.* -> //')"
# a start as the Deskbar does it: no test environment (WGPU_BACKEND, RUST_LOG, XKB_CONFIG_ROOT are not set)
mkdir -p /tmp/pck
env -i HOME=/boot/home PATH=/bin:/boot/system/bin LIBRARY_PATH="$LIBRARY_PATH" ADDON_PATH="$ADDON_PATH" \
	LC_CTYPE="$LC_CTYPE" /boot/system/bin/photocraft > /tmp/pck/run.txt 2>&1 &
pid=$!
waited=0
while [ $waited -lt 25 ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
screenshot -s /boot/home/photocraft-package.png > /dev/null 2>&1
if kill -0 $pid 2> /dev/null; then
	say "run: alive after $waited s"
	hey $pid quit > /dev/null 2>&1
	w=0
	while [ $w -lt 15 ] && kill -0 $pid 2> /dev/null; do sleep 1; w=$((w + 1)); done
	if kill -0 $pid 2> /dev/null; then say "run: still running 15 s after quit"; kill -9 $pid; fi
	wait $pid 2> /dev/null
	say "run: quit after $w s"
else
	wait $pid
	say "run: exit $? after $waited s"
fi
grep -a -v -E '^(display|client): ' /tmp/pck/run.txt | head -n 40 \
	| while IFS= read -r l; do say "run: $(echo "$l" | cut -c1-200)"; done
say "settings: $(ls /boot/home/.config/photocraft 2>&1 | tr '\n' ' ' | cut -c1-160)"
# "Open with" as the Tracker launches: the launcher must pass the document on as an argument
if [ -x /boot/home/mimeapps ] && [ -f /boot/home/pck.jpg ]; then
	# (the program inherits the output: not into a command substitution, which would wait for it)
	/boot/home/mimeapps --launch application/x-vnd.storyteller-photocraft /boot/home/pck.jpg \
		> /tmp/pck/open.txt 2>&1 < /dev/null
	say "open with: $(head -n 1 /tmp/pck/open.txt)"
	# the program's command line (in QEMU it ends within a second or two: no GPU)
	i=0
	while [ $i -lt 30 ]; do
		line=$(ps | grep -a 'apps/PhotoCraft/bin/PhotoCraft' | grep -v grep | head -n 1)
		[ -n "$line" ] && break
		sleep 0.1
		i=$((i + 1))
	done
	say "open with: program: ${line:-not seen}"
	sleep 20
	screenshot -s /boot/home/photocraft-package-open.png > /dev/null 2>&1
	for t in $(ps | awk '/apps\/PhotoCraft\/bin/ && !/awk/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) {print $i; break}}'); do
		hey $t quit > /dev/null 2>&1
	done
fi
# the launcher's MIME entry (signature, supported types: "Open with") is made when it first starts (its
# BApplication calls create_app_meta_mime)
db=/boot/home/config/settings/mime_db
say "mime entry: $(ls -d $db/application/x-vnd.storyteller-photocraft 2>&1)"
for attr in META:PREF_APP META:SUPP_TYPES META:FILE_TYPES; do
	say "mime $attr: $(catattr "$attr" $db/application/x-vnd.storyteller-photocraft 2>&1 | tr '\n' ' ' | cut -c1-200)"
done
# the Tracker's "Open with": the types' supporting applications (tools/haiku-tests/mimeapps, in /boot/home)
[ -x /boot/home/mimeapps ] && /boot/home/mimeapps image/jpeg image/png image/tiff image/x-targa \
	| while IFS= read -r l; do say "$l"; done
grep -a -E "entered the debugger" /var/log/syslog 2> /dev/null | tail -n 5 | while IFS= read -r l; do say "syslog: $l"; done
say end

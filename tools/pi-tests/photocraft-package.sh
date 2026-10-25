#!/bin/sh
# photocraft-package.sh — a UserBootscript: the photocraft package installed (in /boot/system/packages, or
# activated from /boot/home/config/packages) on an image that has its requirements (image-2026-10-25e:
# mesa 26.2.5-6, wayland_server 0.1.20251004-10, libxkbcommon 1.13.2-2). Checks: activated (the files are
# there), the Deskbar entry, the command, the registrar's MIME entry for the app (signature, supported types)
# and that image/jpeg lists it among its supporting applications ("Open with"), then a start without any
# environment variables: `env -i` + the system's own boot environment, as the Deskbar launches it.
# Image: scripts/image-add.sh on a release image, with the packages in /boot/system/packages, this script as
# /boot/home/config/settings/boot/UserBootscript and tools/haiku-tests/mimeapps as /boot/home/mimeapps.
# On the Pi the window opens (PCK screenshot /boot/home/photocraft-package.png after 20 s); in QEMU it stops at
# "No suitable graphics adapter" after its Wayland surface (no GPU).
# Serial lines: "PCK ...", "PCK end".
sleep "${PCK_SLEEP:-30}"
out="${PCK_OUT:-/dev/dprintf}"
say() { echo "PCK $*" >> "$out"; }
say begin
say "packages: $(ls /boot/system/packages /boot/home/config/packages 2> /dev/null | grep -E 'photocraft|mesa-|wayland|xkb' | tr '\n' ' ')"
say "app: $(ls -l /boot/system/apps/PhotoCraft/PhotoCraft 2>&1 | awk '{print $5, $NF}')"
say "command: $(ls -l /boot/system/bin/photocraft 2>&1 | sed 's/.* -> //')"
say "deskbar: $(ls -l /boot/system/data/deskbar/menu/Applications/PhotoCraft 2>&1 | sed 's/.* -> //')"
# a start as the Deskbar does it: no test environment (WGPU_BACKEND, RUST_LOG, XKB_CONFIG_ROOT are not set)
mkdir -p /tmp/pck
env -i HOME=/boot/home PATH=/bin:/boot/system/bin LIBRARY_PATH="$LIBRARY_PATH" ADDON_PATH="$ADDON_PATH" \
	LC_CTYPE="$LC_CTYPE" /boot/system/apps/PhotoCraft/PhotoCraft > /tmp/pck/run.txt 2>&1 &
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
# the app's MIME entry (signature, supported types: "Open with") is made when it starts (its BApplication,
# made by the Wayland server, calls create_app_meta_mime)
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

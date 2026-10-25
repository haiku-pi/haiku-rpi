#!/bin/sh
# wayland-keys.sh — a UserBootscript: what a Wayland client of Haiku's in-process server sees of keys with
# modifiers (tools/haiku-tests/wlkeys: a toplevel made as Photocraft's, its wl_keyboard read through
# libxkbcommon as winit reads it). For the Photocraft P4 question "Ctrl+O does not reach the app"
# (docs/design/photocraft.md). Image: as photocraft-desktop.sh (artifacts/wayland-stage +
# artifacts/photocraft/gui-non-packaged, which has wlkeys and keyinject).
# Keys, each run preceded by a marker letter so the WLK lines can be told apart:
#   a, then keyinject "^o"  (Control+O as keyinject posts it: B_CONTROL_KEY)
#   b, then keyinject "%o"  (Command+O: B_COMMAND_KEY, Haiku's shortcut key)
#   then "PKY sendkey" on the serial console: the host may send real keys through QEMU's USB keyboard
#   (input_server; scripts/qmp-hmp.py SOCKET "sendkey c", "sendkey ctrl-o", "sendkey d", "sendkey alt-o"),
#   waited for 25 s
# Serial lines: "PKY <line>" (wlkeys' "WLK ..." lines at the end), "PKY end".
sleep "${PKY_SLEEP:-25}"
out="${PKY_OUT:-/dev/dprintf}"
bin="${PKY_BIN:-/boot/system/non-packaged/bin}"
tmp="${PKY_TMP:-/tmp/wayland-keys}"
say() { echo "PKY $*" >> "$out"; }
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export XLOCALEDIR=/boot/system/non-packaged/data/X11/locale
rm -rf "$tmp"
mkdir -p "$tmp"
say begin
"$bin/wlkeys" 60 > "$tmp/wlkeys.txt" 2>&1 &
pid=$!
waited=0
until grep -q "WLK ready" "$tmp/wlkeys.txt" 2> /dev/null || [ $waited -ge 20 ]; do sleep 1; waited=$((waited + 1)); done
say "ready after $waited s"
sleep 2
screenshot -s /boot/home/wayland-keys.png > /dev/null 2>&1
say "keyinject a ^o: $("$bin/keyinject" $pid wlkeys "a^o" 2>&1 | tail -n 1)"
sleep 1
say "keyinject b %o: $("$bin/keyinject" $pid wlkeys "b%o" 2>&1 | tail -n 1)"
sleep 1
say sendkey
sleep 25
kill $pid 2> /dev/null
wait $pid 2> /dev/null
grep -a -v "^wl_ips\|^display:\|^client:" "$tmp/wlkeys.txt" | head -n 120 | while IFS= read -r l; do say "$l"; done
say end

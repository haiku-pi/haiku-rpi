# wenv.sh — sourced in a shell on the Pi (scripts/pi-session.sh puts it in /boot/home): the Wine in
# /boot/system/non-packaged with the games' prefix, as tools/pi-tests/wine-games.sh runs it
export PATH=/boot/system/non-packaged/bin:$PATH WINEPREFIX=/boot/home/wineprefix
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export WINEDEBUG=${WINEDEBUG:-err+all,fixme-all} WINE_D3D_CONFIG=${WINE_D3D_CONFIG:-renderer=gl}
# a full boot volume makes Wine fail in misleading ways (a prefix stops part-way, programs crash at start),
# so say it whenever the environment is set up
free_kib=$(df /boot 2> /dev/null | awk '/Free Blocks/ { v = $3; u = $4; if (u ~ /GiB/) v *= 1048576; else if (u ~ /MiB/) v *= 1024; print int(v) }')
[ -n "$free_kib" ] && [ "$free_kib" -lt 1048576 ] && echo "wenv: WARNING: only $((free_kib / 1024)) MiB free on /boot" >&2

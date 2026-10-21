# wenv.sh — sourced in a shell on the Pi (scripts/pi-session.sh puts it in /boot/home): the Wine in
# /boot/system/non-packaged with the games' prefix, as tools/pi-tests/wine-games.sh runs it
export PATH=/boot/system/non-packaged/bin:$PATH WINEPREFIX=/boot/home/wineprefix
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export WINEDEBUG=${WINEDEBUG:-err+all,fixme-all} WINE_D3D_CONFIG=${WINE_D3D_CONFIG:-renderer=gdi}

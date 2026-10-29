#!/bin/sh
# first-boot.sh — the mega image's UserBootscript (scripts/build-mega-image.sh): on the first boot, the
# ~/Desktop/Test Apps folder (links to the launchers in /boot/system/non-packaged/apps/TestApps and to the
# packaged applications), then a Wine prefix (~/.wine, with Wine Mono: ~1-3 min) and the StarCraft
# shareware's registry keys. Shows a notification when Wine is ready; runs once (it renames itself).
# Serial console lines "MEGA ..." (the bench reads them); a log in ~/mega-logs/first-boot.log.
out=/dev/dprintf
mkdir -p /boot/home/mega-logs
log=/boot/home/mega-logs/first-boot.log
say() { echo "MEGA $*" > $out; echo "$(date +%T) $*" >> $log; }
sleep 15
say begin
desk="/boot/home/Desktop/Test Apps"
mkdir -p "$desk"
for f in /boot/system/non-packaged/apps/TestApps/*; do
	[ -x "$f" ] && ln -sf "$f" "$desk/$(basename "$f")"
done
# the packaged applications, where they are
for app in /boot/system/apps/PhotoCraft/PhotoCraft /boot/system/apps/Firefox/Firefox \
		/boot/system/apps/WebPositive /boot/system/apps/OpenArena/OpenArena \
		/boot/system/apps/SuperTuxKart/SuperTuxKart \
		/boot/system/demos/GLTeapot /boot/system/apps/MediaPlayer; do
	[ -e "$app" ] && ln -sf "$app" "$desk/$(basename "$app")"
done
[ -f /boot/home/mega-README.txt ] && ln -sf /boot/home/mega-README.txt "$desk/README.txt"
say "desktop: $(ls "$desk" | wc -l) entries in Test Apps"

notify --type information --group "Test image" --title "Setting up Wine" \
	"The Windows programs in Test Apps work after this (1-3 minutes)." > /dev/null 2>&1
start=$(date +%s)
wineboot -i > /boot/home/mega-logs/wineboot.log 2>&1 < /dev/null
say "wineboot: exit $? after $(( $(date +%s) - start )) s, syswow64 $(ls /boot/home/.wine/drive_c/windows/syswow64 2> /dev/null | wc -l) files"
key='HKLM\Software\Wow6432Node\Blizzard Entertainment\Starcraft Shareware'
if [ -d /boot/system/non-packaged/data/wine-games/SC ]; then
	wine reg add "$key" /v InstallPath /d 'D:\system\non-packaged\data\wine-games\SC' /f > /dev/null 2>&1
	wine reg add "$key" /v Program /d 'D:\system\non-packaged\data\wine-games\SC\Starcraft.exe' /f > /dev/null 2>&1
	wine reg add "$key" /v StarCD /d 'D:\system\non-packaged\data\wine-games\SCCD' /f > /dev/null 2>&1
	say "starcraft: registry keys set"
fi
wineserver -w
notify --type information --group "Test image" --title "Ready" \
	"Wine is set up. Everything is in the Test Apps folder on the Desktop." > /dev/null 2>&1
mv /boot/home/config/settings/boot/UserBootscript /boot/home/config/settings/boot/UserBootscript.done
sync
say end

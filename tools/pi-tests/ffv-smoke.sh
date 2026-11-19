#!/bin/sh
# ffv-smoke.sh [URL] — Firefox smoke test for a test build (docs/design/firefox-video-overlay.md §9.2): the
# installed Firefox opens URL (default https://www.haiku-os.org) in a fresh profile, waits SMOKE_WAIT s (default
# 45; take an HDMI snapshot meanwhile: the host prints when), quits with `hey Firefox quit` and reports whether
# every Firefox team ended by itself, plus the debugger entries in the syslog meanwhile. A clip is played with
# ffv0.sh. Lines "FFS ...".
url=${1:-https://www.haiku-os.org}
dir=$(cd "$(dirname "$0")" && pwd)
ffx=${FFX:-/boot/system/apps/Firefox/Firefox}
profile=$dir/ffs-profile
say() { echo "FFS $*"; }
rm -rf "$profile"
mkdir -p "$profile"
cat > "$profile/user.js" << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
PREFS
dbg0=$(grep -a -c "entered the debugger" /var/log/syslog)
say "package: $(ls /boot/system/packages | grep -a '^firefox-')"
say "libxul: $(ls -l /boot/system/apps/Firefox/lib/libxul.so | awk '{ print $5 }') bytes"
MOZ_CRASHREPORTER_DISABLE=1 $ffx --no-remote --profile "$profile" "$url" > "$dir/ffs.log" 2>&1 &
say "started $url, snapshot window open for ${SMOKE_WAIT:-45} s"
sleep "${SMOKE_WAIT:-45}"
say "teams before quit: $(ps | awk '$1 ~ /Firefox$/' | wc -l)"
hey Firefox quit > /dev/null 2>&1
n=0
while [ $n -lt 20 ] && ps | awk '$1 ~ /Firefox$/ { f = 1 } END { exit !f }'; do sleep 1; n=$((n + 1)); done
left=$(ps | awk '$1 ~ /Firefox$/' | wc -l)
say "quit: $left Firefox teams left after ${n} s"
for t in $(ps | awk '$1 ~ /Firefox$/ { print $(NF-3) }'); do kill -9 "$t" 2> /dev/null; done
dbg1=$(grep -a -c "entered the debugger" /var/log/syslog)
say "debugger entries: $((dbg1 - dbg0))"
say end

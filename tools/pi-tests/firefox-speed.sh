#!/bin/sh
# firefox-speed.sh — a UserBootscript timing Firefox (the package in the regular image,
# /boot/system/apps/Firefox) on the Pi: where does a page's time go, first start or every start?
# Headless screenshots, one profile: a local page three times, then https://www.haiku-os.org/
# twice, each run timed; and what the first run left behind (the profile's size, a fontconfig
# cache). Serial console lines: "FFS "; per run "FFS <name> <seconds> s <bytes> bytes", "FFS end".
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --bootscript tools/pi-tests/firefox-speed.sh --out artifacts/images/haiku-pi4-ffs.img
sleep 20
out=/dev/dprintf
say() { echo "FFS $*" > $out; }
ffx=/boot/system/apps/Firefox/Firefox
profile=/boot/home/ffx-profile
[ -x $ffx ] || { say "no $ffx"; say end; exit 0; }
mkdir -p $profile
cat > $profile/user.js << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
PREFS
export MOZ_CRASHREPORTER_DISABLE=1

ffx_kill() {
	for t in $(ps | grep -a "$ffx" | grep -a -v grep | awk '{print $2}'); do
		kill -9 $t 2> /dev/null
	done
}

cat > /tmp/page.html << 'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>t</title></head>
<body style="font-family: sans-serif"><h1>Firefox speed</h1><p>Text <b>bold</b> <i>italic</i></p>
<script>document.body.appendChild(document.createTextNode(navigator.userAgent));</script></body></html>
EOF

# run NAME URL: one headless screenshot, timed in milliseconds
run() {
	rm -f /tmp/shot.png
	t0=$(date +%s%N 2> /dev/null)
	timeout -s KILL 300 $ffx --headless --no-remote --profile $profile --screenshot /tmp/shot.png "$2" \
		> /tmp/ffs-$1.txt 2>&1
	status=$?
	t1=$(date +%s%N 2> /dev/null)
	ffx_kill
	ms=$(( (t1 - t0) / 1000000 ))
	say "$1 $((ms / 1000)).$(printf %03d $((ms % 1000))) s $(ls -l /tmp/shot.png 2> /dev/null | awk '{print $5}') bytes, exit $status"
}

fc() { du -sk /boot/home/config/cache/fontconfig /boot/system/cache/fontconfig 2> /dev/null | tr '\n' ' '; }
say "before: fontconfig cache: $(fc)"
run local-1 file:///tmp/page.html
say "after first run: profile $(du -sk $profile | cut -f1) KiB, fontconfig cache: $(fc)"
run local-2 file:///tmp/page.html
run local-3 file:///tmp/page.html
# the network (DHCP, DNS, the clock for HTTPS): wait for the site to answer
waited=0
while [ $waited -le 120 ]; do
	code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://www.haiku-os.org/ 2> /dev/null)
	[ "$code" = 200 ] && break
	sleep 10
	waited=$((waited + 10))
done
say "net: http $code after $waited s"
run remote-1 https://www.haiku-os.org/
run remote-2 https://www.haiku-os.org/
tail -n 5 /tmp/ffs-local-1.txt | cut -c1-160 | while IFS= read -r l; do say "local-1 says: $l"; done
say end

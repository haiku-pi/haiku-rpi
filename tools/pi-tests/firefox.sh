#!/bin/sh
# firefox.sh — a UserBootscript for Firefox (scripts/build-firefox.sh): the browser from
# artifacts/firefox/non-packaged (scripts/mkimage-pi4.sh --add-tree) on the Pi.
#   version      Firefox --version: the binary starts and loads libxul
#   shot-remote  --headless --screenshot of https://www.haiku-os.org/ (the boot's DHCP/DNS; the
#                network is not touched here)
#   shot-local   the same for a local file:// page (no network needed)
#   window       Firefox opens the local page in a window, for the HDMI frames (and a desktop
#                screenshot, /boot/home/ffx-window.png, by Haiku's screenshot tool); killed after 150 s
# Each step is time-bounded; Firefox's stdout/stderr lines are echoed. Serial console lines: "FFX ";
# per step "FFX <name> PASS ..." or "FFX <name> FAIL ..." (shot-remote: INCONCLUSIVE when the site did
# not answer curl with HTTP 200); then "FFX summary: N failed", "FFX end".
# A crash also shows as "debug_server:"/"DEBUGGER:" lines (the crashed team waits in the debugger,
# hence the KILL timeouts and the kill of every Firefox team after each step).
sleep 20
out=/dev/dprintf
say() { echo "FFX $*" > $out; }
dir=/boot/system/non-packaged/apps/Firefox
ffx=$dir/Firefox
profile=/boot/home/ffx-profile
cd /tmp || exit 1
fails=0
# the headless runs and the window share one profile (made on the first run); no first-run
# pages (privacy notice, welcome) and no default-browser question
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

# every Firefox team (the parent, content and utility processes)
ffx_kill() {
	for t in $(ps | grep -a "$ffx" | grep -a -v grep | awk '{print $2}'); do
		kill -9 $t 2> /dev/null
	done
}

# echo FILE's last N lines with a prefix
show() { tail -n $3 "$2" | while IFS= read -r line; do say "$1: $line"; done; }

# shot NAME URL PNG SECS: a headless screenshot, PASS when PNG exists and is not empty
shot() {
	name=$1 url=$2 png=$3 secs=$4
	rm -f $png
	t0=$(date +%s)
	say "$name: $url (limit $secs s)"
	timeout -s KILL $secs $ffx --headless --no-remote --profile $profile \
		--screenshot $png $url > /tmp/ffx-$name.txt 2>&1
	status=$?
	t=$(( $(date +%s) - t0 ))
	ffx_kill
	show $name /tmp/ffx-$name.txt 15
	if [ -s $png ] && [ -n "$inconclusive" ]; then
		say "$name INCONCLUSIVE ($inconclusive): exit $status, $(ls -l $png | awk '{print $5}') bytes in $t s (likely the error page)"
	elif [ -s $png ]; then
		say "$name PASS exit $status, $(ls -l $png | awk '{print $5}') bytes in $t s"
	else
		say "$name FAIL exit $status after $t s, no $png"
		fails=$((fails + 1))
	fi
}

say "start: $(uname -a)"
say "date: $(date)"
say "tree: $(ls $dir | tr '\n' ' ')"
say "lib: $(ls $dir/lib | tr '\n' ' ')"
say "omni.ja: $(ls -l $dir/omni.ja $dir/browser/omni.ja 2>&1 | awk '{print $5}' | tr '\n' ' ')"

t0=$(date +%s)
timeout -s KILL 120 $ffx --version > /tmp/ffx-version.txt 2>&1
status=$?
show version /tmp/ffx-version.txt 10
if [ $status -eq 0 ] && grep -q 'Firefox 157' /tmp/ffx-version.txt; then
	say "version PASS in $(( $(date +%s) - t0 )) s"
else
	say "version FAIL exit $status"
	fails=$((fails + 1))
fi
ffx_kill

cat > /tmp/ffx-test.html << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Firefox on Haiku arm64</title>
<style>
body { font-family: sans-serif; background: #f4f4f8; margin: 2em; }
h1 { color: #1a4a8a; }
.box { display: inline-block; width: 120px; height: 80px; margin: 6px; border-radius: 8px; }
</style></head>
<body>
<h1>Firefox 157 on Haiku arm64 (Raspberry Pi 4)</h1>
<p id="js">JavaScript: not run</p>
<div class="box" style="background:#d33"></div><div class="box" style="background:#3a3"></div>
<div class="box" style="background:#33d"></div><div class="box" style="background:#fc0"></div>
<p>Fonts: <b>bold</b> <i>italic</i> <code>monospace</code> &mdash; Unicode: äöü ñ € &#x2713;</p>
<canvas id="c" width="300" height="80"></canvas>
<script>
document.getElementById("js").textContent = "JavaScript: " + navigator.userAgent;
var g = document.getElementById("c").getContext("2d");
var grad = g.createLinearGradient(0, 0, 300, 0);
grad.addColorStop(0, "#f60"); grad.addColorStop(1, "#06f");
g.fillStyle = grad; g.fillRect(0, 0, 300, 80);
</script>
</body></html>
EOF

# the first run makes the profile: allow it longer
# an unreachable site still gives a screenshot (of Firefox's error page): curl tells which it is
# The boot's DHCP, DNS and NTP (HTTPS needs the clock) may still be on their way: wait up to
# 120 s for the site to answer. An unreachable site still gives a screenshot (of Firefox's error
# page), so without an HTTP 200 the shot is INCONCLUSIVE, not PASS.
code=000
waited=0
while [ $waited -le 120 ]; do
	code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://www.haiku-os.org/ 2> /dev/null)
	[ -n "$code" ] || code=000
	say "net: curl http $code after $waited s"
	[ "$code" = 200 ] && break
	sleep 10
	waited=$((waited + 10))
done
inconclusive=""
[ "$code" = 200 ] || inconclusive="net: http $code"
shot shot-remote https://www.haiku-os.org/ /boot/home/ffx.png 420
inconclusive=""
shot shot-local file:///tmp/ffx-test.html /boot/home/ffx-local.png 300

# a window on the desktop for the HDMI frames
t0=$(date +%s)
$ffx --no-remote --profile $profile file:///tmp/ffx-test.html > /tmp/ffx-window.txt 2>&1 &
waited=0
while [ $waited -lt 150 ]; do
	sleep 10
	waited=$((waited + 10))
	say "window: ${waited} s, $(ps | grep -a "$ffx" | grep -a -v grep | wc -l) Firefox team(s)"
	# the desktop as Haiku's screenshot tool sees it (besides the HDMI frames)
	if [ $waited -eq 90 ]; then
		screenshot -s /boot/home/ffx-window.png > /dev/null 2>&1
		say "window: desktop screenshot $(ls -l /boot/home/ffx-window.png 2>&1 | awk '{print $5}') bytes"
	fi
done
if ps | grep -a "$ffx" | grep -a -v grep > /dev/null; then
	say "window PASS still running after $waited s"
else
	say "window FAIL exited within $waited s"
	fails=$((fails + 1))
fi
ffx_kill
show window /tmp/ffx-window.txt 15
say "summary: $fails failed"
say end

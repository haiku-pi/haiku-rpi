#!/bin/sh
# firefox-video.sh — a UserBootscript: Firefox (the package in the regular image) plays the web test
# clips (scripts/make-web-video-clips.sh; mkimage-pi4.sh --add-tree artifacts/media-tests/web/non-packaged)
# one after the other in a window, muted, from a local page, and reports for each: its size, how far it
# played in how long, and the frames decoded and dropped (getVideoPlaybackQuality), on stdout
# (devtools.console.stdout.content); MOZ_LOG names the decoder module Firefox picked. HDMI frames show it.
# Serial console lines: "FFV "; per clip "FFV ... <clip>: WxH t=... frames N dropped M", "FFV end".
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --add-tree artifacts/media-tests/web/non-packaged \
#       --bootscript tools/pi-tests/firefox-video.sh --out artifacts/images/haiku-pi4-ffv.img
sleep 20
out=/dev/dprintf
say() { echo "FFV $*" > $out; }
ffx=/boot/system/apps/Firefox/Firefox
profile=/boot/home/ffx-profile
clips=/boot/system/non-packaged/data/web-video
[ -x $ffx ] || { say "no $ffx"; say end; exit 0; }
mkdir -p $profile
cat > $profile/user.js << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
user_pref("media.autoplay.default", 0);
PREFS
export MOZ_CRASHREPORTER_DISABLE=1

cat > /tmp/video.html << EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>video</title></head>
<body style="margin:0;background:#000"><video id="v" width="1280" height="720" muted playsinline></video>
<script>
function p(s) { console.log("VIDEO " + s); }
const clips = ["h264-720p.mp4", "vp9-720p.webm", "av1-720p.webm", "hevc-720p.mp4", "h264-1080p.mp4"];
let i = 0, token = 0;
function report(c, t0) {
  const v = document.getElementById("v"), q = v.getVideoPlaybackQuality();
  p(c + ": " + v.videoWidth + "x" + v.videoHeight + " t=" + v.currentTime.toFixed(1) + " s of "
    + (v.duration || 0).toFixed(1) + " in " + ((performance.now() - t0) / 1000).toFixed(1) + " s, frames "
    + q.totalVideoFrames + " dropped " + q.droppedVideoFrames);
}
function next() {
  if (i >= clips.length) { p("done"); return; }
  const c = clips[i++], v = document.getElementById("v"), mine = ++token, t0 = performance.now();
  const finish = () => { if (mine !== token) return; token++; report(c, t0); next(); };
  v.onerror = () => { if (mine !== token) return; token++;
    p(c + ": error " + (v.error ? v.error.code + " " + v.error.message : "?")); next(); };
  v.onended = finish;
  v.src = "file://$clips/" + c;
  v.play().catch(e => p(c + ": play() " + e));
  setTimeout(finish, 16000);
}
next();
</script></body></html>
EOF

say "clips: $(ls $clips | tr '\n' ' ')"
MOZ_LOG="PlatformDecoderModule:4" $ffx --no-remote --profile $profile file:///tmp/video.html \
	> /tmp/ffv.txt 2>&1 &
waited=0
while [ $waited -lt 150 ]; do
	sleep 5
	waited=$((waited + 5))
	grep -a -q "VIDEO done" /tmp/ffv.txt && break
done
say "waited $waited s"
grep -a "VIDEO" /tmp/ffv.txt | cut -c1-200 | while IFS= read -r l; do say "$l"; done
# the decoder modules' messages, counted (the end of each: the C++ signature before it is long)
grep -a -i -E "decoder|ffmpeg|ffvpx|agnostic|PDM" /tmp/ffv.txt | grep -a -v VIDEO \
	| sed -e 's/^\[[^]]*\]: //' -e 's/^.*) //' | cut -c1-200 | sort | uniq -c | sort -rn \
	| head -n 15 | while IFS= read -r l; do say "log: $l"; done
for t in $(ps | grep -a "$ffx" | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
sync
say end

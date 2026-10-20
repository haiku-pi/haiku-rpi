#!/bin/sh
# firefox-features.sh — a UserBootscript probing what Firefox (the package in the regular image) can
# do on the Pi beyond rendering pages: WebGL (a context, its renderer, a cleared and read back pixel)
# and video (canPlayType for H.264, HEVC, VP8, VP9, AV1, Theora in their containers), from a local
# page whose console.log lines Firefox prints on stdout (devtools.console.stdout.content), headless.
# Serial console lines: "FFF "; the page's "PROBE ..." lines, then "FFF end".
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --bootscript tools/pi-tests/firefox-features.sh --out artifacts/images/haiku-pi4-fff.img
sleep 20
FFF_PREFS="${FFF_PREFS:-}"
out=/dev/dprintf
say() { echo "FFF $*" > $out; }
ffx=/boot/system/apps/Firefox/Firefox
profile=/boot/home/ffx-profile
[ -x $ffx ] || { say "no $ffx"; say end; exit 0; }
mkdir -p $profile
cat > $profile/user.js << 'PREFS'
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("devtools.console.stdout.content", true);
PREFS
# FFF_PREFS: further prefs for this run (a boot script gets no environment: edit here)
for pref in $FFF_PREFS; do echo "user_pref(\"${pref%%=*}\", ${pref#*=});" >> $profile/user.js; done
export MOZ_CRASHREPORTER_DISABLE=1

cat > /tmp/probe.html << 'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>probe</title></head><body>
<canvas id="c" width="64" height="64"></canvas>
<script>
function p(s) { console.log("PROBE " + s); }
for (const kind of ["webgl2", "webgl"]) {
  try {
    const canvas = document.createElement("canvas");
    let why = "";
    canvas.addEventListener("webglcontextcreationerror", e => { why = e.statusMessage; });
    const gl = canvas.getContext(kind);
    if (!gl) { p(kind + ": no context: " + why); continue; }
    const dbg = gl.getExtension("WEBGL_debug_renderer_info");
    p(kind + ": " + gl.getParameter(gl.VERSION) + " | " +
      (dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) + " / " + gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL)
           : gl.getParameter(gl.RENDERER)));
    gl.clearColor(0.2, 0.4, 0.8, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const px = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    p(kind + ": clear color read back " + Array.from(px).join(","));
  } catch (e) { p(kind + ": error " + e); }
}
const v = document.createElement("video");
for (const t of ['video/mp4; codecs="avc1.42E01E"', 'video/mp4; codecs="hvc1.1.6.L93.B0"',
    'video/webm; codecs="vp8"', 'video/webm; codecs="vp9"', 'video/mp4; codecs="av01.0.05M.08"',
    'video/ogg; codecs="theora"', 'audio/mpeg', 'audio/ogg; codecs="vorbis"', 'audio/webm; codecs="opus"']) {
  p("canPlayType " + t + " = '" + v.canPlayType(t) + "'");
}
p("hardwareConcurrency " + navigator.hardwareConcurrency + ", devicePixelRatio " + devicePixelRatio);
p("done");
</script></body></html>
EOF

timeout -s KILL 200 $ffx --headless --no-remote --profile $profile --screenshot /tmp/probe.png \
	file:///tmp/probe.html > /tmp/fff.txt 2>&1
say "exit $?"
grep -a "PROBE" /tmp/fff.txt | cut -c1-200 | while IFS= read -r l; do say "$l"; done
grep -a -i -E "webgl|glcontext|egl|failed|error" /tmp/fff.txt | grep -a -v PROBE | head -n 12 | cut -c1-200 \
	| while IFS= read -r l; do say "log: $l"; done
for t in $(ps | grep -a "$ffx" | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
say end

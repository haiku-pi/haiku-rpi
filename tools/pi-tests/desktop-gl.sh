#!/bin/sh
# desktop-gl.sh — run over ssh in a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh): which desktop OpenGL
# versions and profiles the installed Mesa gives (docs/design/desktop-gl.md), what OpenGL 3.2/3.3 adds rendered
# and read back, and the regression checks of the GL stack.
#
#   sh desktop-gl.sh DIR [LABEL]
#
# DIR: where glinfo, glcore and glview-core are (tools/gl-tests, copied over; the image's gltri, glview,
# glview-es and vktest are used from its PATH). Environment (MESA_EXTENSION_OVERRIDE, MESA_GL_VERSION_OVERRIDE...)
# is passed on. Output lines start with "DGL "; each program's own lines follow, its log in /tmp/dgl-LABEL-*.txt.
dir=$1 label=${2:-run}
[ -x "$dir/glinfo" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
export PATH=$dir:/boot/system/non-packaged/bin:$PATH
fails=0
run() {
	name=$1
	shift
	"$@" > /tmp/dgl-$label-$name.txt 2>&1
	status=$?
	echo "DGL $label $name: status $status"
	[ $status = 0 ] || fails=$((fails + 1))
}
echo "DGL $label mesa: $(pkgman search -i -D mesa 2>/dev/null | grep -o 'mesa  *[^ ]*' | head -n 1)"
for v in MESA_EXTENSION_OVERRIDE MESA_GL_VERSION_OVERRIDE MESA_GLSL_VERSION_OVERRIDE; do
	eval value=\${$v:-}
	[ -n "$value" ] && echo "DGL $label env: $v=$value"
done
run glinfo glinfo
grep -E '^GLI (egl|[a-z0-9]+:|  version|  glsl|  profile|  gate)' /tmp/dgl-$label-glinfo.txt
run glcore glcore -v
grep -E '^GLC ' /tmp/dgl-$label-glcore.txt
run glview-core glview-core -s 3
grep -E '^GLK ' /tmp/dgl-$label-glview-core.txt
run glview glview -s 3
grep -E '^GLW (renderer|PASS|FAIL)' /tmp/dgl-$label-glview.txt
run glview-es glview-es -s 3
grep -E '^GLE (version|PASS|FAIL)' /tmp/dgl-$label-glview-es.txt
run gltri gltri
grep -E '^GLT (version|gl-context version|PASS|FAIL)' /tmp/dgl-$label-gltri.txt
run vktest vktest
tail -n 1 /tmp/dgl-$label-vktest.txt
echo "DGL $label done: $fails programs with a non-zero status"

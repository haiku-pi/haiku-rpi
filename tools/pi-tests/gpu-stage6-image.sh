#!/usr/bin/env bash
# gpu-stage6-image.sh — the GPU stage 6 test images (docs/design/gpu-stage6.md §8), from a release image
# and no image build:
#
#   tools/pi-tests/gpu-stage6-image.sh --stage
#       collect the stage6 binaries into artifacts/gpu-stage6/ (stripped where they are libraries)
#   tools/pi-tests/gpu-stage6-image.sh BASE.img OUT.img a|b|c
#       a: BASE + the tests, Mesa and libGL of the stage6 branches; the packaged display driver,
#          accelerant and app_server (no overlays: GL presents through the window, as in stage 5)
#       b: a + the stage6 display driver and accelerant (the packaged ones hidden by a BlockedEntries
#          setting) and app_server (started instead of the packaged one by a user_launch override)
#       c: b + the driver setting overlay_above_desktop (overlays above an opaque desktop, no keying;
#          home/config/settings/kernel/drivers: the only directory the boot loader reads them from)
#
# Build directories (override with the environment): HAIKU_GEN (default sources/haiku-stage6/
# generated.arm64), STAGE6_BUILD (artifacts/stage6/build: mesa/, libglvnd/, gl-tests/), the overlaytest
# bitmapcheck and sandprobe binaries in artifacts/stage6/ (build lines in their sources). The bootscript is tools/pi-tests/gpu-stage6.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
g="$root/artifacts/gpu-stage6"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"

if [ "${1:-}" = --stage ]; then
	gen="${HAIKU_GEN:-$root/sources/haiku-stage6/generated.arm64}"
	objects="$gen/objects/haiku/arm64/release"
	build="${STAGE6_BUILD:-$root/artifacts/stage6/build}"
	mkdir -p "$g"
	cp "$objects/add-ons/kernel/drivers/graphics/bcm2711_display/bcm2711_display" "$g/"
	cp "$objects/add-ons/accelerants/bcm2711_display/bcm2711_display.accelerant" "$g/"
	cp "$objects/servers/app/app_server" "$g/"
	cp -L "$build/mesa/src/egl/libEGL_mesa.so.0" "$g/libEGL_mesa.so.0"
	cp -L "$build/libglvnd/src/HGL/libGL.so.1" "$g/libGL.so.1"
	"$tools-strip" --strip-unneeded "$g/libEGL_mesa.so.0" "$g/libGL.so.1"
	for b in glflip glview present-bench; do
		cp "$build/gl-tests/$b" "$g/$b"
		"$tools-strip" "$g/$b"
	done
	cp "$root/artifacts/stage6/overlaytest" "$root/artifacts/stage6/bitmapcheck" \
		"$root/artifacts/stage6/sandprobe" "$g/"
	cat > "$g/50_mesa.json" <<-'JSON'
	{
	    "file_format_version" : "1.0.0",
	    "ICD" : {
	        "library_path" : "/boot/home/stage6/egl/libEGL_mesa.so.0"
	    }
	}
	JSON
	printf 'Package haiku {\n\tBlockedEntries {\n\t\tadd-ons/kernel/drivers/dev/graphics/bcm2711_display\n\t\tadd-ons/kernel/drivers/bin/bcm2711_display\n\t\tadd-ons/accelerants/bcm2711_display.accelerant\n\t}\n}\n' \
		> "$g/packages"
	printf 'service x-vnd.Haiku-app_server {\n\tlaunch /boot/system/non-packaged/servers/app_server\n}\n' \
		> "$g/app_server.launch"
	printf 'overlay_above_desktop true\n' > "$g/bcm2711_display.above"
	{
		echo "# staged $(date -u +%Y-%m-%dT%H:%MZ)"
		for r in haiku-stage6 mesa-stage6 libglvnd-stage6; do
			printf '%s %s\n' "$r" "$(git -C "$root/sources/$r" describe --always --dirty)"
		done
	} > "$g/versions.txt"
	ls -l "$g"
	exit 0
fi

[ $# = 3 ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
base="$1" out="$2" variant="$3"
s=/boot/home/stage6
files=(
	"$g/glflip:$s/glflip"
	"$g/glview:$s/glview"
	"$g/present-bench:$s/present-bench"
	"$g/overlaytest:$s/overlaytest"
	"$g/bitmapcheck:$s/bitmapcheck"
	"$g/sandprobe:$s/sandprobe"
	"$g/libGL.so.1:$s/libgl/libGL.so.1"
	"$g/libEGL_mesa.so.0:$s/egl/libEGL_mesa.so.0"
	"$g/50_mesa.json:$s/egl/50_mesa.json"
	"$g/versions.txt:$s/versions.txt"
	"$root/tools/pi-tests/gpu-stage6.sh:/boot/home/config/settings/boot/UserBootscript"
)
case "$variant" in
a) ;;
b|c)
	np=/boot/system/non-packaged
	files+=(
		"$g/bcm2711_display:$np/add-ons/kernel/drivers/dev/graphics/bcm2711_display"
		"$g/bcm2711_display.accelerant:$np/add-ons/accelerants/bcm2711_display.accelerant"
		"$g/packages:/boot/system/settings/packages"
		"$g/app_server:$np/servers/app_server"
		"$g/app_server.launch:/boot/system/settings/user_launch/app_server"
	)
	[ "$variant" = c ] && files+=("$g/bcm2711_display.above:/boot/home/config/settings/kernel/drivers/bcm2711_display")
	;;
*) echo "gpu-stage6-image: variant a, b or c" >&2; exit 2 ;;
esac
"$root/scripts/image-add.sh" "$base" "$out" "${files[@]}"

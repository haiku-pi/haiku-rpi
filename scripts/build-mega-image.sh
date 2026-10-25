#!/usr/bin/env bash
# build-mega-image.sh — a "mega" SD image for testing everything this port covers, built locally and never
# published: the current sources (Haiku, the GL stack, the kernel), the OpenGL and Vulkan stack, OpenArena
# and SuperTuxKart, Firefox and WebPositive, Wine (x86 and x86-64, Wine Mono), Photocraft, glmark2, the Quakes
# with their shareware/demo data, Windows programs and game demos, and a "Test Apps" folder on the Desktop
# that starts each one with a double-click. Game data and Windows programs are copyrighted: they are not in
# this repository or in any release; this script downloads them from their publishers' (or the Internet
# Archive's) public locations into your own cache (tools/mega/assets.txt: URL and SHA-256 of each), for an
# image you build and use yourself.
#
#   scripts/build-mega-image.sh [--out IMG] [--size MB] [--no-build] [--cache DIR]
#
#   --out IMG    default artifacts/images/haiku-pi4-mega.img
#   --size MB    the image's size (default 16000: a 32 GB card or larger; the content takes ~9 GB)
#   --no-build   use the jam build output as it is (sources/haiku/generated.arm64/haiku-mmc.image, built
#                with -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1)
#   --cache DIR  downloads (default artifacts/mega-cache)
#
# What it needs from this tree (it builds what is missing where a script exists):
#   packages     artifacts/packages/*.hpkg or the download folder of the Haiku build, else our published
#                repository (https://haiku-pi.github.io/packages/arm64): wine wine_data wine_directx
#                wine_x86 wine_x86_64 wine_mono wayland wayland_server libxkbcommon xkeyboard_config
#                glmark2 photocraft
#   the Quakes   artifacts/games/non-packaged (scripts/build-games.sh; its data: tools/mega/assets.txt)
#   GL tools     artifacts/gl-stack/non-packaged/bin (scripts/build-gl-stack.sh): vkcube, glview
#   Windows      artifacts/wine-apps/tree, artifacts/wine-games/tree/data/wine-games (the programs and
#                the games' installed files; assets.txt says where each comes from)
#
# Then: write it to the card (scripts/pi-test.sh --flash IMG, or any SD writer) and boot. The first boot
# makes ~/Desktop/Test Apps and sets Wine up (~2 min, a notification says when it is done):
# tools/mega/first-boot.sh. See docs/MEGA-IMAGE.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/images/haiku-pi4-mega.img" size=16000 build=1 cache="$root/artifacts/mega-cache"
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$(realpath -m "$2")"; shift 2 ;;
	--size) size="$2"; shift 2 ;;
	--no-build) build=0; shift ;;
	--cache) cache="$(realpath -m "$2")"; shift 2 ;;
	-h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "mega: unknown option $1 (--help)" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
work="$root/artifacts/mega-work"
rm -rf "$work"
mkdir -p "$work/np/apps/TestApps" "$work/np/bin" "$work/np/data" "$cache"
say() { echo "mega: $*"; }

# 1. the system: the current sources, with the GL stack and the packaged games
if [ "$build" = 1 ]; then
	say "building Haiku (jam, -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1, $size MB)"
	PI_IMAGE_OUT="$work/jam.img" "$root/scripts/build.sh" -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1 \
		-sHAIKU_PI_IMAGE_SIZE="$size" @pi-mmc
	rm -f "$work/jam.img"	# build.sh's Pi image; this script makes its own from haiku-mmc.image
fi
[ -f "$gen/haiku-mmc.image" ] || { echo "mega: no $gen/haiku-mmc.image" >&2; exit 1; }

# 2. packages: the newest local build of each, else the published repository's
pkg_files=()
find_pkg() {	# NAME → path of its newest .hpkg
	local name="$1" f
	f=$(ls "$root"/artifacts/packages/"$name"-[0-9]*.hpkg "$gen"/download/"$name"-[0-9]*.hpkg 2> /dev/null \
		| awk -F/ '{print $NF "\t" $0}' | sort -V | tail -n 1 | cut -f2)
	if [ -z "$f" ]; then
		local remote
		remote=$(curl -fsSL "https://api.github.com/repos/haiku-pi/packages/contents/arm64/packages" \
			| grep -o "\"name\": \"$name-[0-9][^\"]*\.hpkg\"" | cut -d'"' -f4 | sort -V | tail -n 1)
		[ -n "$remote" ] || { echo "mega: package $name: not built here and not in the repository" >&2; return 1; }
		f="$cache/packages/$remote"
		[ -f "$f" ] || { mkdir -p "$cache/packages"; curl -fL -o "$f.part" \
			"https://haiku-pi.github.io/packages/arm64/packages/$remote" && mv "$f.part" "$f"; }
	fi
	echo "$f"
}
for name in wine wine_data wine_directx wine_x86 wine_x86_64 wine_mono wayland wayland_server libxkbcommon \
		xkeyboard_config glmark2 photocraft; do
	f=$(find_pkg "$name") || exit 1
	pkg_files+=("$f:/boot/system/packages/$(basename "$f")")
	say "package $(basename "$f")"
done

# 3. downloaded assets (game data, Windows programs) into the cache: tools/mega/assets.txt
fetch_assets() {
	local list="$root/tools/mega/assets.txt"
	[ -f "$list" ] || return 0
	grep -v '^#' "$list" | grep -v '^\s*$' | while IFS='|' read -r name url sha extract dest; do
		local f="$cache/dl/$name"
		mkdir -p "$cache/dl"
		if [ ! -f "$f" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$sha" ]; then
			say "downloading $name"
			curl -fL --retry 3 -o "$f.part" "$url" && mv "$f.part" "$f" \
				|| { echo "mega: $name: download failed ($url)" >&2; continue; }
		fi
		[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sha" ] || { echo "mega: $name: SHA-256 mismatch" >&2; continue; }
	done
}
fetch_assets

# 4. the Quakes (SDL2 + OpenGL/Vulkan, with their data)
if [ ! -d "$root/artifacts/games/non-packaged/apps" ]; then
	say "building the Quakes (scripts/build-games.sh)"
	"$root/scripts/build-games.sh" || echo "mega: the Quakes were not built; their launchers are left out" >&2
fi
[ -d "$root/artifacts/games/non-packaged" ] && cp -a "$root/artifacts/games/non-packaged/." "$work/np/"

# 5. GL/Vulkan test programs
for t in vkcube glview; do
	[ -x "$root/artifacts/gl-stack/non-packaged/bin/$t" ] && cp -a "$root/artifacts/gl-stack/non-packaged/bin/$t" "$work/np/bin/"
done

# 6. Windows programs and game demos (installed trees)
[ -d "$root/artifacts/wine-apps/tree" ] && cp -a "$root/artifacts/wine-apps/tree" "$work/np/data/windows-apps"
[ -d "$root/artifacts/wine-games/tree/data/wine-games" ] \
	&& cp -a "$root/artifacts/wine-games/tree/data/wine-games" "$work/np/data/wine-games"

# 7. the launchers of the entries whose program is in the image
cc="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=$root/artifacts/sysroot-arm64"
grep -v '^#' "$root/tools/mega/apps.txt" | grep -v '^\s*$' | while IFS='|' read -r title name command; do
	cmd="${command//\$NP//boot/system/non-packaged}"
	# the program's directory or file must be in the stage (packaged commands: wine, glmark2-es2, ...)
	need=$(echo "$cmd" | grep -o '/boot/system/non-packaged/[^ &;]*' | head -n 1 || true)
	if [ -n "$need" ] && [ ! -e "$work/np/${need#/boot/system/non-packaged/}" ]; then
		say "left out: $title (no ${need#/boot/system/non-packaged/})"
		continue
	fi
	esc=${cmd//\\/\\\\}; esc=${esc//\"/\\\"}
	$cc -O2 -DNAME="\"$name\"" -DCOMMAND="\"$esc\"" -o "$work/np/apps/TestApps/$title" "$root/tools/mega/launcher.c"
done
say "launchers: $(ls "$work/np/apps/TestApps" | wc -l)"

# 8. the image: Pi boot files + the stage, then the packages and the first-boot script's README
"$root/scripts/mkimage-pi4.sh" --in "$gen/haiku-mmc.image" --out "$work/base.img" --add-tree "$work/np" \
	--bootscript "$root/tools/mega/first-boot.sh"
cp "$root/tools/mega/README.txt" "$work/mega-README.txt"
"$root/scripts/image-add.sh" "$work/base.img" "$out" "${pkg_files[@]}" "$work/mega-README.txt:/boot/home/mega-README.txt"
rm -f "$work/base.img"
say "done: $out ($(du -h "$out" | cut -f1)); write it with: scripts/pi-test.sh --flash $out"

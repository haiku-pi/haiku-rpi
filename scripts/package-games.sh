#!/usr/bin/env bash
# package-games.sh — the free games as packages: their engines and data, as the staging trees have them
# (scripts/build-games.sh, scripts/build-q3.sh, scripts/build-stk.sh), each a self-contained directory in
# apps/ with a Deskbar entry (Applications menu).
#
#   scripts/package-games.sh [--revision N]      (default 1)
#
# Output: artifacts/packages/{openarena,supertuxkart}-<version>-<N>-arm64.hpkg
#   openarena     OpenArena 0.8.8 (GPL data) on ioquake3 (apps/OpenArena: the OpenArena launcher, ioquake3,
#                 baseoa); settings and saves in ~/config/settings/OpenArena
#   supertuxkart  SuperTuxKart 1.5 (apps/SuperTuxKart): SuperTuxKart (OpenGL 2.1, the legacy renderer,
#                 the faster one on the V3D) and SuperTuxKart-GLES (OpenGL ES 3, the shader renderer)
# The engines without free data (QuakeSpasm, vkQuake, Yamagi Quake II, ioquake3 for Quake III) are not
# packaged: their data cannot go in a package, and a packaged engine finds none in its read-only
# directory.
# Both are larger than GitHub's 100 MB file limit, so scripts/publish-repo.sh leaves them out; images
# get them with -sHAIKU_PI_GAMES=1 (tools/build/UserBuildConfig) from jam's download directory, where
# this script also copies them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	*) echo "package-games: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
games="$root/artifacts/games/non-packaged/apps"
stk="$root/artifacts/stk/non-packaged/apps/SuperTuxKart"
out="$root/artifacts/packages"
work="$out/build-games"
download="$gen/download"
[ -x "$games/OpenArena/ioquake3" ] || { echo "package-games: run scripts/build-games.sh first" >&2; exit 1; }
[ -x "$stk/SuperTuxKart" ] || { echo "package-games: run scripts/build-stk.sh first" >&2; exit 1; }
mkdir -p "$out"
rm -rf "$work"

# create NAME VERSION DIR — DIR/.PackageInfo must exist; the package also goes to jam's download directory
create() {
	local name="$1" version="$2" dir="$3"
	local file="$out/$name-$version-$revision-arm64.hpkg"
	rm -f "$out/$name"-*-arm64.hpkg "$download/$name"-*-arm64.hpkg
	"$pkgtool" create -q -C "$dir" -i "$dir/.PackageInfo" "$file"
	rm "$dir/.PackageInfo"
	cp "$file" "$download/"
	echo "package-games: $file ($(stat -c %s "$file") bytes)"
}
# deskbar DIR APP LAUNCHER — the Applications menu entry, as HaikuPorts' addAppDeskbarSymlink
deskbar() {
	mkdir -p "$1/data/deskbar/menu/Applications"
	ln -s "../../../../apps/$2/$3" "$1/data/deskbar/menu/Applications/$2"
}
# NAME VERSION SUMMARY DESCRIPTION LICENSES COPYRIGHTS REQUIRES (one item per line). The vendor is the
# HaikuPorts repository's: package_repo refuses a package of another vendor in it.
packageInfo() {
	cat <<-EOF
	name			$1
	version			$2-$revision
	architecture	arm64
	summary			"$3"
	description		"$4 Built for the Raspberry Pi 4 by the haiku-pi project."
	packager		"haiku-pi build farm <build@haiku-pi.invalid>"
	vendor			"Haiku Project"
	licenses		{ $5 }
	copyrights		{ $6 }
	provides {
		$1 = $2-$revision
	}
	requires {
	$7
	}
	EOF
}

# openarena: ioquake3 loads libGL at run time (mesa)
d="$work/openarena"
mkdir -p "$d/apps"
cp -a "$games/OpenArena" "$d/apps/"
deskbar "$d" OpenArena OpenArena
packageInfo openarena 0.8.8 "A free first-person shooter (Quake III Arena engine)" \
	"OpenArena: a free and open source deathmatch shooter on ioquake3, the maintained Quake III Arena engine, with its own maps, characters and weapons." \
	'"GNU GPL v2"' '"OpenArena team" "ioquake3 contributors" "id Software"' \
"	haiku
	lib:libSDL2_2.0
	mesa" > "$d/.PackageInfo"
create openarena 0.8.8 "$d"

# supertuxkart
d="$work/supertuxkart"
mkdir -p "$d/apps"
cp -a "$stk" "$d/apps/"
deskbar "$d" SuperTuxKart SuperTuxKart
packageInfo supertuxkart 1.5 "A free 3D kart racing game" \
	"SuperTuxKart: kart racing with Tux and friends, single races, grand prix and battles on 3D tracks. SuperTuxKart uses OpenGL 2.1 (the legacy renderer); SuperTuxKart-GLES the OpenGL ES 3 shader renderer. The code is GPL v3; the artwork is under its authors' licenses, mostly CC-BY-SA (data/CREDITS)." \
	'"GNU GPL v3"' '"SuperTuxKart Development Team"' \
"	haiku
	lib:libSDL2_2.0
	lib:libcurl
	lib:libvorbisfile
	lib:libsqlite3
	lib:libcrypto
	lib:libjpeg
	lib:libpng16
	lib:libz
	lib:libgcc_s
	lib:libstdc++
	mesa" > "$d/.PackageInfo"
create supertuxkart 1.5 "$d"
rm -rf "$work"

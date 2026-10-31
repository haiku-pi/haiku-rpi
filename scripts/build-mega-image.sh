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
#   Windows      artifacts/wine-apps/tree, artifacts/wine-games/tree/data/wine-games, else made from the
#                downloads: the programs, and the SimCity 3000, Fallout, Heroes III, Age of Empires II and
#                Unreal Tournament demos (unzip, 7z, unshield); Half-Life Uplink, StarCraft, Diablo II and
#                Warcraft III only from an existing installed tree
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
# the staging tree, the base image and the result take up to about twice the image's size at once (the old
# result is replaced); a full disk would only show up halfway through, as a failed copy
mkdir -p "$(dirname "$out")"
avail=$(df -m --output=avail "$(dirname "$out")" | tail -n 1)
old=0
[ -f "$out" ] && old=$(du -m "$out" | cut -f1)
if [ $((avail + old)) -lt $((size * 2)) ]; then
	echo "mega: needs about $((size * 2)) MB free next to $out, has $((avail + old)) MB" >&2
	exit 1
fi
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
		# a copy this tree already has (the 5th field: where it was first used): no download
		if [ ! -f "$f" ] && [ -f "$root/$dest" ] && [ "$extract" = copy ] \
				&& [ "$(sha256sum "$root/$dest" | cut -d' ' -f1)" = "$sha" ]; then
			ln "$root/$dest" "$f" 2> /dev/null || cp "$root/$dest" "$f"
		fi
		if [ ! -f "$f" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$sha" ]; then
			say "downloading $name"
			curl -fL --retry 3 -o "$f.part" "$url" && mv "$f.part" "$f" \
				|| { echo "mega: $name: download failed ($url)" >&2; continue; }
		fi
		[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sha" ] || { echo "mega: $name: SHA-256 mismatch" >&2; continue; }
	done
}
fetch_assets

dl="$cache/dl"
# the Quakes' data from the downloads: the shareware/demo releases' installers and archives
quake_data() {
	local q="$cache/quake-data" x="$cache/extract"
	if [ ! -f "$q/quake/id1/pak0.pak" ] && [ -f "$dl/quake1-shareware-pak0" ]; then
		rm -rf "$x/q1"; mkdir -p "$x/q1" "$q/quake/id1"
		(cd "$x/q1" && unzip -p "$dl/quake1-shareware-pak0" resource.1 > resource.1 \
			&& 7z e -y resource.1 ID1/PAK0.PAK > /dev/null && mv PAK0.PAK "$q/quake/id1/pak0.pak")
	fi
	if [ ! -f "$q/quake2/baseq2/pak0.pak" ] && [ -f "$dl/quake2-demo-pak0" ]; then
		mkdir -p "$q/quake2/baseq2"
		unzip -p "$dl/quake2-demo-pak0" Install/Data/baseq2/pak0.pak > "$q/quake2/baseq2/pak0.pak"
	fi
	if [ ! -f "$q/quake3/demoq3/pak0.pk3" ] && [ -f "$dl/quake3-demo-pak0" ]; then
		rm -rf "$x/q3"; mkdir -p "$x/q3" "$q/quake3/demoq3"
		(cd "$x/q3" && tail -n +165 "$dl/quake3-demo-pak0" > payload.tgz \
			&& tar xzof payload.tgz demoq3/pak0.pk3 && mv demoq3/pak0.pk3 "$q/quake3/demoq3/")
	fi
}

# 4. the Quakes (SDL2 + OpenGL/Vulkan, with their data)
if [ ! -d "$root/artifacts/games/non-packaged/apps" ]; then
	say "building the Quakes (scripts/build-games.sh)"
	quake_data
	QUAKE3_DATA="$cache/quake-data/quake3" "$root/scripts/build-games.sh" \
		--quake-data "$cache/quake-data/quake" --quake2-data "$cache/quake-data/quake2" \
		|| echo "mega: the Quakes were not built; their launchers are left out" >&2
fi
[ -d "$root/artifacts/games/non-packaged" ] && cp -a "$root/artifacts/games/non-packaged/." "$work/np/"

# 5. GL/Vulkan test programs
for t in vkcube glview; do
	[ -x "$root/artifacts/gl-stack/non-packaged/bin/$t" ] && cp -a "$root/artifacts/gl-stack/non-packaged/bin/$t" "$work/np/bin/"
done

# 6. Windows programs (from this tree's copies, else from the downloads) and game demos (installed trees)
if [ -d "$root/artifacts/wine-apps/tree" ]; then
	cp -a "$root/artifacts/wine-apps/tree" "$work/np/data/windows-apps"
else
	w="$work/np/data/windows-apps"
	mkdir -p "$w/putty" "$w/7z" "$w/sumatra" "$w/npp32" "$w/npp64"
	cp "$dl/putty32" "$w/putty/putty32.exe"; cp "$dl/putty64" "$w/putty/putty64.exe"
	cp "$dl/7zr" "$w/7z/7zr.exe"
	cp "$dl/sumatrapdf32" "$w/sumatra/Sumatra32.exe"; cp "$dl/sumatrapdf64" "$w/sumatra/Sumatra64.exe"
	unzip -q -o "$dl/notepadpp32" -d "$w/npp32"; unzip -q -o "$dl/notepadpp64" -d "$w/npp64"
	# a page for SumatraPDF to open
	python3 -I - "$w/sumatra/test.pdf" <<'PDF'
import sys
text = b"BT /F1 24 Tf 72 720 Td (Haiku on the Raspberry Pi 4: a test page) Tj ET"
objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
	b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
	b"<< /Length %d >>\nstream\n" % len(text) + text + b"\nendstream",
	b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out, offsets = b"%PDF-1.4\n", []
for i, o in enumerate(objs, 1):
	offsets.append(len(out)); out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1], "wb").write(out)
PDF
fi
if [ -d "$root/artifacts/wine-games/tree/data/wine-games" ]; then
	cp -a "$root/artifacts/wine-games/tree/data/wine-games" "$work/np/data/wine-games"
else
	# the demos that unpack without running their installers (byte-identical to the tested trees);
	# Half-Life Uplink (a Wise installer), the StarCraft shareware and the Diablo II and Warcraft III demos
	# (installed under Wine) need such a tree from an earlier install: their launchers are left out without one
	g="$work/np/data/wine-games"
	mkdir -p "$g"
	[ -f "$dl/simcity3000-demo" ] && unzip -q -o "$dl/simcity3000-demo" -d "$g"
	[ -f "$dl/fallout-demo" ] && unzip -q -o "$dl/fallout-demo" -d "$g"
	if [ -f "$dl/heroes3-demo" ] && command -v unshield > /dev/null; then
		rm -rf "$cache/extract/h3"; mkdir -p "$cache/extract/h3"
		7z x -y -o"$cache/extract/h3" "$dl/heroes3-demo" > /dev/null \
			&& unshield -d "$cache/extract/h3/out" x "$cache/extract/h3/Disk1/data1.cab" > /dev/null \
			&& mv "$cache/extract/h3/out/Program_Files" "$g/H3"
	fi
	# Age of Empires II: the zip holds the setup program, whose CAB resource is the game tree
	if [ -f "$dl/aoe2-demo" ]; then
		rm -rf "$cache/extract/aoe2"; mkdir -p "$cache/extract/aoe2"
		unzip -p "$dl/aoe2-demo" AoE2demo.exe > "$cache/extract/aoe2/AoE2demo.exe" \
			&& 7z x -y -o"$g/AOE2" "$cache/extract/aoe2/AoE2demo.exe" > /dev/null
	fi
	# Unreal Tournament: a zip archive in a setup program; set up as its first-run wizard would, with the OpenGL
	# renderer (Direct3D through wined3d is a third as fast) and without DirectDraw (with it the OpenGL renderer
	# crashes; first-boot.sh also trims the OpenGL extensions it sees)
	if [ -f "$dl/ut-demo" ]; then
		7z x -y -o"$g/UT" "$dl/ut-demo" > /dev/null 2>&1 || true	# a warning: the setup program's own bytes
		[ -f "$g/UT/System/UnrealTournament.ini" ] && sed -i 's/^FirstRun=.*/FirstRun=338/;
			s/^GameRenderDevice=.*/GameRenderDevice=OpenGLDrv.OpenGLRenderDevice/;
			s/^UseDirectDraw=.*/UseDirectDraw=False/' "$g/UT/System/UnrealTournament.ini"
	fi
fi

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

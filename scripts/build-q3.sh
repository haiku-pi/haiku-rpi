#!/usr/bin/env bash
# build-q3.sh — cross-build ioquake3 (the Quake III Arena engine; HaikuPorts' quake3 recipe is the old
# x86-only BeOS port, its openarena recipe the SDL 1.2 OpenArena engine fork) on this host and stage
# it for the Pi image with OpenArena's free data, and Quake III's own data when there is some
# (mkimage-pi4.sh --add-tree artifacts/games/non-packaged; scripts/build-games.sh calls this):
#
#   apps/OpenArena/   ioquake3 + OpenArena (launcher: com_basegame baseoa) + baseoa/*.pk3
#   apps/Quake3/      ioquake3 + Quake3 (launcher) + ioq3's game modules (cgame/qagame/ui .so) +
#                     <game>/pak0.pk3 — only with --quake3-data
#
#   scripts/build-q3.sh [--quake3-data DIR] [--no-openarena]
#       DIR/demoq3/pak0.pk3 (the Quake III demo) or DIR/baseq3/pak*.pk3 (retail): id's data is not
#       free and not in git (default: QUAKE3_DATA from local.conf or the environment; none: no Quake3)
#
#   ioquake3 1.36 (git 87a99d1, 2026-10-12; ioq3 has no release tags) its CMake build with
#                 tools/cmake/haiku-arm64.cmake, SDL2 2.32 from the sysroot (the libsdl2 package on
#                 the image; scripts/build-games.sh), OpenGL through SDL (Mesa's libGL on the image);
#                 the GL1 renderer (fixed function, GL 1.x — V3D's desktop GL is 2.1) built into the
#                 binary; ioq3's own zlib/libjpeg/libogg/libvorbis (no extra run-time libraries);
#                 no OpenAL (SDL audio), curl, VoIP/Opus or Mumble; patches/ioq3/*.patch (Haiku).
#                 arm64 has no QVM compiler in ioq3: OpenArena's QVMs run interpreted.
#   OpenArena 0.8.8  the release zip's baseoa/ (GPLv2 / free content), without pak2-players-mature.pk3
#                 (optional player models; nothing in the timedemo needs them); its timedemo
#                 demos/demo088-test1.dm_71 (protocol 71, ioq3's) is in pak6-patch088.pk3
#   Quake III     ioq3's baseq3 game code as native modules beside the data (the demo's 1999 QVMs are
#                 UI API 3 and ioq3 wants 6); started with vm_game/vm_cgame/vm_ui 0, sv_pure 0
#
# Build directory: artifacts/cross-ports/ioq3-<rev>/ (src/, build/, install/ with the unstripped
# binaries for addr2line), recreated each run. Downloads: artifacts/cross-ports/dl/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
quake3Data="${QUAKE3_DATA:-}"
openarena=1
while [ $# -gt 0 ]; do
	case "$1" in
	--quake3-data) quake3Data="$2"; shift 2 ;;
	--no-openarena) openarena=0; shift ;;
	*) echo "build-q3: unknown option $1" >&2; exit 2 ;;
	esac
done
q3game=""
if [ -n "$quake3Data" ]; then
	for g in baseq3 demoq3; do
		[ -f "$quake3Data/$g/pak0.pk3" ] && { q3game=$g; break; }
	done
	[ -n "$q3game" ] || { echo "build-q3: no $quake3Data/{baseq3,demoq3}/pak0.pk3" >&2; exit 2; }
fi

rev=87a99d18206e878a20289f05ac3c16005dcae5c3
sha256=8c0c2cdc2326a5f303afe09914b445609780f1ff9337fab5224afc33607bf720
oaVersion=0.8.8
# the HaikuPorts recipe's checksum; its sourceforge mirror URL now serves an HTML page
oaUrl="https://download.tuxfamily.org/openarena/rel/088/openarena-$oaVersion.zip"
oaSha256=5a8faf7f5b51f351b0a1618c06b6b98a5f1a6758f1d39818de2c87df2a0bac4a
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
sysroot="$root/artifacts/sysroot-arm64"
dl="$root/artifacts/cross-ports/dl"
work="$root/artifacts/cross-ports/ioq3-${rev:0:7}"
apps="$root/artifacts/games/non-packaged/apps"

[ -f "$sysroot/boot/system/non-packaged/lib/cmake/SDL2/SDL2Config.cmake" ] \
	|| { echo "build-q3: no SDL2 in the sysroot (scripts/build-games.sh builds it)" >&2; exit 1; }
for p in cmake ninja unzip; do
	command -v "$p" > /dev/null || { echo "build-q3: $p missing on this host" >&2; exit 1; }
done

# fetch FILE URL SHA256
fetch() {
	mkdir -p "$dl"
	[ -f "$dl/$1" ] || { curl -sSfL -o "$dl/$1.part" "$2" && mv "$dl/$1.part" "$dl/$1"; }
	echo "$3  $dl/$1" | sha256sum -c --quiet
}
fetch "ioq3-$rev.tar.gz" "https://github.com/ioquake/ioq3/archive/$rev.tar.gz" "$sha256"
[ "$openarena" = 1 ] && fetch "openarena-$oaVersion.zip" "$oaUrl" "$oaSha256"

rm -rf "$work"
mkdir -p "$work/unpack"
tar -xzf "$dl/ioq3-$rev.tar.gz" -C "$work/unpack"
mv "$work/unpack/ioq3-$rev" "$work/src"
rmdir "$work/unpack"
for p in "$root"/patches/ioq3/*.patch; do
	echo "build-q3: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done

cmake -S "$work/src" -B "$work/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
	-DCMAKE_BUILD_TYPE=Release -DPRODUCT_VERSION="1.36_g${rev:0:7}" \
	-DBUILD_SERVER=OFF -DBUILD_RENDERER_GL2=OFF -DUSE_RENDERER_DLOPEN=OFF \
	-DBUILD_GAME_LIBRARIES=ON -DBUILD_GAME_QVMS=OFF \
	-DUSE_OPENAL=OFF -DUSE_HTTP=OFF -DUSE_VOIP=OFF -DUSE_MUMBLE=OFF -DUSE_CODEC_OPUS=OFF \
	> "$work/configure.log" 2>&1 || { tail -n 30 "$work/configure.log" >&2; exit 1; }
# under the heavy-build guard, unless a caller already holds it (the lock is not re-entrant)
if [ "${HEAVY_BUILD_LOCKED:-0}" = 1 ]; then
	ninja -C "$work/build" -j "${HEAVY_BUILD_JOBS:-$(nproc)}" > "$work/build.log" 2>&1 || rc=$?
else
	"$root/scripts/heavy-build.sh" --mem-per-job 1 -- ninja -C "$work/build" -j '{JOBS}' \
		> "$work/build.log" 2>&1 || rc=$?
fi
[ "${rc:-0}" = 0 ] || { grep -E 'error|FAILED' "$work/build.log" | head -n 30 >&2; exit 1; }
echo "build-q3: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"

release="$work/build/Release"
mkdir -p "$work/install"
cp "$release/ioquake3" "$work/install/"
cp "$release"/baseq3/{cgame,qagame,ui}.so "$work/install/"
for f in "$work"/install/*; do
	if "$tools-readelf" -d "$f" | grep -q -E 'RPATH|RUNPATH'; then
		echo "build-q3: $f has a run path" >&2
		exit 1
	fi
done

# stage_engine APP LAUNCHER GAMEDIR LAUNCHER-ARGS: the engine and a launcher script that starts it on
# the app's data (from Tracker or a shell; arguments are passed on); the user's files (configuration,
# qconsole.log with +set logfile) go to ~/config/settings/<launcher>/<gamedir>/
stage_engine() {
	local app="$apps/$1"
	rm -rf "$app"
	mkdir -p "$app/$3"
	cp "$work/install/ioquake3" "$app/"
	"$tools-strip" "$app/ioquake3"
	cat > "$app/$2" <<EOF
#!/bin/sh
# $2: ioquake3 on $3 (scripts/build-q3.sh)
dir=\$(dirname "\$(realpath "\$0" 2> /dev/null || echo "\$0")")
exec "\$dir/ioquake3" +set fs_basepath "\$dir" +set fs_homepath "\${HOME:-/boot/home}/config/settings/$2" \\
	+set com_basegame $3${4:+ $4} "\$@"
EOF
	chmod 755 "$app/$2"
}

if [ "$openarena" = 1 ]; then
	stage_engine OpenArena OpenArena baseoa ""
	unzip -q -j "$dl/openarena-$oaVersion.zip" "openarena-$oaVersion/baseoa/*" \
		-x "*/pak2-players-mature.pk3" -d "$apps/OpenArena/baseoa"
	for f in COPYING CREDITS README readme_088.txt; do
		unzip -q -j "$dl/openarena-$oaVersion.zip" "openarena-$oaVersion/$f" -d "$apps/OpenArena"
	done
	unzip -l "$apps/OpenArena/baseoa/pak6-patch088.pk3" demos/demo088-test1.dm_71 > /dev/null \
		|| { echo "build-q3: OpenArena's timedemo demo088-test1 is missing" >&2; exit 1; }
	echo "build-q3: OpenArena $oaVersion staged in $apps/OpenArena ($(du -sh "$apps/OpenArena" | cut -f1))"
fi
if [ -n "$q3game" ]; then
	stage_engine Quake3 Quake3 "$q3game" "+set vm_game 0 +set vm_cgame 0 +set vm_ui 0 +set sv_pure 0"
	# the demo has one pak; retail baseq3 has pak0..pak8 (the point releases' patches)
	if [ "$q3game" = demoq3 ]; then
		cp "$quake3Data/demoq3/pak0.pk3" "$apps/Quake3/demoq3/"
	else
		cp "$quake3Data/baseq3"/pak[0-8].pk3 "$apps/Quake3/baseq3/"
	fi
	for m in cgame qagame ui; do
		cp "$work/install/$m.so" "$apps/Quake3/$q3game/"
		"$tools-strip" --strip-unneeded "$apps/Quake3/$q3game/$m.so"
	done
	echo "build-q3: Quake III ($q3game) staged in $apps/Quake3 ($(du -sh "$apps/Quake3" | cut -f1))"
fi

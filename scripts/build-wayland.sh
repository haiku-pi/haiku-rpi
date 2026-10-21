#!/usr/bin/env bash
# build-wayland.sh — cross-build the Wayland stack that Wine's Wayland driver (winewayland.drv) uses on
# Haiku: X547's libwayland fork, whose client library loads X547's in-process Wayland server
# (wayland-server-inproc.so, an add-on that implements the compositor with native Haiku windows on
# app_server), plus libxkbcommon/libxkbregistry and the XKB layout data. HaikuPorts-style packages
# (scripts/cross-port.sh, scripts/package-port.py), in dependency order, from the HaikuPorts recipes:
#
#   scanner             wayland-scanner for this host (from the wayland source, libraries off): the
#                       cross builds below and Wine's configure (WAYLAND_SCANNER=) generate their
#                       protocol code with it. artifacts/wayland-host/bin/wayland-scanner, not packaged
#   wayland             dev-libs/wayland 1.21.0~git (X547's fork), revision 5: libwayland-client,
#                       -server, -cursor, -egl, the arm64 wayland-scanner (+ wayland_devel), with
#                       patches/wayland (wl_display_dispatch_queue() blocks for the in-process server's
#                       events instead of returning at once)
#   wayland_protocols   dev-libs/wayland-protocols 1.49: protocol XML only (architecture any)
#   xkeyboard_config    x11-libs/xkeyboard-config 2.41: the XKB layout data (data/X11/xkb)
#   libxkbcommon        x11-libs/libxkbcommon 1.13.2: libxkbcommon + libxkbregistry, xkbcli (+ _devel)
#   wayland_server      dev-libs/wayland-server 0.1.20251004: wayland-server-inproc.so (no _devel, as
#                       the recipe), with patches/wayland_server (cross build: the sysroot's private
#                       headers, the host machine's architecture)
#
# The ports are built with the packaged prefix (/boot/system, the recipes' $dataDir, $includeDir,
# $libDir), not non-packaged: paths compiled in (libxkbcommon's XKB root /boot/system/data/X11/xkb,
# libwayland-cursor's icon directory) must be the packages' own. The arch-independent pkg-config files
# (wayland-protocols, xkeyboard-config) are in data/pkgconfig, in tools/meson/haiku-arm64.cross's path.
# The recipes' build options are repeated here; where one differs, the comment says why.
# Host tools: meson, ninja, bison (libxkbcommon), perl (xkeyboard-config), the host's expat headers
# (wayland-scanner). Output: artifacts/packages/*.hpkg, the packages extracted into the sysroot.
#
#   scripts/build-wayland.sh [STEP]          (start at STEP; the earlier ones must have run)
#   scripts/build-wayland.sh --only STEP     (just that step)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
cross="$root/scripts/cross-port.sh"
package="$root/scripts/package-port.py"
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
host="$root/artifacts/wayland-host"
export LD_LIBRARY_PATH="$gen/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

waylandRecipe="$ports/dev-libs/wayland/wayland-1.21.0~git.recipe"
protocolsRecipe="$ports/dev-libs/wayland-protocols/wayland_protocols-1.49.recipe"
xkbConfigRecipe="$ports/x11-libs/xkeyboard-config/xkeyboard_config-2.41.recipe"
xkbcommonRecipe="$ports/x11-libs/libxkbcommon/libxkbcommon-1.13.2.recipe"
serverRecipe="$ports/dev-libs/wayland-server/wayland_server-0.1.20251004.recipe"

# meson arguments of every cross build: the recipes' directories under the packaged prefix (the later
# --prefix wins over cross-port.sh's) and the host scanner for the native wayland-scanner dependency.
# (data/pkgconfig is in the cross file's search path. Not as -Dpkg_config_path: pkgconf prefixes the
# sysroot twice to a variable with ${pc_sysrootdir} when the .pc file's directory is not spelled as
# the sysroot is, and the cross file spells it through tools/meson/../..)
paths=(--prefix=/boot/system --datadir=data --includedir=develop/headers --libdir=lib
	--mandir=documentation/man "-Dbuild.pkg_config_path=$host/lib/pkgconfig")

# fail if a port's packaged files (stripped) name this checkout: a sysroot path compiled in or in a .pc file
no_build_paths() {
	local found
	found="$(grep -rlF "$root" "$root/artifacts/packages/build/$1" || true)"
	[ -z "$found" ] || { echo "build-wayland: $1: build paths in $found" >&2; exit 1; }
}

# wayland-scanner for this host, from the same source (the cross build checks its version): no
# libraries, no DTD validation (that needs libxml2 headers on the host; Wine and the ports only
# generate code)
step_scanner() {
	local archive
	archive="$("$root/scripts/haikuports-fetch.sh" "$waylandRecipe" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p')"
	rm -rf "$host"
	mkdir -p "$host/unpack"
	tar -xf "$archive" -C "$host/unpack"
	meson setup "$host/build" "$host/unpack"/wayland-* --prefix="$host" --libdir=lib \
		--buildtype=release -Dlibraries=false -Dtests=false -Ddocumentation=false \
		-Ddtd_validation=false > "$host/configure.log"
	ninja -C "$host/build" install > "$host/build.log"
	"$host/bin/wayland-scanner" --version
}

# the recipe's options, without tests (they run on the target); the aarch64 wayland-scanner of the
# runtime package is built too (cmd:wayland_scanner)
step_wayland() {
	"$cross" --patches "$root/patches/wayland" "$waylandRecipe" meson "${paths[@]}" -Ddocumentation=false \
		-Dtests=false -Dicon_directory=/boot/system/data/icons
	"$package" "$waylandRecipe" --system-prefix --revision 5 --requires lib:libexpat \
		--requires lib:libffi --devel-requires devel:libffi
	no_build_paths wayland
}

step_wayland_protocols() {
	"$cross" "$protocolsRecipe" meson "${paths[@]}" -Dtests=false
	"$package" "$protocolsRecipe" --system-prefix --architecture any
	no_build_paths wayland_protocols
}

# nls as the recipe (on): without msgfmt on the host meson skips the translations
step_xkeyboard_config() {
	"$cross" "$xkbConfigRecipe" meson "${paths[@]}"
	"$package" "$xkbConfigRecipe" --system-prefix
	no_build_paths xkeyboard_config
}

# the recipe's options; the XKB root given (the recipe's build has no xkeyboard-config.pc and falls back
# to $dataDir/X11/xkb, the same path); the libexec tools in lib/xkbcommon, as the recipe's
# --libexecdir=$libDir puts them. libxkbcommon compiles in xkeyboard-config.pc's xkb_base (its legacy
# root, which has no option), and pkgconf prefixes the sysroot to every variable that is a path, unless
# it follows freedesktop's sysroot rules (only -I, -L and ${pc_sysrootdir}, which wayland-protocols.pc
# uses for its XML files)
step_libxkbcommon() {
	PKG_CONFIG_FDO_SYSROOT_RULES=1 "$cross" "$xkbcommonRecipe" meson "${paths[@]}" --libexecdir=lib \
		-Denable-x11=false -Denable-docs=false -Dxkb-config-root=/boot/system/data/X11/xkb
	"$package" "$xkbcommonRecipe" --system-prefix --lib-tree xkbcommon --requires xkeyboard_config \
		--requires lib:libwayland_client
	no_build_paths libxkbcommon
}

step_wayland_server() {
	"$cross" --patches "$root/patches/wayland_server" "$serverRecipe" meson "${paths[@]}"
	"$package" "$serverRecipe" --system-prefix --no-devel --requires lib:libwayland_client \
		--requires lib:libwayland_server
	no_build_paths wayland_server
}

steps=(scanner wayland wayland_protocols xkeyboard_config libxkbcommon wayland_server)
if [ "${1:-}" = --only ]; then
	"step_$2"
	exit 0
fi
start="${1:-scanner}"
run=0
for s in "${steps[@]}"; do
	[ "$s" = "$start" ] && run=1
	[ "$run" = 1 ] && { echo "build-wayland: $s"; "step_$s"; }
done
[ "$run" = 1 ] || { echo "build-wayland: no step $start (${steps[*]})" >&2; exit 2; }

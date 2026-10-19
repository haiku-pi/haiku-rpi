#!/usr/bin/env bash
# build-netsurf.sh — cross-build the NetSurf web browser (HaikuPorts www-client/netsurf, its native
# Haiku "beos" frontend) and every library it needs that the arm64 repository lacks, as HaikuPorts-
# style packages (scripts/cross-port.sh, scripts/package-port.py), in dependency order:
#
#   libiconv, libpng16, libjpeg_turbo, libutf8proc       (libroot has no iconv)
#   openssl3, curl (HTTPS)                               (curl replaces curl-8.19.0_bootstrap, which
#                                                         has no TLS)
#   libwapcaplet, libparserutils, hubbub, libdom, libcss, libnsbmp, libnsgif, libnslog, libnspsl,
#   libnsutils, libsvgtiny                               (NetSurf's own libraries)
#   netsurf                                              (/boot/system/apps/NetSurf)
#
# Each recipe's build options are repeated here; where one differs, the comment says why. expat is
# not built: the arm64 bootstrap expat (+ _devel), which the haiku package already requires, is
# extracted into the sysroot. Build-only, not packaged: the NetSurf buildsystem (makefiles, installed
# into the sysroot's non-packaged/data/netsurf-buildsystem, where the libraries' makefiles read it)
# and nsgenbind (NetSurf's JavaScript binding generator, a host program).
# Host tools: perl, bison, flex, gperf, pkg-config, autotools, cmake + ninja, a host cc with zlib.
# Output: artifacts/packages/*.hpkg.
#
#   scripts/build-netsurf.sh [PORT]     (PORT: start at that port, e.g. "netsurf"; the earlier
#                                        ones must already be in the sysroot)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
cross="$root/scripts/cross-port.sh"
package="$root/scripts/package-port.py"
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
hostTools="$gen/objects/linux/x86_64/release/tools"
export LD_LIBRARY_PATH="$gen/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# what the script-mode builds below need besides cross-port.sh's CC, CXX, AR, ...: pkg-config looking
# into the sysroot, and the NetSurf buildsystem's makefiles
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/boot/system/non-packaged/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig"
export NSSHARED="$sysroot/boot/system/non-packaged/data/netsurf-buildsystem"
export NSHOST="$root/artifacts/cross-ports/netsurf-host-tools"
# openssl3 builds with zstd (scripts/build-packages.sh puts zstd into the sysroot)
[ -f "$sysroot/boot/system/develop/headers/zstd.h" ] \
	|| { echo "build-netsurf: no zstd in the sysroot: run scripts/build-packages.sh first" >&2; exit 1; }

expat() {
	local p f
	for p in expat expat_devel; do
		f=$(ls "$gen"/download/"$p"-[0-9]*-arm64.hpkg | head -n 1)
		"$hostTools/package/package" extract -C "$sysroot/boot/system" "$f"
	done
	rm -f "$sysroot/boot/system/.PackageInfo"
	sed -i 's|/packages/[^/]*/\.self|/boot/system|g' "$sysroot/boot/system/develop/lib/pkgconfig/expat.pc"
	rm -f "$sysroot/boot/system/develop/lib/libexpat.la"
}

libiconv() {
	AUTORECONF=0 "$cross" "$ports/dev-libs/libiconv/libiconv-1.18.recipe" autotools \
		--enable-relocatable --enable-shared --disable-static --disable-nls --enable-extra-encodings
	"$package" "$ports/dev-libs/libiconv/libiconv-1.18.recipe"
}

# --enable-arm-neon=yes: the default ("check" at run time) reads /proc/cpuinfo, which Haiku lacks;
# every arm64 CPU has NEON. The programs go into _devel, as the recipe has them.
libpng16() {
	"$cross" "$ports/media-libs/libpng/libpng16-1.6.53.recipe" autotools --disable-static \
		--enable-arm-neon=yes
	"$package" "$ports/media-libs/libpng/libpng16-1.6.53.recipe" --devel-bin libpng-config \
		--devel-bin libpng16-config --devel-bin pngfix --devel-bin png-fix-itxt
}

# the command-line tools (cjpeg, djpeg, ...) are the recipe's _tools package: not built here
libjpeg_turbo() {
	"$cross" "$ports/media-libs/libjpeg-turbo/libjpeg_turbo-3.1.4.1.recipe" cmake \
		-DENABLE_STATIC=OFF -DWITH_TOOLS=OFF
	"$package" "$ports/media-libs/libjpeg-turbo/libjpeg_turbo-3.1.4.1.recipe"
}

libutf8proc() {
	"$cross" "$ports/dev-libs/libutf8proc/libutf8proc-2.11.3.recipe" cmake \
		-DBUILD_SHARED_LIBS=ON -DUTF8PROC_ENABLE_TESTING=OFF
	"$package" "$ports/dev-libs/libutf8proc/libutf8proc-2.11.3.recipe"
}

# OpenSSL's Haiku configuration (Configurations/50-haiku.conf, as the patchset leaves it) has x86
# targets only; ./config would guess the build machine's. A haiku-aarch64 target in its style, then
# the recipe's options: no-asm (the recipe's choice for every architecture but x86_64), zlib, zstd,
# OPENSSLDIR /boot/system/data/ssl, where ca_root_certificates puts CARootCertificates.pem (the
# patchset makes that the default CA file). The engines-3/ and ossl-modules/ plug-ins are not
# packaged (package-port.py takes lib/*.so only); TLS needs neither.
openssl3() {
	"$cross" "$ports/dev-libs/openssl/openssl3-3.5.9.recipe" script '
cat > Configurations/51-haiku-aarch64.conf <<EOF
my %targets = (
    "haiku-aarch64" => {
        inherit_from     => [ "haiku-common" ],
        bn_ops           => "SIXTY_FOUR_BIT_LONG",
        asm_arch         => "aarch64",
        perlasm_scheme   => "linux64",
    },
);
EOF
./Configure haiku-aarch64 --prefix=/boot/system/non-packaged --libdir=lib \
	--openssldir=/boot/system/data/ssl enable-zlib enable-zstd shared no-asm no-tests \
	CC="${CC%% *}" AR="$AR" RANLIB="$RANLIB" CFLAGS="-Wall -O2 --sysroot=$SYSROOT" \
	LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/boot/system/non-packaged/lib"
make -j"$(nproc)"
make install_sw DESTDIR="${DEST%/boot/system/non-packaged}"
rm -f "$DEST"/lib/*.a'
	"$package" "$ports/dev-libs/openssl/openssl3-3.5.9.recipe" --requires ca_root_certificates
}

# curl with OpenSSL. Not ported, so not used: libssh2, nghttp2 (HTTP/2), libpsl (NetSurf has its own
# public suffix list, libnspsl), and --with-openssl-quic (it also needs nghttp3).
curl() {
	"$cross" "$ports/net-misc/curl/curl-8.22.0.recipe" autotools \
		--enable-ipv6 --enable-websockets --disable-static --disable-manual --disable-ldap \
		--with-openssl --without-libssh2 --without-nghttp2 --without-libpsl \
		--with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem \
		CPPFLAGS="-D_BSD_SOURCE -I$sysroot/boot/system/non-packaged/include" ac_cv_func_accept4=no
	# curl-config: the installed paths (the recipe's fixDevelopLibDirReferences), not this host's
	sed -i -e "s| -L$sysroot[^ ']*||g; s| --sysroot=$sysroot||g; s|$root[^ ']*/||g" \
		-e "s|^prefix='/boot/system/non-packaged'|prefix='/boot/system'|" \
		-e 's|includedir="${prefix}/include"|includedir="${prefix}/develop/headers"|' \
		-e 's|${exec_prefix}/lib|${exec_prefix}/develop/lib|g' \
		"$root/artifacts/cross-ports/curl-8.22.0/install/boot/system/non-packaged/bin/curl-config"
	"$package" "$ports/net-misc/curl/curl-8.22.0.recipe" --devel-bin curl-config \
		--requires ca_root_certificates
}

# the NetSurf buildsystem: makefiles only, read by the libraries' builds from the sysroot
netsurf_buildsystem() {
	"$cross" "$ports/dev-build/netsurf_buildsystem/netsurf_buildsystem-1.10.recipe" script '
make install PREFIX=/boot/system/non-packaged BASE="$DEST/data/netsurf-buildsystem"'
}

# nsgenbind: generates NetSurf's JavaScript (duktape) bindings at build time, a host program
nsgenbind() {
	local recipe="$ports/dev-libs/nsgenbind/nsgenbind-0.9.recipe" archive
	archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p')"
	rm -rf "$NSHOST"
	mkdir -p "$NSHOST"
	tar -xf "$archive" -C "$NSHOST"
	env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR make -C "$NSHOST/nsgenbind-0.9" \
		PREFIX="$NSHOST" install > "$NSHOST/build.log" 2>&1 \
		|| { tail -n 30 "$NSHOST/build.log" >&2; exit 1; }
	echo "build-netsurf: $NSHOST/bin/nsgenbind"
}

# a NetSurf library: the recipe's make lines (lib-shared), cross-compiling (HOST); -Wno-error as these
# makefiles use -Werror for every host but i586-pc-haiku. Not parallel (as in the recipes): the
# buildsystem creates its build directory racily (libnslog). CFLAGS and LDFLAGS go in the environment:
# the makefiles prepend their own flags to it.
#   [extraLdflags=...] nslib RECIPE [make variables...]
nslib() {
	local recipe="$1"
	shift
	"$cross" "$recipe" script "
export CFLAGS=\"-Wno-error -I\$SYSROOT/boot/system/non-packaged/include\"
export LDFLAGS=\"-L\$SYSROOT/boot/system/non-packaged/lib ${extraLdflags:-}\"
args=(PREFIX=/boot/system/non-packaged NSSHARED=\"\$NSSHARED\" COMPONENT_TYPE=lib-shared
	HOST=aarch64-unknown-haiku CC=\"\$CC\" AR=\"\$AR\" Q= $*)
make \"\${args[@]}\"
make install \"\${args[@]}\" DESTDIR=\"\${DEST%/boot/system/non-packaged}\" INCLUDEDIR=include \
	LIBDIR=lib"
	"$package" "$recipe"
}

libwapcaplet() { nslib "$ports/dev-libs/libwapcaplet/libwapcaplet-0.4.3.recipe"; }
# -liconv: its makefile does not link the iconv it calls (the recipe requires lib:libiconv); without
# it the library would load only into programs that link libiconv themselves
libparserutils() {
	extraLdflags=-liconv nslib "$ports/dev-libs/libparserutils/libparserutils-0.2.5.recipe"
}
hubbub() { nslib "$ports/net-libs/hubbub/hubbub-0.3.8.recipe"; }
libdom() { nslib "$ports/net-libs/libdom/libdom-0.4.2.recipe"; }
# VARIANT=debug: the recipe's (it makes a debug-info package from it): -O0 -g
libcss() { nslib "$ports/dev-libs/libcss/libcss-0.9.2.recipe" VARIANT=debug; }
libnsbmp() { nslib "$ports/media-libs/libnsbmp/libnsbmp-0.1.7.recipe"; }
libnsgif() { nslib "$ports/media-libs/libnsgif/libnsgif-1.0.0.recipe"; }
libnslog() { nslib "$ports/dev-libs/libnslog/libnslog-0.1.3.recipe"; }
libnspsl() { nslib "$ports/net-libs/libnspsl/libnspsl-0.1.7.recipe"; }
libnsutils() { nslib "$ports/dev-libs/libnsutils/libnsutils-0.1.1.recipe"; }
libsvgtiny() { nslib "$ports/media-libs/libsvgtiny/libsvgtiny-0.1.8.recipe"; }

# NetSurf, the recipe's "make TARGET=beos ... BUILD=release". Its CSS, HTML pages, icons and messages
# are Haiku resources in the executable since 3.6 (the recipe deletes what "make install" copies
# besides it): the jam-built host rc + xres + setversion put them there, as on Haiku. Not run:
# mimeset (attributes, which this host keeps by inode, and a copy loses); Haiku reads the signature
# and icon from the resources. The command line overrides frontends/beos/Makefile.tools' CC := gcc;
# PREFIX feeds only its -I$(PREFIX)/include -L$(PREFIX)/lib, so it is the sysroot's. Stripped here
# (before xres), as package-port.py must not strip a file with resources. Two makes, as the recipe's
# BUILD and INSTALL: the resource list is a wildcard, read before the first make writes the
# translated Messages files, so only the second embeds them (without them, no UI texts).
netsurf() {
	PATH="$NSHOST/bin:$PATH" "$cross" "$ports/www-client/netsurf/netsurf-3.11.recipe" script "
args=(TARGET=beos BUILD=release CC=\"\$CC\" CXX=\"\$CXX\" PREFIX=\"\$SYSROOT/boot/system/non-packaged/\"
	BEOS_RC=\"$hostTools/rc/rc\" BEOS_XRES=\"$hostTools/xres\" BEOS_SETVER=\"$hostTools/setversion\"
	BEOS_MIMESET=true NETSURF_STRIP_BINARY=YES STRIP=\"\$STRIP\" Q=)
make -j\"\$(nproc)\" \"\${args[@]}\"
make \"\${args[@]}\"
mkdir -p \"\$DEST/apps\" \"\$DEST/data/deskbar/menu/Applications\"
cp NetSurf \"\$DEST/apps/\"
ln -s ../../../../apps/NetSurf \"\$DEST/data/deskbar/menu/Applications/NetSurf\""
	"$package" "$ports/www-client/netsurf/netsurf-3.11.recipe" --provides app:NetSurf
}

steps=(expat libiconv libpng16 libjpeg_turbo libutf8proc openssl3 curl netsurf_buildsystem nsgenbind
	libwapcaplet libparserutils hubbub libdom libcss libnsbmp libnsgif libnslog libnspsl libnsutils
	libsvgtiny netsurf)
start="${1:-${steps[0]}}"
started=0
for s in "${steps[@]}"; do
	[ "$s" = "$start" ] && started=1
	[ "$started" = 1 ] || continue
	echo "build-netsurf: === $s"
	"$s"
done
[ "$started" = 1 ] || { echo "build-netsurf: no step $start (${steps[*]})" >&2; exit 2; }
for p in libiconv libpng16 libjpeg_turbo libutf8proc openssl3 curl libwapcaplet libparserutils hubbub \
		libdom libcss libnsbmp libnsgif libnslog libnspsl libnsutils libsvgtiny netsurf; do
	ls -l "$root"/artifacts/packages/"$p"{,_devel}-[0-9]*-arm64.hpkg 2>/dev/null || true
done

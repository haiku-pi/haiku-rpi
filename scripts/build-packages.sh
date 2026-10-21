#!/usr/bin/env bash
# build-packages.sh — (re)build every package of ours that sources/haiku's arm64 repository definition
# lists, and stage them with the "any" packages in jam's download directory, so that
# `scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc` (or @minimum-mmc) finds them all:
#
#   mesa, mesa_devel, glu, glu_devel       scripts/build-gl-stack.sh + scripts/package-gl-stack.sh
#   libogg, libvorbis, fluidlite (+_devel) scripts/cross-port.sh + scripts/package-port.py
#   libsdl2                                scripts/cross-port.sh + scripts/package-port.py
#   ffmpeg6                                scripts/build-ffmpeg.sh
#   zstd (+ zstd_source)                   scripts/cross-port.sh + scripts/package-port.py
#   gzip, tar, bzip2, unzip                scripts/build-base-ports.sh
#   netsurf + OpenSSL 3, curl, ...         scripts/build-netsurf.sh
#   haikuwebkit + libxml2, sqlite, ...     scripts/build-webkit.sh (several hours)
#   libedit (+_devel)                      scripts/cross-port.sh + scripts/package-port.py
#   python3.14 (+_devel)                   scripts/build-python.sh (after OpenSSL, sqlite, libedit)
#   icu74 (+_devel)                        scripts/build-icu.sh (its data in libicudata)
#   ncurses6_bootstrap                     scripts/make-bootstrap-shim.sh (the terminfo path of ncurses6's
#                                          bootstrap package)
#   nano, wget, rsync, vim, openssh, git,  scripts/cross-port.sh + scripts/package-port.py (for pkgman: no
#   htop_rivoreo; lz4, xxhash, libpcre2    image has them, so the repository definition does not list them)
#   (+_devel)
#   fonts, sounds, firmware, user guide    scripts/fetch-any-packages.sh (x86_64 repository)
#   openarena, supertuxkart                scripts/package-games.sh (not run here: needs build-games.sh and
#                                          build-stk.sh; only for -sHAIKU_PI_GAMES=1 images)
#
#   scripts/build-packages.sh [--sysroot]   (--sysroot: recreate the sysroot first)
#
# Needs a jam build of the tree (the cross compiler, haiku_devel.hpkg, the host package tool).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
download="$root/sources/haiku/generated.arm64/download"
if [ "${1:-}" = --sysroot ]; then
	"$root/scripts/haiku-sysroot.sh"
fi

"$root/scripts/build-gl-stack.sh"
"$root/scripts/package-gl-stack.sh"

"$root/scripts/cross-port.sh" "$ports/media-libs/libogg/libogg-1.3.6.recipe" cmake \
	-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
"$root/scripts/package-port.py" "$ports/media-libs/libogg/libogg-1.3.6.recipe"
# autotools: libvorbis' CMake build gives the libraries their full version as soname
"$root/scripts/cross-port.sh" "$ports/media-libs/libvorbis/libvorbis-1.3.7.recipe" autotools \
	--disable-static
"$root/scripts/package-port.py" "$ports/media-libs/libvorbis/libvorbis-1.3.7.recipe"
"$root/scripts/cross-port.sh" "$ports/media-sound/fluidlite/fluidlite-1.0.9.recipe" cmake \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SF3=YES -DSTB_VORBIS=NO
# jam's fluidlite build feature links the static library as libfluidlite-static.a
"$root/scripts/package-port.py" "$ports/media-sound/fluidlite/fluidlite-1.0.9.recipe" \
	--static-suffix=-static

# SDL2 (the games) and ffmpeg link libmedia and libgame, which the sysroot's haiku_devel (from the
# minimum build) does not have: the libraries jam built (as scripts/build-games.sh does)
objects="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/kits"
for l in game/libgame.so media/libmedia.so; do
	cp "$objects/$l" "$root/artifacts/sysroot-arm64/boot/system/develop/lib/"
done
# with patches/libsdl2 (Vulkan windows through Mesa's Haiku WSI; OpenGL ES contexts; display modes that own their data;
# window events handled on the thread that pumps events); revision 5
"$root/scripts/cross-port.sh" --patches "$root/patches/libsdl2" \
	"$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" cmake \
	-DSDL_STATIC=OFF -DSDL_RPATH=OFF -DSDL_TEST=OFF -DSDL_VULKAN=ON
"$root/scripts/package-port.py" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" \
	--revision 5 --devel-bin sdl2-config

# ffmpeg (the media kit's ffmpeg plugin, MediaPlayer), with HEVC on the Pi 4's decoder block
"$root/scripts/build-ffmpeg.sh"

# zstd: the packages from Haiku's servers are zstd-compressed, and packagefs and the package kit
# read them only with jam's zstd feature (zstd_devel + zstd_source: packagefs compiles the decoder)
"$root/scripts/cross-port.sh" "$ports/app-arch/zstd/zstd-1.5.7.recipe" script '
make -j"$(nproc)" CC="$CC" AR="$AR" RANLIB="$RANLIB" prefix=/boot/system/non-packaged lib-release \
	zstd-release
make CC="$CC" AR="$AR" RANLIB="$RANLIB" prefix=/boot/system/non-packaged \
	DESTDIR="${DEST%/boot/system/non-packaged}" install
rm -f "$DEST"/lib/libzstd.a
rm -rf "$DEST/share"'
"$root/scripts/package-port.py" "$ports/app-arch/zstd/zstd-1.5.7.recipe" --source-package

"$root/scripts/build-base-ports.sh"
"$root/scripts/build-netsurf.sh"
"$root/scripts/build-webkit.sh"
# libedit: CPython's readline module (ncurses6, the bootstrap package, is in the sysroot)
"$root/scripts/cross-port.sh" "$ports/sys-libs/libedit/libedit-20260512_3.1.recipe" autotools \
	--enable-examples=no --enable-widec --disable-static
"$root/scripts/package-port.py" "$ports/sys-libs/libedit/libedit-20260512_3.1.recipe" \
	--requires lib:libncursesw
"$root/scripts/build-python.sh"
"$root/scripts/fetch-any-packages.sh"
"$root/scripts/build-icu.sh"
# ncurses6 is upstream's bootstrap package (the build's download directory); published with ours, as
# python3.14 and libedit need it, with the shim that gives it its terminfo database
cp "$download"/ncurses6-6.6_bootstrap-1-arm64.hpkg "$root/artifacts/packages/"
"$root/scripts/make-bootstrap-shim.sh" ncurses6_bootstrap 6.6-1 ncurses6 "the terminfo database (data/terminfo)"

# everyday command-line tools. Libraries in /boot/system/lib (the bootstrap ncurses6, zlib, expat) are
# not ours to package-port.py, which takes them for the system's: their requires are named here.
# nano: syntax files in data/nano, nanorc read from settings/ (no gettext, no libmagic)
AUTORECONF=0 "$root/scripts/cross-port.sh" "$ports/app-editors/nano/nano-9.1.recipe" autotools --disable-nls \
	--sysconfdir=/boot/system/settings '--datadir=${prefix}/data'
"$root/scripts/package-port.py" "$ports/app-editors/nano/nano-9.1.recipe" \
	--requires lib:libncursesw --requires lib:libz
# libpcre2: wget --regex-type=pcre, git grep -P (pcre2-config with the packaged paths)
"$root/scripts/cross-port.sh" "$ports/dev-libs/libpcre2/libpcre2-10.45.recipe" autotools --with-pic \
	--enable-pcre2-16 --enable-pcre2-32 --enable-jit --enable-pcre2grep-libz --enable-pcre2grep-libbz2 \
	--enable-pcre2test-libedit --disable-static
sed -i -e 's|^prefix=/boot/system/non-packaged|prefix=/boot/system|' \
	-e 's|${exec_prefix}/lib|${exec_prefix}/develop/lib|g' -e 's|${prefix}/include|${prefix}/develop/headers|g' \
	"$root/artifacts/cross-ports/libpcre2-10.45/install/boot/system/non-packaged/bin/pcre2-config"
"$root/scripts/package-port.py" "$ports/dev-libs/libpcre2/libpcre2-10.45.recipe" --devel-bin pcre2-config \
	--requires lib:libz
# wget: the shipped configure (the host has no autopoint for autoreconf), -lnetwork as the patched
# configure.ac adds it; OpenSSL's default CA file is ca_root_certificates', so no wgetrc
AUTORECONF=0 "$root/scripts/cross-port.sh" "$ports/net-misc/wget/wget-1.24.5.recipe" autotools --disable-nls \
	--disable-rpath --with-ssl=openssl --without-libpsl --disable-pcre --sysconfdir=/boot/system/settings \
	LIBS=-lnetwork AUTOCONF=: AUTOMAKE=: ACLOCAL=:
"$root/scripts/package-port.py" "$ports/net-misc/wget/wget-1.24.5.recipe" \
	--requires ca_root_certificates --requires lib:libz
# lz4, xxhash: rsync's compression and checksums
"$root/scripts/cross-port.sh" "$ports/app-arch/lz4/lz4-1.9.4.recipe" script '
make -C lib BUILD_STATIC=no CC="$CC" AR="$AR" -j"$(nproc)"
make -C programs CC="$CC" -j"$(nproc)" lz4 lz4c
make BUILD_STATIC=no CC="$CC" install DESTDIR="${DEST%/boot/system/non-packaged}" PREFIX=/boot/system/non-packaged
rm -rf "$DEST/share"'
"$root/scripts/package-port.py" "$ports/app-arch/lz4/lz4-1.9.4.recipe"
"$root/scripts/cross-port.sh" "$ports/dev-libs/xxhash/xxhash-0.8.3.recipe" script '
make CC="$CC" AR="$AR" -j"$(nproc)" lib xxhsum
make CC="$CC" AR="$AR" install DESTDIR="${DEST%/boot/system/non-packaged}" PREFIX=/boot/system/non-packaged
rm -f "$DEST"/lib/libxxhash.a
rm -rf "$DEST/share"'
"$root/scripts/package-port.py" "$ports/dev-libs/xxhash/xxhash-0.8.3.recipe"
# rsync: its configure wrapper only works in the source tree; the run-time checks answered as on Haiku
"$root/scripts/cross-port.sh" "$ports/net-misc/rsync/rsync-3.2.7.recipe" script '
np="$SYSROOT/boot/system/non-packaged"
aclocal -I m4
autoconf -o configure.sh
autoheader
./configure.sh --host=aarch64-unknown-haiku --prefix=/boot/system/non-packaged \
	--enable-xattr-support --disable-iconv --disable-iconv-open --disable-locale --disable-debug \
	--with-included-zlib=no --disable-md2man CC="$CC" CPPFLAGS="-I$np/include" LDFLAGS="-L$np/lib" \
	rsync_cv_HAVE_SOCKETPAIR=yes rsync_cv_HAVE_SECURE_MKSTEMP=yes rsync_cv_HAVE_C99_VSNPRINTF=yes \
	rsync_cv_HAVE_BROKEN_READDIR=no rsync_cv_HAVE_BROKEN_LARGEFILE=no
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"
rm -rf "$DEST/share"'
"$root/scripts/package-port.py" "$ports/net-misc/rsync/rsync-3.2.7.recipe" --requires lib:libz
# vim: the console editor (no GUI, no Python/Ruby interpreters), prefix /boot/system as VIMRUNTIME
# (data/vim/vim91) is compiled in
"$root/scripts/heavy-build.sh" -- "$root/scripts/cross-port.sh" "$ports/app-editors/vim/vim-9.1.1618.recipe" script '
cd src
PKG_CONFIG_LIBDIR="$SYSROOT/boot/system/develop/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
./configure --host=aarch64-unknown-haiku --prefix=/boot/system --datadir=/boot/system/data \
	--disable-gui --without-x --without-wayland --with-features=huge --enable-fail-if-missing=yes \
	--enable-cscope --disable-nls --with-tlib=ncursesw --with-compiledby=haiku-pi \
	CC="$CC" LDFLAGS=-lgnu vim_cv_uname_output=Haiku vim_cv_uname_r_output=1 vim_cv_uname_m_output=arm64 \
	vim_cv_toupper_broken=no vim_cv_terminfo=yes vim_cv_tgetent=zero vim_cv_tty_group=world \
	vim_cv_tty_mode=0620 vim_cv_getcwd_broken=no vim_cv_stat_ignores_slash=no \
	vim_cv_memmove_handles_overlap=yes
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}" STRIP=:
system="${DEST%/non-packaged}"
ln -s vim "$system/bin/vi"
rm -rf "$system/share" "$system/data/applications" "$system/data/icons"'
"$root/scripts/package-port.py" "$ports/app-editors/vim/vim-9.1.1618.recipe" --system-prefix \
	--requires lib:libncursesw
# openssh: client and sshd; the recipe's sshd user and group and its host key generation on activation
"$root/scripts/cross-port.sh" "$ports/net-misc/openssh/openssh-10.6p1.recipe" script '
np="$SYSROOT/boot/system/non-packaged"
system="${DEST%/non-packaged}"
defaultPath=".:/boot/home/config/non-packaged/bin:/boot/home/config/bin"
defaultPath+=":/boot/system/non-packaged/bin:/boot/system/bin:/bin"
defaultPath+=":/boot/system/apps:/boot/system/preferences"
touch configure
PATH_PASSWD_PROG=/bin/passwd LOGIN_PROGRAM=/bin/login \
PKG_CONFIG_LIBDIR="$np/lib/pkgconfig:$SYSROOT/boot/system/develop/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
./configure --host=aarch64-unknown-haiku --prefix=/boot/system --sbindir=/boot/system/bin \
	--sysconfdir=/boot/system/settings/ssh --libexecdir=/boot/system/lib/openssh \
	--with-privsep-path=/boot/system/data/openssh/empty --with-pid-dir=/boot/system/var/run \
	--with-default-path="$defaultPath" --disable-utmpx --with-libedit --disable-strip \
	CC="$CC" CPPFLAGS="-I$np/include" LDFLAGS="-L$np/lib"
make -j"$(nproc)"
make install-nokeys DESTDIR="${system%/boot/system}"
install -m 755 contrib/ssh-copy-id "$system/bin"
sed -i -e "s| ~/\.ssh/| /boot/home/config/settings/ssh/|" "$system/settings/ssh/ssh_config"
mkdir -p "$system/data/openssh/empty"
cp "$system/settings/ssh/ssh_config" "$system/data/openssh/ssh_config.default"
cp "$system/settings/ssh/sshd_config" "$system/data/openssh/sshd_config.default"
rm -rf "$system/share"'
"$root/scripts/package-port.py" "$ports/net-misc/openssh/openssh-10.6p1.recipe" --system-prefix \
	--lib-tree openssh --global-writable settings/ssh --requires lib:libz --requires cmd:login \
	--requires cmd:passwd --group sshd \
	--user 'sshd real-name "sshd user" home "/boot/system/data/openssh/empty" shell "/bin/true" groups sshd' \
	--post-install "$ports/net-misc/openssh/additional-files/sshd_keymaker.sh"
# git: the recipe's make variables, without Perl, Python, Tcl/Tk and gettext; the programs in bin/
# are links to lib/git-core, as the recipe makes them
"$root/scripts/heavy-build.sh" -- "$root/scripts/cross-port.sh" "$ports/dev-vcs/git/git-2.56.0.recipe" script '
np="$SYSROOT/boot/system/non-packaged"
system="${DEST%/non-packaged}"
makeGit() {
	make prefix=/boot/system bindir_relative=bin gitexecdir=/boot/system/lib/git-core \
		sharedir=/boot/system/data template_dir=/boot/system/data/git-core/templates \
		sysconfdir=/boot/system/settings \
		uname_S=Haiku uname_O=Haiku uname_M=arm64 uname_P=arm64 uname_R=1 uname_V=1 \
		CC="$CC" AR="$AR" CFLAGS="-O2 -I$np/include" LDFLAGS="-L$np/lib" \
		CURL_CFLAGS= CURL_LDFLAGS=-lcurl PTHREAD_LIBS= USE_LIBPCRE2=YesPlease \
		NO_D_TYPE_IN_DIRENT=YesPlease NO_MEMMEM=YesPlease NEEDS_LIBICONV=YesPlease NO_RUST=YesPlease \
		NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease \
		OBJECT_CREATION_USES_RENAMES=YesPlease NO_CROSS_DIRECTORY_HARDLINKS=YesPlease \
		NO_INSTALL_HARDLINKS=YesPlease HAVE_DEV_TTY=YesPlease DEFAULT_EDITOR=nano \
		DEFAULT_HELP_FORMAT=web BASIC_LDFLAGS="-lnetwork -lbsd" \
		CPPFLAGS="-D_POSIX_THREAD_SAFE_FUNCTIONS" "$@"
}
makeGit -j"$(nproc)" all
makeGit install DESTDIR="${system%/boot/system}"
mkdir -p "$system/data/bash-completion/completions"
cp contrib/completion/git-completion.bash "$system/data/bash-completion/completions/git"
rm -rf "$system/share"
for program in "$system"/bin/git* "$system/bin/scalar"; do
	ln -sfn "/boot/system/lib/git-core/$(basename "$program")" "$program"
done'
"$root/scripts/package-port.py" "$ports/dev-vcs/git/git-2.56.0.recipe" --system-prefix --lib-tree git-core \
	--requires lib:libz --requires lib:libexpat --requires cmd:nano
# htop: Rivoreo's fork, the HaikuPorts htop with Haiku support
"$root/scripts/cross-port.sh" "$ports/sys-process/htop_rivoreo/htop_rivoreo-2.3.1.recipe" autotools \
	--sysconfdir=/boot/system/settings
"$root/scripts/package-port.py" "$ports/sys-process/htop_rivoreo/htop_rivoreo-2.3.1.recipe" \
	--requires lib:libncursesw

mkdir -p "$download"
cp "$root"/artifacts/packages/*.hpkg "$download/"
echo "build-packages: staged $(ls "$root"/artifacts/packages/*.hpkg | wc -l) packages in $download"

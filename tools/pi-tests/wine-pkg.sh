#!/bin/sh
# wine-pkg.sh — a UserBootscript: the Wine packages as a user gets them, before they are published. On an image
# without Wine, installs the .hpkg files netboot-cycle.sh --add put in /boot/home/pkgs (wine, wine_x86 and the
# Wayland stack they need) with pkgman, then runs Wine from the packaged prefix: a new prefix with the x86 emulator,
# and the test programs (/boot/home/wine-tests: hello, tone and gltest, as x86). Serial console lines: "WPK ".
sleep 15
out=/dev/dprintf
say() { echo "WPK $*" > $out; }
export WINEPREFIX=/boot/home/wineprefix-pkg
tests=/boot/home/wine-tests

say "installing: $(ls /boot/home/pkgs | tr '\n' ' ')"
pkgman install -y /boot/home/pkgs/*.hpkg > /tmp/pkgman.txt 2>&1
say "pkgman: exit $?"
tail -n 5 /tmp/pkgman.txt | while read -r line; do say "  pkgman: $line"; done
say "wine: $(which wine 2>&1) $(wine --version 2>&1)"

start=$(date +%s)
# no Wine Mono / Gecko installer dialogs (Wine 11.20 asks; nobody is there to answer)
WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i > /tmp/wineboot.txt 2>&1
wineserver -w
say "prefix: $(( $(date +%s) - start )) s, system32 $(ls $WINEPREFIX/drive_c/windows/system32 2> /dev/null | wc -l)," \
	"syswow64 $(ls $WINEPREFIX/drive_c/windows/syswow64 2> /dev/null | wc -l) files"

# NAME EXE ARGS... (60 s at most each)
t() {
	name=$1
	shift
	wine "$@" > /tmp/$name.txt 2>&1 &
	pid=$!
	n=0
	while [ $n -lt 60 ] && kill -0 $pid 2> /dev/null; do sleep 1; n=$((n + 1)); done
	kill -0 $pid 2> /dev/null && say "$name: still running after 60 s"
	grep -a -E '^(TONE|GLTEST)|hello from|caught exception|thread result|wine: ' /tmp/$name.txt | head -n 12 | while read -r line; do say "$name: $line"; done
	wineserver -k
	sleep 2
}
t hello-x86 $tests/hello-x86.exe
t tone-x86 $tests/tone-x86.exe 3 1000
t gltest-x86 $tests/gltest-x86.exe 10
sync
say end

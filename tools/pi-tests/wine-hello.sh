#!/bin/sh
# wine-hello.sh — a UserBootscript for Wine on Haiku arm64 (the staged install: mkimage-pi4.sh --add-tree
# artifacts/wine/install/boot/system/non-packaged's parent): creates a prefix (wineboot) and runs the native
# arm64 Windows test program (tools/wine-tests/hello.c). Serial console lines: "WIN ".
sleep 15
out=/dev/dprintf
say() { echo "WIN $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export WINEDEBUG=err+all,fixme-all
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
# bounded SECS OUT CMD...: runs CMD with its output in OUT, killed after SECS (a crash waits in the debugger)
bounded() {
	secs=$1; outf=$2; shift 2
	"$@" > "$outf" 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		kill -9 $pid 2> /dev/null
		for t in $(ps | grep -a -E 'wine|wineserver' | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
		echo "(killed after $secs s)" >> "$outf"
		return 124
	fi
	wait $pid
}
bounded 60 /tmp/version.txt wine --version
say "wine --version: exit $?: $(head -n 5 /tmp/version.txt | tr '\n' ' ' | cut -c1-200)"
start=$(date +%s)
bounded 300 /tmp/wineboot.txt wineboot -i
say "wineboot: exit $? in $(( $(date +%s) - start )) s"
tail -n 30 /tmp/wineboot.txt | while read -r line; do say "  boot: $line"; done
start=$(date +%s)
bounded 120 /tmp/hello.txt wine /boot/system/non-packaged/data/wine-tests/hello-arm64.exe
say "hello: exit $? in $(( $(date +%s) - start )) s"
cat /tmp/hello.txt | head -n 40 | while read -r line; do say "  $line"; done
# 32-bit x86 through WoW64: Box64's wowbox64.dll as the x86 emulator (Hangover's arrangement)
if [ -f /boot/system/non-packaged/lib/wine/aarch64-windows/wowbox64.dll ]; then
	cp /boot/system/non-packaged/lib/wine/aarch64-windows/wowbox64.dll $WINEPREFIX/drive_c/windows/system32/
	bounded 60 /tmp/reg.txt wine reg add 'HKLM\Software\Microsoft\Wow64\x86' /ve /d wowbox64.dll /f
	say "wow64 emulator: exit $?: $(tail -n 1 /tmp/reg.txt)"
	start=$(date +%s)
	WINEDEBUG=err+all,fixme-all,+module,+loaddll,+wow bounded 180 /tmp/hello-x86.txt \
		wine /boot/system/non-packaged/data/wine-tests/hello-x86.exe
	say "hello-x86: exit $? in $(( $(date +%s) - start )) s"
	grep -a -v "^trace:module:get_load_order\|trace:module:get_module_path_end" /tmp/hello-x86.txt | tail -n 60 \
		| while read -r line; do say "  x86: $(echo "$line" | cut -c1-200)"; done
fi
say end

#!/bin/sh
# membarrier.sh — a UserBootscript for the kernel's team memory barrier (_kern_team_memory_barrier) and Wine's
# NtFlushProcessWriteBuffers on it (patches/wine-11.20/0025). Serial console lines: "MB ".
#   /boot/home/membarrier             tools/haiku-tests/membarrier.c (litmus + cost)
#   /boot/home/flushwb-<arch>.exe     tools/wine-tests/flushwb.c (arm64, and x86/x64 when present)
# Wine from the packages (wine wine_data wine_directx [wine_x86 wine_x86_64] + the Wayland stack), a fresh
# prefix. /boot/home/mb.env may set MB_ROUNDS / MB_CALLS (shorter runs in QEMU: MB_ROUNDS=20000 MB_CALLS=2000)
# and MB_NO_WINE=1.
sleep 15
[ -f /boot/home/mb.env ] && . /boot/home/mb.env
out=/dev/dprintf
say() { echo "MB $*" > $out; }
rounds=${MB_ROUNDS:-100000}
calls=${MB_CALLS:-20000}
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
say "kernel: $(uname -a | cut -c1-120)"
bounded 900 /tmp/mb.txt /boot/home/membarrier $rounds $calls
say "membarrier: exit $?"
while read -r line; do say "  $line"; done < /tmp/mb.txt
if [ -z "$MB_NO_WINE" ] && command -v wine > /dev/null 2>&1; then
	export WINEPREFIX=/boot/home/mbprefix
	export WINEDEBUG=err+all,fixme-all,fixme+virtual
	start=$(date +%s)
	bounded 1800 /tmp/wineboot.txt wineboot -i
	say "wineboot: exit $? in $(( $(date +%s) - start )) s"
	start=$(date +%s)
	bounded 1800 /tmp/wait.txt wineserver -w
	say "wineserver -w: exit $? after $(( $(date +%s) - start )) s more"
	start=$(date +%s)
	bounded 600 /tmp/echo.txt wine cmd /c echo hello from cmd
	say "cmd /c echo: exit $? in $(( $(date +%s) - start )) s: $(tr -d '\r' < /tmp/echo.txt | tail -n 3 | tr '\n' ' ' | cut -c1-200)"
	for a in arm64 x86 x64; do
		[ -f /boot/home/flushwb-$a.exe ] || continue
		[ $a = x86 ] && [ ! -d /boot/system/lib/wine/i386-windows ] && continue
		start=$(date +%s)
		bounded 1800 /tmp/flushwb-$a.txt wine /boot/home/flushwb-$a.exe $rounds $calls
		say "flushwb-$a: exit $? in $(( $(date +%s) - start )) s"
		tr -d '\r' < /tmp/flushwb-$a.txt | grep -a -E 'FLUSHWB|NtFlushProcessWriteBuffers|err:' | head -n 20 \
			| while read -r line; do say "  $a: $line"; done
	done
fi
say end

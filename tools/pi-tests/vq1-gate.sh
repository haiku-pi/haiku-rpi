#!/bin/sh
# vq1-gate.sh URL [ITEM...] — VQ1's merge gate on the Pi, in one network session (copied with its helpers to
# /boot/home/vq1 by tools/pi-tests/vq1-gate-run.sh). Each item runs under a time limit; a run past it is a hang.
# Items (default all):
#   psh      pshcut 10 3000: a cut below a waiter on a process-shared mutex in heap memory returns at once
#   vcut     vchiq_test_cut -b 1024 400 x5, then KILL=1 x3 (killed during the waits)
#   mp       MediaPlayer on URL (MP3's trigger clip over http) 60 times, kill -9 and hey quit alternating
#   cptr     clientptr (tools/gl-tests/clientptr.c): GL_MESA_map_buffer_client_pointer's placed maps (MAP_FIXED
#            commits and decommits in a reserved range: the clone-replaces-range path)
#   tar      tar of /boot/system/apps + lib (~1 GB) and back, compared by file count
#   git      git clone --depth 1 of a GitHub repository (GIT_URL, default haiku-pi/haiku-rpi)
#   pkg      pkgman install of PKG_FILE (a .hpkg next to this script, if any)
#   ffv      Firefox, h264-1080p.mp4 (ffv0.sh, from /boot/home/ffv)
#   blender  blender-b7-view.sh (open, Cycles/Material Preview viewport, EEVEE F12), from /boot/home/vq1/blender
# Lines "VQ1G <item> ...", "VQ1G <item> PASS|FAIL|HANG ...", the last "VQ1G result: F failed, D debugger entries".
url=${1:?usage: vq1-gate.sh URL [ITEM...]}
shift
items=${*:-psh vcut mp cptr tar git pkg ffv blender}
dir=$(cd "$(dirname "$0")" && pwd)
say() { echo "VQ1G $*"; echo "VQ1G $*" > /dev/dprintf; }
dbg() { grep -a "entered the debugger" /var/log/syslog | grep -a -c -v "VQ1"; }
failed=0
fail() { failed=$((failed + 1)); say "$*"; }
# lim SECS CMD...: CMD under a time limit; 124 = timed out
lim() { timeout "$@"; }
dbg0=$(dbg)
for it in $items; do
	d0=$(dbg)
	case $it in
	psh)
		lim 120 "$dir/pshcut" 10 3000 > /tmp/vq1g-psh.txt 2>&1; rc=$?
		say "psh $(tail -n 1 /tmp/vq1g-psh.txt)"
		[ $rc = 0 ] && say "psh PASS" || fail "psh FAIL (exit $rc)" ;;
	vcut)
		lim 300 sh "$dir/vq1-vchiqcut.sh" 5 gate-vcut > /tmp/vq1g-vcut.txt 2>&1; rc=$?
		KILL=1 lim 120 sh "$dir/vq1-vchiqcut.sh" 3 gate-vkill > /tmp/vq1g-vkill.txt 2>&1; rc2=$?
		grep -a "result" /tmp/vq1g-vcut.txt /tmp/vq1g-vkill.txt | sed 's/^.*VQ1 /vcut /' | while read -r l; do say "$l"; done
		grep -q "result: 0 of" /tmp/vq1g-vcut.txt && grep -q "result: 0 of" /tmp/vq1g-vkill.txt \
			&& say "vcut PASS" || fail "vcut FAIL (exit $rc/$rc2)" ;;
	mp)
		lim 900 sh "$dir/vq1-mpswitch.sh" 60 mix "$url" gate-mp > /tmp/vq1g-mp.txt 2>&1; rc=$?
		say "mp $(grep -a 'result' /tmp/vq1g-mp.txt)"
		[ $rc != 124 ] && say "mp PASS (the players' own debugger entries are counted below)" || fail "mp HANG" ;;
	cptr)
		lim 300 "$dir/clientptr" > /tmp/vq1g-cptr.txt 2>&1; rc=$?
		grep -a "GCP " /tmp/vq1g-cptr.txt | tail -n 3 | while read -r l; do say "cptr $l"; done
		[ $rc = 0 ] && say "cptr PASS" || fail "cptr FAIL (exit $rc)" ;;
	tar)
		rm -rf /boot/home/vq1t && mkdir -p /boot/home/vq1t
		n0=$(find /boot/system/apps /boot/system/lib | wc -l)
		lim 900 tar cf /boot/home/vq1t/a.tar /boot/system/apps /boot/system/lib 2> /dev/null; rc=$?
		lim 900 tar xf /boot/home/vq1t/a.tar -C /boot/home/vq1t 2> /dev/null; rc2=$?
		n1=$(find /boot/home/vq1t/boot/system/apps /boot/home/vq1t/boot/system/lib | wc -l)
		say "tar $(ls -l /boot/home/vq1t/a.tar | awk '{ print $5 }') bytes, $n0 entries, $n1 back (exit $rc/$rc2)"
		rm -rf /boot/home/vq1t
		[ $rc != 124 ] && [ $rc2 != 124 ] && [ "$n0" = "$n1" ] && say "tar PASS" || fail "tar FAIL" ;;
	git)
		rm -rf /boot/home/vq1g
		lim 600 git clone -q --depth 1 "${GIT_URL:-https://github.com/haiku-pi/haiku-rpi}" /boot/home/vq1g \
			> /tmp/vq1g-git.txt 2>&1; rc=$?
		say "git exit $rc, $(find /boot/home/vq1g -type f 2> /dev/null | wc -l) files, $(git -C /boot/home/vq1g log --oneline -1 2>&1)"
		rm -rf /boot/home/vq1g
		[ $rc = 0 ] && say "git PASS" || fail "git FAIL (exit $rc)" ;;
	pkg)
		f=$(ls "$dir"/*.hpkg 2> /dev/null | head -n 1)
		if [ -z "$f" ]; then say "pkg skipped (no package)"; else
			lim 300 pkgman install -y "$f" > /tmp/vq1g-pkg.txt 2>&1; rc=$?
			say "pkg $(basename "$f"): exit $rc"
			[ $rc = 0 ] && say "pkg PASS" || fail "pkg FAIL"
		fi ;;
	ffv)
		lim 300 sh /boot/home/ffv/ffv0.sh h264-1080p.mp4 gate > /tmp/vq1g-ffv.txt 2>&1; rc=$?
		grep -a "quality\|team .*Firefox" /tmp/vq1g-ffv.txt | while read -r l; do say "ffv $l"; done
		grep -a -q "quality after" /tmp/vq1g-ffv.txt && say "ffv PASS" || fail "ffv FAIL (exit $rc)" ;;
	blender)
		lim 900 sh "$dir/blender/blender-b7-view.sh" gate > /dev/null 2>&1; rc=$?
		grep -a "BB7V" /tmp/bb7v-gate.txt | grep -a -v SNAP | tail -n 12 | while read -r l; do say "blender $l"; done
		[ $rc != 124 ] && grep -q "BB7V done" /tmp/bb7v-gate.txt && ! grep -a "BB7V exit status" /tmp/bb7v-gate.txt \
			| grep -q -v "status 0" && say "blender PASS" || fail "blender FAIL (exit $rc)" ;;
	*) say "$it: no such item" ;;
	esac
	d1=$(dbg)
	[ "$d1" = "$d0" ] || say "$it: $((d1 - d0)) debugger entries"
done
say "result: $failed failed, $(($(dbg) - dbg0)) debugger entries"

#!/bin/sh
# libc.sh — the LIBC part of tools/x86-tests/core.sh alone (strtold/strtod, setrlimit, poll, the string routines,
# user copies, DT_RELR), for a quick re-run after a libroot or kernel change. Serial lines "X86T libc ...".
G=libc
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
say "info $(uname -a)"
t strtold 300 'strtold: ok' ./strtold
# strtod()/strtof() alone (strtold's output is cut at 40 lines): every check of theirs, verbose
t strtod 300 '!FAIL' sh -c "./strtold -v | grep -a -E 'strto[df]( errno)?:|round trip strtod'"
t setrlimit 60 'setrlimit: ok' ./setrlimit
t strtest 600 'strtest: PASS' ./strtest
t polltest 60 'POLLTEST ok' ./polltest
t relrtest 60 'relrtest: ok' ./relr/relrtest $X86T_DIR/relr
# last: before haiku 6f810ed2d7 it panics the kernel
t usercopy 120 'usercopy: PASS' ./usercopy /boot/system/lib/libroot.so
finish

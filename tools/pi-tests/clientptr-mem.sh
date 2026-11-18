#!/bin/sh
# clientptr-mem.sh — run over ssh in a Pi session: the memory cost of GL_MESA_map_buffer_client_pointer for a WoW64
# program (docs/design/gl-client-pointer.md §8). Runs EXE under Wine in DIR with the extension on or off (off:
# MESA_EXTENSION_OVERRIDE, the same Mesa build), after SECS seconds prints the system's used memory relative to
# before the start, and the v3d BO mappings in the program's team (count, MiB, and how many of them lie below
# 4 GiB, i.e. were placed in Wine's ranges); then ends Wine and counts Mesa's "never released" range warnings.
#
#   sh clientptr-mem.sh on|off DIR SECS EXE [ARGS...]          (lines "MEM ...")
mode=$1 dir=$2 secs=$3; shift 3
export HOME=/boot/home WINEDEBUG=err+all,fixme-all
[ $mode = off ] && export MESA_EXTENSION_OVERRIDE=-GL_MESA_map_buffer_client_pointer
cd $dir
before=$(sysinfo -mem | sed -n 's/.*used\/max *\([0-9]*\).*/\1/p')
start=$(date +%s)
wine "$@" > /tmp/mem-$mode.txt 2>&1 &
sleep $secs
id=$(ps | grep -a "bin/wine $1" | awk '{print $(NF-3)}' | head -1)
used=$(sysinfo -mem | sed -n 's/.*used\/max *\([0-9]*\).*/\1/p')
bo=$(listarea $id | grep -a "v3d bo map" | awk '{n++; s += strtonum("0x" $6)} END {printf "%d mappings, %.1f MiB", n, s / 1048576}')
low=$(listarea $id | grep -a "v3d bo map" | awk 'strtonum($5) < 4294967296 {n++; s += strtonum("0x" $6)} END {printf "%d below 4 GiB, %.1f MiB", n, s / 1048576}')
echo "MEM $mode $1: system used $(( (used - before) / 1048576 )) MiB more than before; BOs mapped in the team: $bo ($low)"
wineserver -k; sleep 3
echo "MEM $mode never-released warnings: $(grep -a -c 'never released' /tmp/mem-$mode.txt)"

#!/usr/bin/env bash
# build.sh — build dwarfdump, a host (Linux) harness around Haiku Debugger's DWARF reader
# (src/kits/debugger/dwarf/ of a Haiku tree), for testing the reader without a Haiku system:
#
#   tools/dwarf-host/build.sh HAIKU_TREE OUT_DIR      # -> OUT_DIR/dwarfdump
#   OUT_DIR/dwarfdump [--pc ADDR]... FILE             # dump units, ranges, files, lines, functions, variables
#
# It compiles the reader with the host flags Haiku's build uses for libbe_build (the BeOS build
# compatibility headers) and links libbe_build.so of the main tree's generated.arm64.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
[ $# = 2 ] || { echo "usage: $0 HAIKU_TREE OUT_DIR" >&2; exit 2; }
tree="$(cd "$1" && pwd)" out="$2"
mkdir -p "$out/obj"
out="$(cd "$out" && pwd)"
gen="$root/sources/haiku/generated.arm64"
libdir="$gen/objects/linux/lib"
h="$tree/headers"
flags=(-O1 -g -Wall -Wno-multichar -Wno-trigraphs -fPIC -std=gnu++17
	-include "$h/build/BeOSBuildCompatibility.h"
	-DARCH_x86_64 -D_NO_INLINE_ASM -D__NO_INLINE__ -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64
	-D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -DHAIKU_HOST_PLATFORM_LINUX
	-DHAIKU_HOST_PLATFORM_64_BIT
	-I "$here/include" -iquote "$tree/build/config_headers"
	-iquote "$tree/src/kits/debugger/dwarf" -iquote "$tree/src/kits/debugger"
	-iquote "$tree/src/kits/debugger/util"
	-I "$h/private/debugger" -I "$h/private/debugger/elf" -I "$h/private/debugger/types"
	-I "$h/private/debugger/util" -I "$h/private/debugger/model"
	-I "$h/build/private/app" -I "$h/build/private/interface" -I "$h/build/private/shared"
	-I "$h/build/private/support" -I "$h/build/host/linux" -I "$h/build" -I "$h/build/os"
	-I "$h/build/os/app" -I "$h/build/os/interface" -I "$h/build/os/kernel" -I "$h/build/os/storage"
	-I "$h/build/os/support" -I "$h/build/private" -I "$h/private/shared")
srcs=()
for f in "$tree"/src/kits/debugger/dwarf/*.cpp; do
	case "$(basename "$f")" in DwarfManager.cpp) continue ;; esac
	srcs+=("$f")
done
srcs+=("$tree/src/kits/debugger/elf/ElfFile.cpp" "$tree/src/kits/debugger/elf/ElfSymbolLookup.cpp"
	"$tree/src/kits/debugger/model/SymbolInfo.cpp"
	"$tree/src/kits/debugger/types/TargetAddressRangeList.cpp"
	"$tree/src/kits/debugger/types/ValueLocation.cpp"
	"$tree/src/kits/shared/Variant.cpp"
	"$here/dwarfdump.cpp")
objs=()
for s in "${srcs[@]}"; do
	o="$out/obj/$(basename "${s%.cpp}").o"
	g++ "${flags[@]}" -c "$s" -o "$o"
	objs+=("$o")
done
g++ -o "$out/dwarfdump" "${objs[@]}" -L "$libdir" -lbe_build -lroot_build -Wl,-rpath,"$libdir"
echo "dwarf-host: $out/dwarfdump"

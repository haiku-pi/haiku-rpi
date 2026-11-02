#!/usr/bin/env bash
# run-tests.sh — host tests of Haiku Debugger's DWARF reader (design/debugger-dwarf5.md):
#
#   tools/dwarf-host/run-tests.sh HAIKU_TREE [BASE_TREE]
#
# Builds dwarfdump (build.sh) from HAIKU_TREE, the test programs (tools/haiku-tests/dbgtarget.c, -O0,
# also with a mapped source path, and dbgtarget-cxx.cpp, -O2, also with type units) with the GCC 13 and GCC 16 cross compilers and
# clang, each with -gdwarf-4 and -gdwarf-5, and checks
#   rows    every line number row equals llvm-dwarfdump's (line-oracle.py; prologue_end ignored:
#           LineNumberProgram clears it before returning the row, and nothing uses it)
#   decl    every function's declaration file and line equals llvm-dwarfdump's (decl-oracle.py)
#   4 vs 5  the -gdwarf-4 and -gdwarf-5 builds give the same output (functions, ranges, declaration
#           lines, variables and their locations at every row address), except the language code,
#           the file table's order and why a location is unavailable
#   libstdc++ (GCC 13 and 16): units loaded and rows
# With BASE_TREE (e.g. sources/haiku, unchanged) also: the base reader's output on the files whose
# DWARF is version 4 throughout (unit and line tables), GCC's, which must be the same but for the file
# table (a file named twice is now one file), the language and DW_OP_GNU_entry_value's error code
# (clang's DWARF 4 is not compared: its relative include directories are now made absolute).
# Output in artifacts/dwarf5/; prints one line per check, "FAIL" lines for differences.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
[ $# -ge 1 ] || { echo "usage: $0 HAIKU_TREE [BASE_TREE]" >&2; exit 2; }
out="$root/artifacts/dwarf5"
bin="$out/bin"
mkdir -p "$bin"
"$here/build.sh" "$1" "$out/host-new" > /dev/null || exit 1
new="$out/host-new/dwarfdump"
base=
if [ $# -ge 2 ]; then
	"$here/build.sh" "$2" "$out/host-base" > /dev/null || exit 1
	base="$out/host-base/dwarfdump"
fi

t="$root/tools/haiku-tests"
gcc13="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
sys13="--sysroot=$root/artifacts/sysroot-arm64"
g16root="${GCC16_TREE:-/home/houp/haiku-rpi-gcc16}"
gcc16="$g16root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
sys16="--sysroot=$g16root/artifacts/sysroot-arm64"
headers="$root/artifacts/sysroot-arm64/boot/system/develop/headers"
programs=()
for v in 4 5; do
	"${gcc13}gcc" $sys13 -O0 -g -gdwarf-$v -o "$bin/c-gcc13-dw$v" "$t/dbgtarget.c"
	"${gcc13}g++" $sys13 -O2 -g -gdwarf-$v -o "$bin/cxx-gcc13-dw$v" "$t/dbgtarget-cxx.cpp"
	# type units: .debug_types (DWARF 4), DW_UT_type units in .debug_info (DWARF 5)
	"${gcc13}g++" $sys13 -O2 -g -gdwarf-$v -fdebug-types-section -o "$bin/cxx-types-gcc13-dw$v" \
		"$t/dbgtarget-cxx.cpp"
	# a mapped source path (-fdebug-prefix-map): GCC's DWARF 4 table names the file twice
	"${gcc13}gcc" $sys13 -O0 -g -gdwarf-$v -fdebug-prefix-map="$t=/boot/home/src" \
		-o "$bin/c-map-gcc13-dw$v" "$t/dbgtarget.c"
	programs+=(c-gcc13 cxx-gcc13 cxx-types-gcc13 c-map-gcc13)
	if [ -x "${gcc16}gcc" ]; then
		"${gcc16}gcc" $sys16 -O0 -g -gdwarf-$v -o "$bin/c-gcc16-dw$v" "$t/dbgtarget.c"
		"${gcc16}g++" $sys16 -O2 -g -gdwarf-$v -o "$bin/cxx-gcc16-dw$v" "$t/dbgtarget-cxx.cpp"
		programs+=(c-gcc16 cxx-gcc16)
	fi
	if command -v clang > /dev/null && command -v ld.lld > /dev/null; then
		for o in O0 O2; do
			clang --target=aarch64-unknown-haiku -isystem "$headers/posix" -isystem "$headers" \
				-isystem "$headers/os" -$o -g -gdwarf-$v -fuse-ld=lld -nostdlib \
				-Wl,--unresolved-symbols=ignore-all -Wl,-e,main -o "$bin/c-clang$o-dw$v" \
				"$t/dbgtarget.c"
			programs+=(c-clang$o)
		done
	fi
done
programs=($(printf '%s\n' "${programs[@]}" | sort -u))

fail=0
check_rows() {	# FILE LABEL
	python3 -I "$here/line-oracle.py" "$1" | sed 's/ prologue_end$//' | sort > "$out/oracle.rows"
	"$new" "$1" 2> "$out/$2.err" > "$out/$2.dump"
	grep '^  row ' "$out/$2.dump" | sed 's/ prologue_end$//' | sort > "$out/new.rows"
	local d; d=$(diff "$out/new.rows" "$out/oracle.rows" | grep -c '^[<>]')
	local units; units=$(head -n 1 "$out/$2.dump" | sed 's/.*load //')
	if [ "$d" = 0 ]; then
		echo "ok    rows   $2: $(wc -l < "$out/new.rows") rows ($units)"
	else
		echo "FAIL  rows   $2: $d rows differ from llvm-dwarfdump ($units)"; fail=1
	fi
	python3 -I "$here/decl-oracle.py" "$1" | sort -u > "$out/oracle.decl"
	sed -nE 's/^  function .* \[(0x[0-9a-f]+)-[^ ]* decl (.*)$/\1 \2/p' "$out/$2.dump" | sort -u \
		> "$out/new.decl"
	d=$(comm -23 "$out/new.decl" "$out/oracle.decl" | wc -l)
	if [ "$d" = 0 ]; then
		echo "ok    decl   $2: $(wc -l < "$out/new.decl") function declaration lines"
	else
		echo "FAIL  decl   $2: $d of $(wc -l < "$out/new.decl") function declarations differ" \
			"from llvm-dwarfdump"; fail=1
	fi
}
normalize() {
	grep -v '^file \|^  file [0-9]*: \|^  dir ' "$1" | sed 's/: error .*/: unavailable/'
}
for p in "${programs[@]}"; do
	for v in 4 5; do
		check_rows "$bin/$p-dw$v" "$p-dw$v"
	done
	d=$(diff <(normalize "$out/$p-dw4.dump") <(normalize "$out/$p-dw5.dump") | grep -c '^[<>]')
	summary="$(tail -n 1 "$out/$p-dw5.dump")"
	if [ "$d" = 0 ]; then
		echo "ok    4 vs 5 $p: same ($summary)"
	else
		echo "FAIL  4 vs 5 $p: $d lines differ (diff $out/$p-dw4.dump $out/$p-dw5.dump)"; fail=1
	fi
	if [ -n "$base" ] && [ "${p#*clang}" = "$p" ] && [ "$(readelf --debug-dump=info,rawline "$bin/$p-dw4" 2>/dev/null \
			| grep -c 'Version: *5')" = 0 ]; then
		"$base" "$bin/$p-dw4" > "$out/$p-dw4.base" 2> /dev/null
		if cmp -s "$out/$p-dw4.base" "$out/$p-dw4.dump"; then
			echo "ok    base   $p-dw4: same output as the base reader"
		elif diff <(normalize "$out/$p-dw4.base") <(normalize "$out/$p-dw4.dump") > /dev/null; then
			echo "ok    base   $p-dw4: same output as the base reader but the file table," \
				"language or error codes ($(diff "$out/$p-dw4.base" "$out/$p-dw4.dump" \
				| grep -c '^>') lines)"
		else
			echo "FAIL  base   $p-dw4: differs from the base reader"; fail=1
		fi
	fi
done

for lib in "$root/artifacts/sysroot-arm64/boot/system/lib/libstdc++.so.6.0.32" \
		"$g16root/artifacts/sysroot-arm64/boot/system/lib/libstdc++.so.6.0.36"; do
	[ -f "$lib" ] || continue
	label="$(basename "$lib")"
	check_rows "$lib" "$label"
	readelf_units=$(readelf --debug-dump=info "$lib" 2>/dev/null | grep -c 'Compilation Unit @')
	echo "      units  $label: readelf $readelf_units; $(tail -n 1 "$out/$label.dump")"
done
exit $fail

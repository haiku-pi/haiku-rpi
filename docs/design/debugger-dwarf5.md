# DWARF 5 in Haiku's Debugger (KNOWN-ISSUES F9)

Goal (F9, 11-02): libraries and programs built with DWARF 5 get the same source information in the
Debugger (functions, source lines, variables, stack traces with source locations) as DWARF 4 builds;
libstdc++ frames show source information. Host and QEMU only; the Pi check is at the end.

**Result:** haiku branch **`dwarf5`** (from rpi4 46a18aecb4, pushed to origin, 7 commits, below). A
`-gdwarf-5` build of a C and of a C++ program gives the same Debugger output as its `-gdwarf-4` build, on
the host (every line row and function declaration checked against llvm-dwarfdump; GCC 13, GCC 16, clang)
and in QEMU (the Debugger's command line and its debug reports); libstdc++ loads all its units with the
right files.

## What was wrong

Upstream (all of it is in rpi4; `git log rpi4..upstream/master -- src/kits/debugger` is empty) had begun
DWARF 5: unit header parsing, the v5 line number program header, `strx`/`addrx` forms, `implicit_const`,
tag/attribute names. Missing or wrong:

1. **Version 5 units were rejected and parsing stopped there** (`DwarfFile.cpp`: "Unsupported compilation
   unit version: 5", then `break`): a `-gdwarf-5` program had no debug information at all, and every
   library lost the units after the first version 5 one. libstdc++ 6.0.32 (GCC 13) is DWARF 4 except
   libgcc's `lse.S` units (GNU as writes version 5 units for assembler sources): 189 of 216 units loaded.
2. **The line number program header of version 5 was misread, also in DWARF 4 units — the real cause of
   F9's "libstdc++ shows no source information".** GCC (13 and 16) writes version 5 line tables even with
   `-gdwarf-4`: 215 of libstdc++'s 216 line tables are version 5. Their file entries count from 0 (the
   primary file, usually repeated as entry 1), DWARF 4's from 1, and directory entry 0 is the compilation
   directory, which the reader added a second time in front: every row's file and every
   `DW_AT_decl_file` was the entry before the right one (a function of `basic_string.h` was filed under
   the header listed before it), every directory index one off. On the host the old reader gets nearly
   all of libstdc++'s 194 308 rows wrong against llvm-dwarfdump (359 695 diff lines) and 4 758 of its
   4 933 function declarations; in QEMU the system's Debugger names libstdc++'s `thread.cc` under the
   build's `obj/` directory instead of `src/gcc/` (below). Also the directory and file counts are ULEB128, not bytes (C++ units have more than 127
   files), and any field but path/directory/time/size/MD5 failed the whole table.
3. No `.debug_rnglists`/`.debug_loclists` (DWARF 5 range and location lists): a version 5 unit with code in
   several sections (any C++ unit, `.text.startup`) had no address ranges, optimised code no variable
   locations.
4. `DW_AT_str_offsets_base`/`addr_base` were ignored (the indexed forms read the section's first
   contribution), no `rnglistx`/`loclistx`, no `data16` (a 16 byte constant: "Unsupported attribute form",
   the whole file failed), no DWARF 5 type units (`DW_UT_type`, in `.debug_info`).
5. The language codes GCC writes with `-gdwarf-5` (`DW_LANG_C11`, `DW_LANG_C_plus_plus_14`; clang also
   with `-gdwarf-4`) were "unsupported": no C/C++ language for expressions.
6. Expression operations `DW_OP_addrx`, `DW_OP_constx`; `DW_OP_entry_value` warned as unknown on every
   evaluation.
7. clang names include directories relative to the compilation directory (DWARF 4 and 5); they were used
   as they are. GCC's DWARF 4 line table names a source file twice with `-fdebug-prefix-map` (absolute,
   and relative to its directory; rows use one entry, `DW_AT_decl_file` the other): such functions had
   no source lines (seen in QEMU with the system's Debugger, below).

## What is implemented (haiku `dwarf5`)

| Commit | |
|---|---|
| b67b55acf7 | `DW_OP_addrx`/`DW_OP_constx` through `.debug_addr` (new `DwarfExpressionEvaluationContext::GetIndexedAddress()`); `DW_OP_entry_value`, `DW_OP_implicit_pointer` and their GNU forms: an unavailable value, quietly |
| 6c71603f62 | C11/C17/C23 and C++03/11/14/17/20/23 language codes → C / C++ (`DIECompileUnitBase`, `DwarfImageDebugInfo::GetSourceLanguage()`) |
| d2d2349f2c | version 5 units: compile and partial units, `DW_UT_type` units in `.debug_info` (`_UnitSection()`), skeleton/split units skipped with a warning, unknown versions skipped instead of ending the parse; `BaseUnit` knows its version and its `DW_AT_str_offsets_base`/`addr_base`/`rnglists_base`/`loclists_base` (recorded in the first pass, the indexed forms resolved in the second); `rnglistx`/`loclistx` → section offsets; `data16` as a 16 byte block; the supplementary-file forms skipped; bounds and byte order of the indexed reads |
| 65cae45a13 | line number program headers of version 5 (in any unit): `CompilationUnit::AddFileEntry()`/`FileIndex()` map file numbers to the file list (entries naming the same path share a file), used by `LineNumberProgram` and `DwarfUtils::GetDeclarationLocation()`; directory 0 from the header; ULEB128 counts; unknown fields skipped; `strx` paths; program size |
| 4588cddb87 | `.debug_rnglists` (`DW_RLE_*`) and `.debug_loclists` (`DW_LLE_*`, default location, ULEB128 expression lengths, GNU view pairs skipped), chosen by the unit's version |
| a36ea1ed3b | include directories relative to the compilation directory made absolute |
| 1b4e49fd6c | DWARF 2-4 file numbers mapped the same way: entries with the same path share one file |

DWARF 2–4: units and line tables of version 2–4 are read as before (host: identical output to the old
reader on GCC's DWARF 4 builds). Intended differences for DWARF 4 input: the version 5 line tables GCC
writes for DWARF 4 units are now read right (item 2), a file named twice is one file, `DW_OP_GNU_entry_value`
fails without a warning (B_UNSUPPORTED instead of B_BAD_DATA), clang's `DW_LANG_C11` and relative
directories are understood.

## Tests

### Host (no Haiku needed): `tools/dwarf-host/`

`dwarfdump` is the Debugger's DWARF reader (`src/kits/debugger/dwarf/`, ElfFile, the address range and
value location types) compiled for Linux with Haiku's build compatibility headers and linked against the
main tree's `libbe_build.so`/`libroot_build.so`; two small header stand-ins (`include/`). It loads a file
like the Debugger (`StartLoading`/`Load`/`FinishLoading`) and prints per unit the name, compilation
directory, language, ranges, file table, every line number row, and per function (as
`DwarfImageDebugInfo::GetFunctions()` finds them) its qualified name, ranges, declaration file:line,
parameters and variables (lexical blocks too) with their locations evaluated at every row address
against a fake target.

```
tools/dwarf-host/run-tests.sh sources/haiku-dwarf5 sources/haiku     # ~20 s; output in artifacts/dwarf5/
```

builds dwarfdump, the test programs (`tools/haiku-tests/dbgtarget.c` -O0, also with
`-fdebug-prefix-map`; `dbgtarget-cxx.cpp` -O2 with a
namespace, a template, a lambda and a `std::thread` — also with `-fdebug-types-section`) with the GCC 13
and GCC 16 cross compilers and clang (`--target=aarch64-unknown-haiku`, linked by lld: clang uses `strx1`,
`addrx`, `rnglistx`, `loclistx`, which GCC does only for split DWARF), each `-gdwarf-4` and `-gdwarf-5`,
and checks:

- **rows**: every line number row (address, file path, line, column, flags) equals llvm-dwarfdump's
  (`line-oracle.py`), for all 20 programs and both libstdc++ builds;
- **decl**: every function's declaration file and line equals llvm-dwarfdump's (`decl-oracle.py`,
  following abstract origins and specifications);
- **4 vs 5**: the `-gdwarf-4` and `-gdwarf-5` builds of each program give the same output (functions,
  ranges, declarations, variables and their locations at every row) except the language code, the order of
  the file table, and *why* a location is unavailable (GCC's DWARF 5 location lists add
  `DW_OP_entry_value` ranges where its DWARF 4 lists have none: unavailable either way);
- **base**: on GCC's DWARF 4 builds (units and line tables version 4) the old reader's output, unchanged.

Result (11-02, 47 checks ok, `artifacts/dwarf5/run-tests.txt`): e.g. `cxx-gcc13`: 451 rows, 14 functions, 48 variables, same for 4 and 5;
libstdc++ 6.0.32: 216 of 216 units (old: 189), 194 308 rows, 5 032 functions, 18 685 variables;
libstdc++ 6.0.36 (GCC 16): 224 of 224 units (old: 197), 215 317 rows.

### QEMU: the Debugger itself

```
scripts/build.sh --generated sources/haiku-dwarf5/generated.arm64 libdebugger.so Debugger
scripts/dwarf5-image.sh artifacts/images/haiku-pi4-2026-11-03.img artifacts/images/haiku-pi4-dwarf5-test.img
scripts/qemu-virt.sh --image artifacts/images/haiku-pi4-dwarf5-test.img --no-copy --secs 900
grep -a DWARF5 artifacts/qemu/<ts>-virt.log
```

`dwarf5-image.sh` puts the new `Debugger` and `libdebugger.so` in `/boot/home/dwarf5` (`lib/`: the runtime
loader looks in the application's `lib/` first; the system's Debugger stays), the four test programs
(GCC 13, `-fdebug-prefix-map` to `/boot/home/dwarf5/src`, where their sources go: the Debugger shows a
source line only for a source file it finds) and the UserBootscript `tools/pi-tests/dwarf5.sh`. Each
session runs `Debugger --cli`, stops in `add3()` called from `twice()` (C) or `dbg::leaf()` in the
`std::thread` (C++), prints the stack trace, the variables of frame 0 and 1, and saves a debug report
(frames with `(file:line)` and variables), all to the serial line; then the system's Debugger on the
`-gdwarf-5` C program and the `-gdwarf-4` C++ program for comparison.

Compare a run's sessions (addresses, IDs, sizes normalised; `-gdwarf-4` against `-gdwarf-5`):
`tools/dwarf-host/compare-sessions.sh artifacts/qemu/<ts>-virt.log`.

Result (QEMU virt, 4 CPUs, image-2026-11-03 + the dwarf5 Debugger, run 20261102-223001):

| | `-gdwarf-4` | `-gdwarf-5` |
|---|---|---|
| C: CLI (break, bt, variables, print in frames 0 and 1) | 20 lines | the same 20 lines |
| C: debug report | 83 lines | the same 83 lines |
| C++: CLI | 35 lines | the same but 2 (`npos: Unavailable`, below) |
| C++: debug report | 108 lines | the same but 2 (`npos`) |

```
add3(int) + 0 (/boot/home/dwarf5/src/dbgtarget.c:9)            value: 0  result: <not set yet>
twice(int) + 0x10 (/boot/home/dwarf5/src/dbgtarget.c:20)       value: 10  first: 13  second: 0
main(void) + 0x18 (/boot/home/dwarf5/src/dbgtarget.c:29)       a: 13

dbg::leaf(int, const std::string&) + 0 (/boot/home/dwarf5/src/dbgtarget-cxx.cpp:33)      value: 10 label scaled: 10
dbg::worker(const std::vector<int, std::allocator<int> >&) + 0xb8 (.../dbgtarget-cxx.cpp:47)   accumulator {sum, count} label value
std::thread::_State_impl<...>::_M_run(void) + 0x18 (.../include/c++/13.3.0/bits/std_thread.h:-1)   this
std::execute_native_thread_routine(void*) + 0x18 (.../gccsys/src/gcc/libstdc++-v3/src/c++11/thread.cc:-1)   __p __t
pthread_thread_entry(void*, void*) + 0x18
```

(Report lines are zero-based, as the Debugger counts; `-1`: the source file is not on the target, see
Gaps.) The system's Debugger on the same image: `-gdwarf-5` C program "Unsupported compilation unit
version: 5", frames `add3 + 0`, `twice + 0x10`, `main + 0x18` (symbols only), "No variables available";
`-gdwarf-4` C++ program: argument lists, but no source line for `leaf`/`worker` (the file named twice) and
libstdc++'s `thread.cc` under `.../gccsys/obj/aarch64-unknown-haiku/libstdc++-v3/src/c++11/` (one directory
off). Three QEMU runs; in two of them one session's Debugger did not exit after `quit`/`k` once its work
was done (c-dw5 once, cxx-dw4 once; 2 of 12 sessions of the new Debugger, 0 of 4 of the system's), its
output complete; the bootscript ends a session after 240 s. Not chased (the quit path reads no DWARF).

## Gaps

- Split DWARF (skeleton/split units, `.dwo` files) and supplementary object files (`dwz`, `DW_FORM_*_sup`,
  `DW_FORM_GNU_*`): skipped / not read.
- `DW_OP_entry_value` and `DW_OP_implicit_pointer` (and GNU forms): unavailable values by design
  (recovering an entry value needs the caller's call site parameters). The typed operations
  (`DW_OP_convert`, `const_type`, `regval_type`, `deref_type` and their GNU forms, which GCC -O2 writes at
  either version) still fail as unknown opcodes.
- Older, not DWARF 5 specific (same in DWARF 4): `DwarfExpressionEvaluator::EvaluateLocation()` drops a
  composite location's first piece and pops from an empty stack for an empty piece (optimised-out part):
  such variables show as unavailable (host: 7 345 of libstdc++'s evaluations); `LineNumberProgram` clears
  `prologue_end` before returning the row (nothing uses it); with a function's source file missing on the
  target the Debugger shows its disassembly and a report has `(file:-1)` (the file, no line), by design
  of `DwarfImageDebugInfo::GetStatement()`.
- Static data members: DWARF 5 declares them as `DW_TAG_variable` in the class (DWARF 4: `DW_TAG_member`);
  the type factory takes only members, so they are not listed (with DWARF 4 they are listed, as
  "Unavailable"): the `npos` lines above.
- The Debugger's command line `bt` prints function + offset only; source locations are in `save-report`.
- `Debugger --cli` sometimes does not exit after `quit` + `k` (above).

## Pi check

On a network boot (the card holds the owner's image), under the bench lock as every cycle:

```
scripts/netboot-cycle.sh --image artifacts/images/haiku-pi4-dwarf5-test.img --secs 900 --label dwarf5 \
    --until 'DWARF5 end' --retry-wedge
grep -a 'DWARF5 [a-z0-9-]*: [0-9]* s\|DWARF5 end' artifacts/uart/*-dwarf5.log
tools/dwarf-host/compare-sessions.sh "$(ls -t artifacts/uart/*-dwarf5.log | head -n 1)"
```

Expect, as in QEMU: sessions `c-dw4`, `c-dw5`, `cxx-dw4`, `cxx-dw5` with `Breakpoint at … (add3(int))` /
`(dbg::leaf(int, const std::string&))`, `bt` with the argument lists, `print` values, a report whose
frames carry `(/boot/home/dwarf5/src/dbgtarget.c:N)` (C: add3 → twice → main; C++: leaf → worker →
lambda → `_M_run` → `std::execute_native_thread_routine(void*)` with libstdc++'s `thread.cc` path) and
variables; `old-c-dw5` with "Unsupported compilation unit version: 5" and bare symbol names; then
`DWARF5 end`; compare-sessions.sh: C 0 lines differ, C++ only the 2 `npos` lines. Rebuild the image: the
first two commands of the QEMU section (`artifacts/images/haiku-pi4-dwarf5-test.img` is built from
image-2026-11-03 and the dwarf5 branch at 1b4e49fd6c).

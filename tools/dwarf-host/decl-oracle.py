#!/usr/bin/env python3
"""decl-oracle.py — the declaration file and line of every function with code, as llvm-dwarfdump
resolves DW_AT_decl_file/DW_AT_decl_line (following DW_AT_abstract_origin and DW_AT_specification
like DwarfUtils::GetDeclarationLocation()), as "<low pc> <path>:<line - 1>" lines (zero-based, as GetDeclarationLocation() returns it), to compare with
dwarfdump's "function ... [<low pc>-...) decl <path>:<line>" (tools/dwarf-host/dwarfdump.cpp):

    tools/dwarf-host/decl-oracle.py FILE | sort > a
    dwarfdump FILE | sed -n 's/^  function .* \\[\\(0x[0-9a-f]*\\)-.* decl \\(.*\\)$/\\1 \\2/p' | sort > b
    comm -23 b a     # dwarfdump's that llvm-dwarfdump does not confirm
"""
import re
import subprocess
import sys


def main():
    text = subprocess.run(["llvm-dwarfdump", "--debug-info", sys.argv[1]], check=True,
        capture_output=True, text=True, errors="replace").stdout
    dies = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"(0x[0-9a-f]+):\s+(DW_TAG_\w+)", line)
        if m:
            current = {"tag": m.group(2)}
            dies[int(m.group(1), 16)] = current
            continue
        if current is None:
            continue
        m = re.match(r"\s+(DW_AT_\w+)\s+\((.*)\)$", line)
        if m:
            current[m.group(1)] = m.group(2)

    def attr(die, name, depth=0):
        if name in die or depth > 4:
            return die.get(name)
        for link in ("DW_AT_abstract_origin", "DW_AT_specification"):
            if link in die:
                target = dies.get(int(die[link].split()[0], 16))
                if target is not None:
                    value = attr(target, name, depth + 1)
                    if value is not None:
                        return value
        return None

    for die in dies.values():
        if die["tag"] != "DW_TAG_subprogram" or "DW_AT_low_pc" not in die:
            continue
        path = attr(die, "DW_AT_decl_file")
        line = attr(die, "DW_AT_decl_line")
        if path is None or line is None:
            continue
        print("%#x %s:%d" % (int(die["DW_AT_low_pc"], 16), path.strip('"'), int(line, 0) - 1))


main()

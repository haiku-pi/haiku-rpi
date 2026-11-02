#!/usr/bin/env python3
"""line-oracle.py — the line number rows of an ELF file as llvm-dwarfdump decodes them, printed in
dwarfdump's "row" format (tools/dwarf-host/dwarfdump.cpp), as an independent reference:

    tools/dwarf-host/line-oracle.py FILE > rows.txt
    dwarfdump FILE | grep '^  row ' | sort > a; sort rows.txt > b; diff a b

Paths are directory + "/" + name (a name that is absolute stays as it is); a DWARF 2-4 table's
directory 0 is the unit's DW_AT_comp_dir, a DWARF 5 table's is its own entry 0; the other directories
are relative to directory 0 unless absolute.
"""
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(["llvm-dwarfdump", *args], check=True, capture_output=True,
        text=True, errors="replace").stdout


def main():
    path = sys.argv[1]

    # line table offset -> compilation directory, from the unit entries
    comp_dirs = {}
    stmt = comp_dir = None
    for line in run("--debug-info", "--recurse-depth=0", path).splitlines():
        if "DW_TAG_compile_unit" in line or "DW_TAG_partial_unit" in line:
            if stmt is not None:
                comp_dirs[stmt] = comp_dir
            stmt = comp_dir = None
        m = re.search(r"DW_AT_stmt_list\s+\((0x[0-9a-f]+)\)", line)
        if m:
            stmt = int(m.group(1), 16)
        m = re.search(r'DW_AT_comp_dir\s+\("(.*)"\)', line)
        if m:
            comp_dir = m.group(1)
    if stmt is not None:
        comp_dirs[stmt] = comp_dir

    out = []
    dirs = files = None
    version = 0
    file_entry = None
    in_rows = False
    for line in run("--debug-line", path).splitlines():
        m = re.match(r"debug_line\[(0x[0-9a-f]+)\]", line)
        if m:
            offset = int(m.group(1), 16)
            dirs, files, in_rows = {}, {}, False
            if offset in comp_dirs and comp_dirs[offset] is not None:
                dirs[0] = comp_dirs[offset]
            continue
        m = re.match(r"\s+version: (\d+)", line)
        if m:
            version = int(m.group(1))
            continue
        m = re.match(r'include_directories\[\s*(\d+)\] = "(.*)"', line)
        if m:
            index, name = int(m.group(1)), m.group(2)
            if index > 0 and not name.startswith("/") and 0 in dirs:
                name = dirs[0] + "/" + name    # relative to the compilation directory
            dirs[index] = name
            continue
        m = re.match(r"file_names\[\s*(\d+)\]:", line)
        if m:
            file_entry = int(m.group(1))
            files[file_entry] = ["", 0]
            continue
        m = re.match(r'\s+name: "(.*)"', line)
        if m and file_entry is not None:
            files[file_entry][0] = m.group(1)
            continue
        m = re.match(r"\s+dir_index: (\d+)", line)
        if m and file_entry is not None:
            files[file_entry][1] = int(m.group(1))
            continue
        if line.startswith("------------------"):
            in_rows = True
            continue
        if in_rows:
            m = re.match(r"(0x[0-9a-f]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s*(.*)", line)
            if not m:
                in_rows = False
                continue
            address, row_line, column, file_number = (int(m.group(1), 16), int(m.group(2)),
                int(m.group(3)), int(m.group(4)))
            flags = m.group(5).split()
            name, dir_index = files.get(file_number, (None, 0))
            if name is None:
                file_path = "<file %d>" % file_number
            elif name.startswith("/") or dir_index not in dirs:
                file_path = name
            else:
                file_path = dirs[dir_index] + "/" + name
            out.append("  row %s %s:%d:%d%s%s%s" % ("%#x" % address if address else "0", file_path, row_line, column,
                " stmt" if "is_stmt" in flags else "", " end" if "end_sequence" in flags else "",
                " prologue_end" if "prologue_end" in flags else ""))
    print("\n".join(out))


main()

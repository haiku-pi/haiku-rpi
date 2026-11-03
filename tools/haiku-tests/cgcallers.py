#!/usr/bin/env python3
"""cgcallers.py — who calls a function, from Haiku `profile -v DIR` callgrind output (one file per
thread): sums the ticks of every call edge into functions whose name contains PATTERN, by caller,
over all files. `profile -S` only gives flat or inclusive counts; this gives the edges.

    tools/haiku-tests/cgcallers.py DIR PATTERN [--top N]
    tools/haiku-tests/cgcallers.py DIR --self [--top N]     the functions with the most self ticks (flat profile)

Pi: profile -k -l -i 250 -v cg ./program; copy cg/ back (tar).
"""
import argparse
import collections
import os
import re
import subprocess


def demangle(names):
    try:
        out = subprocess.run(["c++filt"], input="\n".join(names), capture_output=True, text=True,
                             check=True).stdout.split("\n")
        return dict(zip(names, out))
    except (OSError, subprocess.CalledProcessError):
        return {n: n for n in names}


def parse(path, edges, self_ticks):
    names = {}
    fn = cfn = None
    pending_call = False

    def resolve(spec):
        m = re.match(r"\((\d+)\)(?:\s+(.*))?", spec)
        if not m:
            return spec
        if m.group(2):
            names[m.group(1)] = m.group(2)
        return names.get(m.group(1), spec)

    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("fn="):
                fn = resolve(line[3:])
            elif line.startswith("cfn="):
                cfn = resolve(line[4:])
            elif line.startswith("calls="):
                pending_call = True
            elif line and line[0].isdigit():
                parts = line.split()
                ticks = int(parts[1]) if len(parts) > 1 else 0
                if pending_call:
                    edges[(fn, cfn)] += ticks
                    pending_call = False
                else:
                    self_ticks[fn] += ticks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("pattern", nargs="?", default="")
    parser.add_argument("--self", action="store_true", help="list the top functions by self ticks")
    parser.add_argument("--top", type=int, default=25)
    args = parser.parse_args()
    if not args.self and not args.pattern:
        parser.error("a PATTERN or --self")

    edges = collections.Counter()
    self_ticks = collections.Counter()
    for name in os.listdir(args.dir):
        if name.startswith("callgrind.out"):
            parse(os.path.join(args.dir, name), edges, self_ticks)

    if args.self:
        total = sum(self_ticks.values())
        top = self_ticks.most_common(args.top)
        pretty = demangle([f for f, _ in top])
        print("CGSELF %d self ticks" % total)
        for fn, ticks in top:
            print("%8d  %5.2f %%  %s" % (ticks, 100.0 * ticks / max(total, 1), pretty[fn][:150]))
        return

    callers = collections.Counter()
    for (caller, callee), ticks in edges.items():
        if args.pattern in callee or args.pattern in demangle([callee])[callee]:
            callers[caller] += ticks
    total_self = sum(t for f, t in self_ticks.items() if args.pattern in f)
    top = callers.most_common(args.top)
    pretty = demangle([c for c, _ in top])
    print("CGCALLERS %s: %d self ticks, %d ticks through call edges" % (
        args.pattern, total_self, sum(callers.values())))
    for caller, ticks in top:
        print("%8d  %s" % (ticks, pretty[caller][:150]))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""profsum.py — read Haiku `profile` text output (per-thread blocks, or the one `-S` summary block) and rank it.

    tools/haiku-tests/profsum.py FILE [--top N]            top functions over all blocks, as a share of the
                                                           non-idle ticks (cpu_idle excluded), plus the busiest threads
    tools/haiku-tests/profsum.py FILE --symbol NAME        ticks of functions whose name contains NAME, by thread

"Unknown" ticks (a sample in no image with symbols, also after the stack walk) are counted per block. A thread's
team is not in the output; threads are listed by name and id.
"""
import argparse
import collections
import re

HEAD = re.compile(r'^profiling results for (thread|summary) "(.*)" \((\d+)\):')
ROW = re.compile(r'^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)$')


def parse(path):
    blocks = []
    cur = None
    infuncs = False
    with open(path, errors="replace") as f:
        for line in f:
            m = HEAD.match(line)
            if m:
                cur = {"name": m.group(2), "id": int(m.group(3)), "total": 0, "unknown": 0, "funcs": []}
                blocks.append(cur)
                infuncs = False
                continue
            if cur is None:
                continue
            if line.strip().startswith("total ticks:"):
                cur["total"] = int(line.split()[2])
            elif line.strip().startswith("unknown ticks:"):
                cur["unknown"] = int(line.split()[2])
            elif "in us" in line and "function" in line:
                infuncs = True
            elif infuncs:
                m = ROW.match(line)
                if m:
                    cur["funcs"].append((int(m.group(1)), int(m.group(4)), m.group(5).strip()))
    return blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--symbol")
    args = ap.parse_args()
    blocks = parse(args.file)
    total = sum(b["total"] for b in blocks)
    idle = sum(h for b in blocks for h, _, fn in b["funcs"] if fn == "cpu_idle")
    busy = total - idle
    unknown = sum(b["unknown"] for b in blocks)
    if args.symbol:
        by = collections.Counter()
        for b in blocks:
            for h, _, fn in b["funcs"]:
                if args.symbol in fn:
                    by["%s (%d)" % (b["name"], b["id"])] += h
        s = sum(by.values())
        print("PROFSUM %s: %d ticks = %.2f %% of %d non-idle" % (args.symbol, s, 100.0 * s / max(busy, 1), busy))
        for k, v in by.most_common(args.top):
            print("%8d  %5.1f %%  %s" % (v, 100.0 * v / max(s, 1), k))
        return
    funcs = collections.Counter()
    for b in blocks:
        for h, img, fn in b["funcs"]:
            if fn != "cpu_idle":
                funcs[(fn, img)] += h
    print("PROFSUM blocks %d, ticks %d, idle %d, non-idle %d, unknown %d (%.1f %% of non-idle)" % (
        len(blocks), total, idle, busy, unknown, 100.0 * unknown / max(busy, 1)))
    print("top functions (share of non-idle ticks):")
    for (fn, img), h in funcs.most_common(args.top):
        print("%8d  %5.2f %%  [%d] %s" % (h, 100.0 * h / max(busy, 1), img, fn[:120]))
    if len(blocks) > 1:
        print("busiest threads (ticks, of which unknown):")
        ranked = sorted(blocks, key=lambda b: b["total"] - sum(h for h, _, fn in b["funcs"] if fn == "cpu_idle"),
            reverse=True)
        for b in ranked[:args.top]:
            t = b["total"] - sum(h for h, _, fn in b["funcs"] if fn == "cpu_idle")
            print("%8d  %5.2f %%  unknown %6d  %s (%d)" % (t, 100.0 * t / max(busy, 1), b["unknown"], b["name"], b["id"]))


if __name__ == "__main__":
    main()

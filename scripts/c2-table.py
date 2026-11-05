#!/usr/bin/env python3
"""c2-table.py — the C2 read-ahead A/B (perf-round-h20.md C2) from the serial logs of tools/pi-tests/c2.sh card
boots: per side, the cold (round 1) window time of each application per boot and its median, the warm median
(rounds 2..), the mapped-file fault-in rates, the content checks, the card's raw read times, and the boot
milestones (loader -> desktop cursor, as scripts/boot-times.sh).

  scripts/c2-table.py --a LOG... --b LOG...
"""
import re
import statistics
import sys


def parse(path):
    r = {"cold": {}, "warm": {}, "rate": {}, "disk": {}, "mmap": None, "read": None, "cursor": None, "bad": 0}
    loader = None
    for line in open(path, errors="replace"):
        m = re.match(r"\[\s*([0-9.]+)\]", line)
        t = float(m.group(1)) if m else None
        if loader is None and "to the Haiku boot loader" in line:
            loader = t
        if loader is not None and r["cursor"] is None and "hardware cursor shown" in line:
            r["cursor"] = t - loader
        if re.search(r"PANIC|debug_server|kernel debugger.*entered", line):
            r["bad"] += 1
        m = re.search(r"C2 launch (\S+)-(\d+): window (\d+) ms", line)
        if m:
            app, rnd, ms = m.group(1), int(m.group(2)), int(m.group(3))
            (r["cold"] if rnd == 1 else r["warm"]).setdefault(app, []).append(ms)
        m = re.search(r"C2 mmap rate (\S+) .* ([0-9.]+) MB/s", line)
        if m:
            r["rate"][m.group(1)] = float(m.group(2))
        m = re.search(r"C2 mmap ok (\d+) bad (\d+)", line)
        if m:
            r["mmap"] = (int(m.group(1)), int(m.group(2)))
        m = re.search(r"C2 read check (\d+) ok of (\d+)", line)
        if m:
            r["read"] = (int(m.group(1)), int(m.group(2)))
        m = re.search(r"C2 disklat: (\d+) KiB: mean ([0-9.]+) ms", line)
        if m:
            r["disk"][int(m.group(1))] = float(m.group(2))
    return r


def side(logs):
    return [parse(p) for p in logs]


def main():
    args = sys.argv[1:]
    if "--a" not in args or "--b" not in args:
        print(__doc__, file=sys.stderr)
        return 2
    ia, ib = args.index("--a"), args.index("--b")
    a = side(args[ia + 1:ib] if ia < ib else args[ia + 1:])
    b = side(args[ib + 1:] if ia < ib else args[ib + 1:ia])
    apps = []
    for r in a + b:
        for k in r["cold"]:
            if k not in apps:
                apps.append(k)

    def cell(rs, f):
        return " / ".join(f(r) for r in rs)

    print("| | A | B | B - A (medians) |")
    print("|---|---|---|---|")
    for app in apps:
        ca = [r["cold"].get(app, [None])[0] for r in a]
        cb = [r["cold"].get(app, [None])[0] for r in b]
        ma = statistics.median([x for x in ca if x is not None])
        mb = statistics.median([x for x in cb if x is not None])
        print(f"| {app} cold, per boot (median) | {' / '.join(map(str, ca))} ({ma:g}) | "
              f"{' / '.join(map(str, cb))} ({mb:g}) | {mb - ma:+g} ({(mb - ma) / ma * 100:+.1f} %) |")
        wa = [x for r in a for x in r["warm"].get(app, [])]
        wb = [x for r in b for x in r["warm"].get(app, [])]
        if wa and wb:
            ma, mb = statistics.median(wa), statistics.median(wb)
            print(f"| {app} warm median (n) | {ma:g} ({len(wa)}) | {mb:g} ({len(wb)}) | "
                  f"{(mb - ma) / ma * 100:+.1f} % |")
    for o in ("forward", "reverse", "stride", "random"):
        print(f"| mmap fault-in {o}, MB/s | {cell(a, lambda r: str(r['rate'].get(o)))} | "
              f"{cell(b, lambda r: str(r['rate'].get(o)))} | |")
    print(f"| mmap MD5 (ok, bad) | {cell(a, lambda r: str(r['mmap']))} | {cell(b, lambda r: str(r['mmap']))} | |")
    print(f"| read() check | {cell(a, lambda r: str(r['read']))} | {cell(b, lambda r: str(r['read']))} | |")
    for kib in (4, 64, 128, 1024):
        print(f"| raw read {kib} KiB, mean ms | {cell(a, lambda r: str(r['disk'].get(kib)))} | "
              f"{cell(b, lambda r: str(r['disk'].get(kib)))} | |")
    cursor = lambda r: "%.2f" % r["cursor"] if r["cursor"] is not None else "-"
    print(f"| loader -> cursor, s | {cell(a, cursor)} | {cell(b, cursor)} | |")
    print(f"| PANIC / debug_server lines | {cell(a, lambda r: str(r['bad']))} | {cell(b, lambda r: str(r['bad']))} | |")
    return 0


if __name__ == "__main__":
    sys.exit(main())

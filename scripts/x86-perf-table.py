#!/usr/bin/env python3
"""x86-perf-table.py — the H22 timing table from scripts/x86-perf.sh's runs (docs/design/x86-64-check.md §4.6).

    scripts/x86-perf-table.py [--tsv FILE] [--since YYYYmmdd-HHMMSS] IMAGE_A IMAGE_B

Reads artifacts/qemu-x86/perf.tsv (image, round, host seconds to boot 1's desktop, serial log) and each log's
"X86T perf" lines; prints a Markdown table: per metric the median of each image's runs, [min-max] and the run
count, and B/A. Lower is better for every metric. Per run, dlopen is the median of rounds 2..20 (warm) and
round 1 (cold) on its own.
"""
import argparse, os, re, statistics, sys

ap = argparse.ArgumentParser()
ap.add_argument("--tsv", default=os.path.join(os.path.dirname(__file__), "..", "artifacts/qemu-x86/perf.tsv"))
ap.add_argument("--since", default="")
ap.add_argument("images", nargs=2)
a = ap.parse_args()

runs = {img: [] for img in a.images}
for line in open(a.tsv):
    f = line.rstrip("\n").split("\t")
    if len(f) < 4 or f[0] not in runs:
        continue
    log = f[3]
    if os.path.basename(log)[:15] < a.since:
        continue
    runs[f[0]].append((f[2], log))

def parse(host, log):
    m = {}
    if host not in ("?", ""):
        m["boot 1 (first boot), QEMU start to desktop, host s"] = float(host)
    text = open(log, "rb").read().decode("latin-1")
    for n in (1, 2):
        x = re.search(r"X86T perf info boot%d SYSTIME (\d+)" % n, text)
        if x:
            m["boot %d%s, kernel start to desktop, s" % (n, " (first boot)" if n == 1 else "")] = int(x.group(1)) / 1e6
    for app, rnd, ms in re.findall(r"X86T perf info launch (\S+) (cold|warm) window after (\d+) ms", text):
        m["launch %s %s, ms" % (app, rnd)] = int(ms)
    for case, us in re.findall(r"FORKBENCH (.+?) ([\d.]+) us/op", text):
        m["forkbench %s, us" % case] = float(us)
    for case, us in re.findall(r"THREADBENCH (\S+) ([\d.]+) us/op", text):
        m["threadbench %s, us" % case] = float(us)
    x = re.search(r"tlsbench: global ([\d.]+) ns, thread-local ([\d.]+) ns", text)
    if x:
        m["tlsbench global, ns"] = float(x.group(1))
        m["tlsbench thread-local (linked library), ns"] = float(x.group(2))
    x = re.search(r"tlsbench: dlopened thread-local ([\d.]+) ns", text)
    if x:
        m["tlsbench thread-local (dlopened), ns"] = float(x.group(1))
    for lib in ("libbe.so", "libtracker.so", "PNGTranslator"):
        v = [float(t) for t in re.findall(r"X86T perf out dlopentime-%s: dlopentime: \S+: dlopen ([\d.]+) ms"
            % re.escape(lib), text)]
        if v:
            m["dlopen %s first, ms" % lib] = v[0]
            if len(v) > 1:
                m["dlopen %s warm (median of the rest), ms" % lib] = statistics.median(v[1:])
    return m

data = {img: [parse(h, l) for h, l in runs[img]] for img in a.images}
keys = []
for img in a.images:
    for m in data[img]:
        for k in m:
            if k not in keys:
                keys.append(k)

def cell(vals):
    if not vals:
        return "—", None
    med = statistics.median(vals)
    fmt = (lambda v: "%.2f" % v) if med < 100 else (lambda v: "%.0f" % v)
    return "%s [%s–%s] (%d)" % (fmt(med), fmt(min(vals)), fmt(max(vals)), len(vals)), med

A, B = a.images
print("| metric | %s median [min–max] (runs) | %s median [min–max] (runs) | %s / %s |" % (A, B, B, A))
print("|---|---|---|---|")
for k in keys:
    ca, ma = cell([m[k] for m in data[A] if k in m])
    cb, mb = cell([m[k] for m in data[B] if k in m])
    ratio = "%.2f" % (mb / ma) if ma and mb is not None else "—"
    print("| %s | %s | %s | %s |" % (k, ca, cb, ratio))

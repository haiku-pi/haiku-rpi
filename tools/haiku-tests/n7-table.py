#!/usr/bin/env python3
"""n7-table.py — the A/B table of H20 item N7 (docs/design/perf-round-h20.md "N7 results") from the outputs of
scripts/n7-wifi.sh (artifacts/h20-n7/LABEL.txt, LABEL-up.prof, LABEL-down.prof).

    tools/haiku-tests/n7-table.py --a LABEL... --b LABEL... [--dir artifacts/h20-n7]

Per direction and side: TCP Mbit/s; PMU cycles of all CPUs during the transfer (they stop in WFI, so they include
interrupt handlers that the scheduler books to an idle CPU) per MiB moved; "CPUs busy" (scheduler); from the one
profiled transfer per boot: the non-idle share of the ticks and the share of `spin` + `system_time` (the busy-wait;
spin() loops on system_time()) and of the sdhci module in the non-idle ticks. Medians over all transfers of a side.
"""
import argparse
import os
import re
import statistics

TP = re.compile(r'N7 \S+ (up|down) (\d+): tcp_throughput: \w+ (\d+) bytes in ([\d.]+) s: .*\(([\d.]+) Mbit/s\)')
CYC = re.compile(r'N7 \S+ (up|down) (\d+) pmu: ([\d,]+)\s+cycles .*CPUs busy ([\d.]+) %')
ELA = re.compile(r'N7 \S+ (up|down) (\d+) pmu: ([\d.]+)\s+seconds elapsed')
PIN = re.compile(r'N7 \S+ (up|down) pinned\d+: tcp_throughput: .*\(([\d.]+) Mbit/s\)')
PKC = re.compile(r'N7 \S+ (up|down) pinned\d+ pmu: ([\d,]+)\s+cpu_cycles')
PKI = re.compile(r'N7 \S+ (up|down) pinned\d+ pmu: ([\d,]+)\s+inst_retired')
CLK = re.compile(r'N7 \S+ (up|down) \d+ clock: (.*)$')
BRING = re.compile(r'bringup: ok \S+, associated after (\d+) ms \(joins (\d+)\), address after (\d+) ms')
ROW = re.compile(r'^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)$')
IMG = re.compile(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*$')


def prof(path):
    """(non-idle share, spin+system_time share of non-idle, sdhci share of non-idle) of a -S profile"""
    total = idle = spin = 0
    images = {}
    sdhci_id = None
    infuncs = False
    with open(path, errors="replace") as f:
        for line in f:
            if line.strip().startswith("total ticks:"):
                total = int(line.split()[2])
            elif "in us" in line and "function" in line:
                infuncs = True
            elif not infuncs:
                m = IMG.match(line)
                if m:
                    images[int(m.group(3))] = (os.path.basename(m.group(4)), int(m.group(1)))
            else:
                m = ROW.match(line)
                if m:
                    hits, func = int(m.group(1)), m.group(5).strip()
                    if func == "cpu_idle":
                        idle += hits
                    elif func in ("spin", "system_time"):
                        spin += hits
    sdhci = sum(h for name, h in images.values() if name == "sdhci")
    busy = total - idle
    return busy / total, spin / busy, sdhci / busy


def side(labels, d):
    r = {"up": {}, "down": {}}
    for k in r:
        r[k] = {"pkc": [], "pki": [], "clk750": [], "pinned": [], "mbit": [], "cyc_mib": [], "busy": [], "nonidle": [], "spin": [], "sdhci": []}
    bring = []
    for label in labels:
        txt = open(os.path.join(d, label + ".txt"), errors="replace").read().splitlines()
        nbytes = {}
        for line in txt:
            m = TP.search(line)
            if m:
                r[m.group(1)]["mbit"].append(float(m.group(5)))
                nbytes[(m.group(1), m.group(2))] = int(m.group(3))
            m = CYC.search(line)
            if m:
                key = (m.group(1), m.group(2))
                cyc = int(m.group(3).replace(",", ""))
                r[m.group(1)]["cyc_mib"].append(cyc / (nbytes.get(key, 64 << 20) / (1 << 20)) / 1e6)
                r[m.group(1)]["busy"].append(float(m.group(4)))
            m = PIN.search(line)
            if m:
                r[m.group(1)]["pinned"].append(float(m.group(2)))
            m = PKC.search(line)
            if m:
                r[m.group(1)]["pkc"].append(int(m.group(2).replace(",", "")) / 64 / 1e6)
            m = PKI.search(line)
            if m:
                r[m.group(1)]["pki"].append(int(m.group(2).replace(",", "")) / 64 / 1e6)
            m = CLK.search(line)
            if m:
                c = [int(x) for x in m.group(2).split()[0::3]]
                f = [int(x) for x in m.group(2).split()[2::3]]
                n = sum(c)
                r[m.group(1)]["clk750"].append(100 * sum(x for x, y in zip(c, f) if y < 1500) / n if n else 0)
            m = BRING.search(line)
            if m:
                bring.append((int(m.group(1)), int(m.group(2)), int(m.group(3))))
        for k in ("up", "down"):
            p = os.path.join(d, "%s-%s.prof" % (label, k))
            if os.path.exists(p):
                n, s, h = prof(p)
                r[k]["nonidle"].append(100 * n)
                r[k]["spin"].append(100 * s)
                r[k]["sdhci"].append(100 * h)
    return r, bring


def fmt(v, nd=1):
    if not v:
        return "—"
    return "%.*f (%s)" % (nd, statistics.median(v), ", ".join("%.*f" % (nd, x) for x in v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", nargs="+", required=True)
    ap.add_argument("--b", nargs="+", required=True)
    ap.add_argument("--dir", default="artifacts/h20-n7")
    a = ap.parse_args()
    A, ba = side(a.a, a.dir)
    B, bb = side(a.b, a.dir)
    rows = [("TCP Mbit/s", "mbit", 1), ("PMU cycles per MiB (M)", "cyc_mib", 1), ("CPUs busy (scheduler) %", "busy", 1),
            ("profile: non-idle % of ticks", "nonidle", 1), ("profile: spin + system_time % of non-idle", "spin", 1),
            ("profile: sdhci module % of non-idle", "sdhci", 1),
            ("ARM clock samples below 1500 MHz, %", "clk750", 0),
            ("TCP Mbit/s, ARM clock held at 1500 MHz", "pinned", 1),
            ("same, kernel cycles per MiB (M)", "pkc", 1),
            ("same, kernel instructions per MiB (M)", "pki", 1)]
    print("| median (values) | A up | B up | A down | B down |")
    print("|---|---|---|---|---|")
    for name, key, nd in rows:
        print("| %s | %s | %s | %s | %s |" % (name, fmt(A["up"][key], nd), fmt(B["up"][key], nd),
                                           fmt(A["down"][key], nd), fmt(B["down"][key], nd)))
    for n, br in (("A", ba), ("B", bb)):
        print("%s bring-up: %d ok; associated ms %s; address ms %s; joins %s" % (
            n, len(br), [x[0] for x in br], [x[2] for x in br], [x[1] for x in br]))


if __name__ == "__main__":
    main()

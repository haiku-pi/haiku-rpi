#!/usr/bin/env python3
"""c4b-table.py — the H20 C4b A/B table from scripts/c4b-round.sh outputs (artifacts/h20-c4b/LABEL.txt).

    scripts/c4b-table.py --a A1 A2 ... --b B1 B2 ...      (labels or paths)

Per row: each round's MB/s and the median, A then B, and B's median against A's. Then the integrity counts
(MD5 comparisons, fcfile content checks, checkfs "0 blocks" lines, serial PANIC/KDL lines).
"""
import argparse
import os
import re
import statistics

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ROWS = [
	("raw write 256 MiB in 1 MiB (control)", r"C4B diskwrite: seq 1024 KiB: 256.0 MiB .*?([\d.]+) MB/s", None),
	("raw read 1 MiB, disklat (control)", r"C4B raw disklat: 1024 KiB: .*?([\d.]+) MB/s", None),
	("BFS dd 128 MiB + fsync", r"C4B bfs write 128 MiB \+ fsync: .*?([\d.]+) MB/s", None),
	("BFS dd 1 GiB + fsync", r"C4B bfs write 1024 MiB \+ fsync: .*?([\d.]+) MB/s", None),
	("fcfile write 64 MiB in 4 KiB + fsync", r"C4B fcfile: write 4 KiB: 64.0 MiB .*?([\d.]+) MB/s", None),
	("fcfile write 64 MiB in 64 KiB + fsync", r"C4B fcfile: write 64 KiB: 64.0 MiB .*?([\d.]+) MB/s", None),
	("fcfile write 128 MiB in 128 KiB + fsync", r"C4B fcfile: write 128 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("fcfile write 1 GiB in 1 MiB + fsync", r"C4B fcfile: write 1024 KiB: 1024.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 1 GiB in 1 MiB", r"C4B fcfile: read 1024 KiB: 1024.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 1 GiB in 128 KiB", r"C4B fcfile: read 128 KiB: 1024.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 128 MiB in 4 KiB", r"C4B fcfile: read 4 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 128 MiB in 64 KiB", r"C4B fcfile: read 64 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 128 MiB in 128 KiB", r"C4B fcfile: read 128 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 128 MiB in 512 KiB", r"C4B fcfile: read 512 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 128 MiB in 1 MiB", r"C4B fcfile: read 1024 KiB: 128.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 64 MiB in 4 KiB (written in 4 KiB)", r"C4B fcfile: read 4 KiB: 64.0 MiB .*?([\d.]+) MB/s", None),
	("cold read 64 MiB in 64 KiB (written in 64 KiB)", r"C4B fcfile: read 64 KiB: 64.0 MiB .*?([\d.]+) MB/s", None),
	("cat 128 MiB, cold", r"C4B cat 128 MiB cold: .*?([\d.]+) MB/s", None),
	("md5sum 1 GiB, cold", r"C4B md5sum 1 GiB cold: .*?([\d.]+) MB/s", None),
	("cp 128 MiB, cold + sync", r"C4B cp 128 MiB cold \+ sync: .*?([\d.]+) MB/s", None),
	("USB: write 512 MiB in 1 MiB + fsync", r"C4B fcfile: write 1024 KiB: 512.0 MiB .*?([\d.]+) MB/s", None),
	("USB: cold read 512 MiB in 1 MiB", r"C4B fcfile: read 1024 KiB: 512.0 MiB .*?([\d.]+) MB/s", None),
	("USB: usb-bfs.sh total, s (lower is better)", r"UB total (\d+) s", None),
]


def load(label):
	path = label if os.path.exists(label) else os.path.join(ROOT, "artifacts/h20-c4b", label + ".txt")
	with open(path, errors="replace") as f:
		return os.path.basename(path).rsplit(".", 1)[0], f.read()


def values(text, regex):
	return [float(v) for v in re.findall(regex, text)]


def fmt(vals):
	return " / ".join("%g" % v for v in vals)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--a", nargs="+", required=True)
	ap.add_argument("--b", nargs="+", required=True)
	args = ap.parse_args()
	a = [load(x) for x in args.a]
	b = [load(x) for x in args.b]
	print("| MB/s | A (%s) | B (%s) | B − A (medians) |" % (", ".join(n for n, _ in a), ", ".join(n for n, _ in b)))
	print("|---|---|---|---|")
	for name, regex, _ in ROWS:
		va = [v for _, t in a for v in values(t, regex)]
		vb = [v for _, t in b for v in values(t, regex)]
		if not va and not vb:
			continue
		ma = statistics.median(va) if va else None
		mb = statistics.median(vb) if vb else None
		diff = "%+.1f %%" % ((mb - ma) / ma * 100) if ma and mb else ""
		print("| %s | %s (**%g**) | %s (**%g**) | %s |" % (name, fmt(va), ma or 0, fmt(vb), mb or 0, diff))
	print()
	for side, rounds in (("A", a), ("B", b)):
		t = "".join(x for _, x in rounds)
		print("%s: MD5 same %d, DIFFERENT %d; fcfile content ok %d, bad %d; checkfs '0 blocks' lines %d (of %d); "
			"serial PANIC/debug_server/KDL %s" % (side,
				len(re.findall(r"md5.*\bsame\b", t)),
				len(re.findall(r"DIFFERENT", t)),
				len(re.findall(r"content ok", t)), len(re.findall(r"bad bytes", t)),
				len(re.findall(r"checkfs: \s*0 blocks", t)), len(re.findall(r"checkfs: \s*\d+ blocks", t)),
				",".join(re.findall(r"PANIC\|debug_server\|KDL lines: (\d+)", t))))


if __name__ == "__main__":
	main()

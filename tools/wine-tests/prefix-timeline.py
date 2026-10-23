#!/usr/bin/env python3
"""prefix-timeline.py FILE.timeline — per-process wall and CPU times from tools/pi-tests/prefix-timeline.sh.

Each sample is Haiku's `ps -a`: a team line (command line, id, threads, gid, uid) followed by its threads
(name, id, state, priority, user ms, kernel ms). A team's CPU time is the largest sum over its threads seen
in one sample, so threads that ended between samples are missed: a lower bound. Prints one line per team
that ran Wine, in order of first appearance, then the sums.
"""
import sys

teams = {}
order = []
t = 0
team = None
for line in open(sys.argv[1], errors="replace"):
	f = line.split()
	if not f:
		continue
	if f[0] == "SAMPLE":
		t = int(f[1])
		team = None
		continue
	if len(f) >= 5 and all(x.isdigit() for x in f[-4:]):
		tid = int(f[-4])
		args = line.rsplit(None, 4)[0].strip()
		team = teams.get(tid)
		if team is None:
			team = teams[tid] = {"args": args, "first": t, "last": t, "cpu": 0, "sample": {}}
			order.append(tid)
		team["last"] = t
		team["sample"] = {}
		continue
	if team is not None and len(f) >= 6 and f[-1].isdigit() and f[-2].isdigit():
		team["sample"][f[-5]] = int(f[-2]) + int(f[-1])
		team["cpu"] = max(team["cpu"], sum(team["sample"].values()))

total = {"system32": 0, "syswow64": 0, "other": 0}
print(f"{'first':>5} {'wall':>5} {'cpu s':>7}  command")
for tid in order:
	tm = teams[tid]
	if "wine" not in tm["args"]:
		continue
	kind = "syswow64" if "syswow64" in tm["args"].lower() else \
		"system32" if "system32" in tm["args"].lower() else "other"
	total[kind] += tm["cpu"]
	print(f"{tm['first']:5d} {tm['last'] - tm['first'] + 2:5d} {tm['cpu'] / 1000:7.1f}  {tm['args']}")
print("cpu s by kind:", {k: round(v / 1000, 1) for k, v in total.items()})

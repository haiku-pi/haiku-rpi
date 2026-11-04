#!/usr/bin/env python3
"""kdl-x86.py — type kernel debugger commands into a Haiku x86-64 guest's COM1 (scripts/qemu-x86.sh --serial-sock).

    scripts/kdl-x86.py SOCK LOG [--wait REGEX] [--timeout S] CMD...

Waits until LOG (the run's serial log) shows the KDL prompt ("kdebug>"; or REGEX first, then the prompt), then
sends each CMD followed by a newline, waiting for the next prompt (at most 20 s) before the next. A CMD may name
values from REGEX's named groups, e.g. --wait 'DD=(?P<dd>\\d+)' 'bt {dd}'. The output lands in LOG.
"""
import argparse, re, socket, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("sock"); ap.add_argument("log")
ap.add_argument("--wait", default=None); ap.add_argument("--timeout", type=float, default=300)
ap.add_argument("cmds", nargs="*")
a = ap.parse_args()

def text():
    with open(a.log, "rb") as f:
        return f.read().decode("latin-1")

deadline = time.time() + a.timeout
values = {}
if a.wait:
    while time.time() < deadline:
        m = re.search(a.wait, text())
        if m:
            values = m.groupdict(); break
        time.sleep(0.5)
    else:
        sys.exit("kdl-x86: --wait pattern never showed")
while time.time() < deadline and "kdebug>" not in text():
    time.sleep(0.5)
if "kdebug>" not in text():
    sys.exit("kdl-x86: no KDL prompt")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(a.sock)
for cmd in a.cmds:
    cmd = cmd.format(**values)
    n = text().count("kdebug>")
    s.sendall((cmd + "\r").encode())
    t = time.time()
    while time.time() - t < 20 and text().count("kdebug>") <= n:
        try:
            s.settimeout(0.2); s.recv(65536)
        except socket.timeout:
            pass
    print("kdl-x86: sent %r" % cmd)
s.close()

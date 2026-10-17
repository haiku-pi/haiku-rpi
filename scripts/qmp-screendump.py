#!/usr/bin/env python3
"""qmp-screendump.py SOCKET OUT.png — ask a running QEMU (started with -qmp unix:SOCKET,server,nowait)
for a screenshot of its display."""
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()  # greeting
for cmd in ({"execute": "qmp_capabilities"},
            {"execute": "screendump", "arguments": {"filename": sys.argv[2], "format": "png"}}):
    f.write(json.dumps(cmd) + "\n")
    f.flush()
    while True:
        reply = json.loads(f.readline())
        if "return" in reply or "error" in reply:
            break
    if "error" in reply:
        sys.exit("qmp: %s" % reply["error"])

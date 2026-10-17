#!/usr/bin/env python3
"""qmp-hmp.py SOCKET 'monitor command' — run a human-monitor command (e.g. "info registers -a")
in a QEMU started with -qmp unix:SOCKET,server,nowait and print its output."""
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()
for cmd in ({"execute": "qmp_capabilities"},
            {"execute": "human-monitor-command", "arguments": {"command-line": sys.argv[2]}}):
    f.write(json.dumps(cmd) + "\n")
    f.flush()
    while True:
        reply = json.loads(f.readline())
        if "return" in reply or "error" in reply:
            break
print(reply.get("return", reply.get("error")))

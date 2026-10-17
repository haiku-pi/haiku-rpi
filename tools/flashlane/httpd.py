#!/usr/bin/env python3
"""httpd.py DIR PORT BIND — the flash lane's HTTP server: GET serves files from DIR (job.txt, the
image to write); POST /upload/<name> stores the request body as DIR/upload/<name> (the card's
contents read back by the Pi, see tools/flashlane/init MODE=read)."""
import http.server
import os
import shutil
import sys

ROOT = os.path.abspath(sys.argv[1])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_POST(self):
        name = os.path.basename(self.path)
        if not self.path.startswith("/upload/") or not name or name.startswith("."):
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        os.makedirs(os.path.join(ROOT, "upload"), exist_ok=True)
        target = os.path.join(ROOT, "upload", name)
        with open(target + ".part", "wb") as out:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 1 << 20))
                if not chunk:
                    break
                out.write(chunk)
                remaining -= len(chunk)
        if remaining:
            self.send_error(400, "short upload")
            return
        shutil.move(target + ".part", target)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


http.server.ThreadingHTTPServer((sys.argv[3], int(sys.argv[2])), Handler).serve_forever()

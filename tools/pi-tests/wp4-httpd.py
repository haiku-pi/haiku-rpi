#!/usr/bin/env python3
"""wp4-httpd.py DIR [ADDRESS] [PORT] — serve DIR over HTTP to the bench Pi for the media kit's BUrl reader
(BAdapterIO, http_streamer) the way a real server would deliver it, not only at LAN speed (WP4,
docs/design/webpositive-video-overlay.md §6). The first path element picks the delivery:

  /f/FILE        full speed, with Content-Length
  /sN/FILE       throttled to N kB/s, with Content-Length (the data still arriving while the player reads)
  /n/FILE        full speed, no Content-Length (HTTP/1.0, the end of the body is the connection's close)
  /nsN/FILE      throttled to N kB/s, no Content-Length

No Range support (http_streamer reads one request from the start). One line per request on stderr: the path,
the bytes sent of the file's size, the seconds, and "complete" or "client closed". Bind it to the Pi LAN only
(default 10.42.0.1, port 8091); stop it by its PID.
"""
import http.server
import os
import re
import sys
import time

root = os.path.realpath(sys.argv[1])
address = sys.argv[2] if len(sys.argv) > 2 else '10.42.0.1'
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8091
CHUNK = 16384


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % args))

    def _resolve(self):
        m = re.match(r'^/(f|n|s\d+|ns\d+)/([^/?]+)$', self.path)
        if not m:
            return None
        path = os.path.realpath(os.path.join(root, m.group(2)))
        if os.path.dirname(path) != root or not os.path.isfile(path):
            return None
        mode = m.group(1)
        rate = int(re.sub(r'\D', '', mode) or 0) * 1024
        return path, mode.startswith('n'), rate

    def _head(self, r):
        path, nolen, _ = r
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4' if path.endswith('.mp4') else 'application/octet-stream')
        if not nolen:
            self.send_header('Content-Length', str(os.path.getsize(path)))
        self.send_header('Connection', 'close')
        self.end_headers()

    def do_HEAD(self):
        r = self._resolve()
        if r is None:
            self.send_error(404)
            return
        self._head(r)

    def do_GET(self):
        r = self._resolve()
        if r is None:
            self.send_error(404)
            return
        path, _, rate = r
        self._head(r)
        size = os.path.getsize(path)
        sent, t0, status = 0, time.monotonic(), 'complete'
        try:
            with open(path, 'rb') as f:
                while True:
                    data = f.read(CHUNK)
                    if not data:
                        break
                    self.wfile.write(data)
                    sent += len(data)
                    if rate:
                        ahead = sent / rate - (time.monotonic() - t0)
                        if ahead > 0:
                            time.sleep(ahead)
        except (BrokenPipeError, ConnectionResetError):
            status = 'client closed'
        self.log_message('%s sent %d of %d in %.1f s, %s', self.path, sent, size,
                         time.monotonic() - t0, status)


server = http.server.ThreadingHTTPServer((address, port), Handler)
sys.stderr.write('wp4-httpd: %s on http://%s:%d/ (pid %d)\n' % (root, address, port, os.getpid()))
sys.stderr.flush()
server.serve_forever()

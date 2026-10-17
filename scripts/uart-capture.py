#!/usr/bin/env python3
"""uart-capture.py - capture the Pi 4 UART to a log file.

    uart-capture.py --log FILE [--dev /dev/ttyUSB0] [--secs N] [--until REGEX]... [--fail REGEX]...
                    [--quiet-secs N] [--send SECS:TEXT]... [--echo]

Stops after --secs seconds; or as soon as a line matches an --until (exit 0) or a --fail
(exit 3) regex; or after --quiet-secs of silence once something was received (exit 4).
Exit 2 = nothing at all was received. --send types TEXT (Python escapes: \\n, \\x1d) into the
UART SECS seconds after the capture began; e.g. the kernel debugger on Haiku:
--send '200:\\x1d\\x1d\\x1dd' --send '203:threads\\n'. Lines get a "[  12.345] " host timestamp prefix
(seconds since the capture began) so boot stages can be timed; the raw bytes are kept too,
in FILE.raw.
"""
import argparse
import re
import sys
import time

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--log", required=True)
    ap.add_argument("--secs", type=float, default=120)
    ap.add_argument("--until", action="append", default=[])
    ap.add_argument("--fail", action="append", default=[])
    ap.add_argument("--quiet-secs", type=float, default=0)
    ap.add_argument("--send", action="append", default=[])
    ap.add_argument("--echo", action="store_true")
    a = ap.parse_args()

    sends = []
    for item in a.send:
        when, text = item.split(":", 1)
        sends.append((float(when), text.encode("latin-1").decode("unicode_escape").encode("latin-1")))
    sends.sort()

    until = [re.compile(p) for p in a.until]
    fail = [re.compile(p) for p in a.fail]
    port = serial.Serial(a.dev, a.baud, timeout=0.2)
    port.reset_input_buffer()
    t0 = time.monotonic()
    last_rx = None
    buf = b""
    rc = 1
    done = False
    with open(a.log, "w", encoding="utf-8", errors="replace") as log, open(a.log + ".raw", "wb") as raw:
        while not done:
            now = time.monotonic()
            if now - t0 >= a.secs:
                rc = 1 if until else 0  # timed out waiting for an --until line
                break
            if a.quiet_secs and last_rx is not None and now - last_rx >= a.quiet_secs:
                rc = 4
                break
            while sends and now - t0 >= sends[0][0]:
                for byte in sends.pop(0)[1]:
                    port.write(bytes([byte]))
                    port.flush()
                    time.sleep(0.01)
            data = port.read(4096)
            if not data:
                continue
            last_rx = time.monotonic()
            raw.write(data)
            raw.flush()
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", "replace").rstrip("\r")
                stamped = "[%8.3f] %s" % (last_rx - t0, text)
                log.write(stamped + "\n")
                log.flush()
                if a.echo:
                    print(stamped, flush=True)
                if any(r.search(text) for r in fail):
                    rc, done = 3, True
                    break
                if any(r.search(text) for r in until):
                    rc, done = 0, True
                    break
            # A prompt ("kdebug> ") has no newline: match the unterminated tail too.
            if not done and buf:
                tail = buf.decode("utf-8", "replace")
                if any(r.search(tail) for r in fail):
                    rc, done = 3, True
                elif any(r.search(tail) for r in until):
                    rc, done = 0, True
        if buf:
            log.write("[%8.3f] %s\n" % (time.monotonic() - t0, buf.decode("utf-8", "replace")))
    if last_rx is None:
        rc = 2
    print("uart-capture: rc=%d secs=%.1f log=%s" % (rc, time.monotonic() - t0, a.log), file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())

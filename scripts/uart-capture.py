#!/usr/bin/env python3
"""uart-capture.py - capture the Pi 4 UART to a log file.

    uart-capture.py --log FILE [--dev /dev/ttyUSB0] [--secs N] [--until REGEX]... [--fail REGEX]...
                    [--quiet-secs N] [--send SECS:TEXT]... [--echo]
                    [--silence-after N --silence-send OFFSET:TEXT... [--silence-arm REGEX]
                     [--silence-disarm REGEX]...] [--inbox DIR]

Stops after --secs seconds; or as soon as a line matches an --until (exit 0) or a --fail
(exit 3) regex; or after --quiet-secs of silence once something was received (exit 4).
Exit 2 = nothing at all was received. --send types TEXT (Python escapes: \\n, \\x1d) into the
UART SECS seconds after the capture began; e.g. the kernel debugger on Haiku:
--send '200:\\x1d\\x1d\\x1dd' --send '203:threads\\n'. Lines get a "[  12.345] " host timestamp prefix
(seconds since the capture began) so boot stages can be timed; the raw bytes are kept too,
in FILE.raw, and FILE.raw.times gives each chunk's arrival ("<seconds> <offset in FILE.raw> <bytes>"):
when the bytes of a line that never ended arrived.
--silence-after N: when the line has been silent for N seconds (after something was received,
once per capture), type the --silence-send texts, each OFFSET seconds after that moment: the
kernel debugger's dumps of a boot that stopped, whenever it stops. A line matching a
--silence-disarm regex (the boot got past where it stops) disarms it. With --silence-arm, the
silence only counts after a line matching that regex (e.g. the kernel's banner): a slow stage
before it (the firmware's TFTP) is not a stop, and keys typed then would land in U-Boot instead.
--inbox DIR: while capturing, each file that appears in DIR holds "OFFSET:TEXT" lines (as
--silence-send) that are typed OFFSET seconds after the file was found; the file is then removed.
scripts/uart-send.sh writes them: the kernel debugger of a system that hangs long after boot.
"""
import os
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
    ap.add_argument("--silence-after", type=float, default=0)
    ap.add_argument("--silence-send", action="append", default=[])
    ap.add_argument("--silence-disarm", action="append", default=[])
    ap.add_argument("--silence-arm")
    ap.add_argument("--inbox")
    a = ap.parse_args()

    sends = []
    for item in a.send:
        when, text = item.split(":", 1)
        sends.append((float(when), text.encode("latin-1").decode("unicode_escape").encode("latin-1")))
    sends.sort()
    silence_sends = []
    for item in a.silence_send:
        when, text = item.split(":", 1)
        silence_sends.append((float(when), text.encode("latin-1").decode("unicode_escape").encode("latin-1")))
    silence_sends.sort()
    disarm = [re.compile(p) for p in a.silence_disarm]
    armed = a.silence_after > 0 and bool(silence_sends)
    arm_at = re.compile(a.silence_arm) if a.silence_arm else None
    waiting_arm = armed and arm_at is not None

    until = [re.compile(p) for p in a.until]
    fail = [re.compile(p) for p in a.fail]
    if a.inbox:
        # texts left over from an earlier capture are not for this boot
        os.makedirs(a.inbox, exist_ok=True)
        for name in os.listdir(a.inbox):
            os.remove(os.path.join(a.inbox, name))
    port = serial.Serial(a.dev, a.baud, timeout=0.2)
    port.reset_input_buffer()
    t0 = time.monotonic()
    last_rx = None
    buf = b""
    rc = 1
    done = False
    with open(a.log, "w", encoding="utf-8", errors="replace") as log, open(a.log + ".raw", "wb") as raw, \
            open(a.log + ".raw.times", "w") as times:
        while not done:
            now = time.monotonic()
            if now - t0 >= a.secs:
                rc = 1 if until else 0  # timed out waiting for an --until line
                break
            if a.quiet_secs and last_rx is not None and now - last_rx >= a.quiet_secs:
                rc = 4
                break
            if armed and not waiting_arm and last_rx is not None and now - last_rx >= a.silence_after:
                armed = False
                log.write("[%8.3f] uart-capture: %.0f s of silence, sending the --silence-send texts\n"
                          % (now - t0, now - last_rx))
                sends = sorted(sends + [(now - t0 + off, text) for off, text in silence_sends])
            if a.inbox and os.path.isdir(a.inbox):
                for name in sorted(os.listdir(a.inbox)):
                    if name.startswith("."):
                        continue  # still being written
                    path = os.path.join(a.inbox, name)
                    try:
                        with open(path, encoding="latin-1") as f:
                            lines = [l.rstrip("\n") for l in f if ":" in l]
                        os.remove(path)
                    except OSError:
                        continue
                    for item in lines:
                        when, text = item.split(":", 1)
                        sends.append((now - t0 + float(when),
                            text.encode("latin-1").decode("unicode_escape").encode("latin-1")))
                    log.write("[%8.3f] uart-capture: %d texts from %s\n" % (now - t0, len(lines), name))
                sends.sort()
            while sends and now - t0 >= sends[0][0]:
                for byte in sends.pop(0)[1]:
                    port.write(bytes([byte]))
                    port.flush()
                    time.sleep(0.01)
            data = port.read(4096)
            if not data:
                continue
            last_rx = time.monotonic()
            times.write("%.3f %d %d\n" % (last_rx - t0, raw.tell(), len(data)))
            times.flush()
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
                if waiting_arm and arm_at.search(text):
                    waiting_arm = False
                if armed and any(r.search(text) for r in disarm):
                    armed = False
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

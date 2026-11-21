#!/usr/bin/env python3
# blender-bw-table.py — blender-bw.sh's two logs on the host: per config and bus watcher, the transaction rate
# while orbiting minus the rate in the idle window after it (same window, nothing drawn), and that per frame.
#
#   tools/pi-tests/blender-bw-table.py BBW-LOG AXB-LOG [SEL=BYTES-PER-TRANSACTION ...]
#
# With a BYTES-PER-TRANSACTION for a watcher (from a calibration, docs/design/blender.md §7.17) also MB/s and
# MB per frame. Only axibw windows wholly inside a Blender window count.
import re
import sys


def main():
    bbw, axb = sys.argv[1], sys.argv[2]
    bpt = dict(a.split("=") for a in sys.argv[3:])
    samples = []  # (t0, t1, sel, reads, writes)
    for line in open(axb, errors="replace"):
        m = re.match(r"AXB (\d+\.\d+) (\d+\.\d+) (\S+) R (\d+) W (\d+) A (\d+)", line)
        if m:
            t1 = float(m.group(1))
            samples.append((t1 - float(m.group(2)) / 1000, t1, m.group(3), int(m.group(4)), int(m.group(5))))
    sels = list(dict.fromkeys(s[2] for s in samples))
    windows = {}
    order = []
    for line in open(bbw, errors="replace"):
        m = re.match(r"BBW orbit (\S+) (\S+) (\S+) (\d+) (\S+) (\S+)", line)
        if m:
            c = m.group(1)
            order.append(c)
            windows[c] = {"orbit": (float(m.group(2)), float(m.group(3))), "frames": int(m.group(4)),
                          "ms": float(m.group(5)), "viewport": m.group(6)}
        m = re.match(r"BBW idle (\S+) (\S+) (\S+)", line)
        if m:
            windows[m.group(1)]["idle"] = (float(m.group(2)), float(m.group(3)))

    def rate(sel, t0, t1):
        r = w = secs = 0.0
        for s in samples:
            if s[2] == sel and s[0] >= t0 and s[1] <= t1:
                r += s[3]
                w += s[4]
                secs += s[1] - s[0]
        return (r / secs, w / secs) if secs > 0 else (float("nan"), float("nan"))

    for c in order:
        win = windows[c]
        print("%s: %.1f ms/frame (%.2f fps), %d frames, viewport %s" % (c, win["ms"], 1000 / win["ms"],
                                                                       win["frames"], win["viewport"]))
        for sel in sels:
            ro, wo = rate(sel, *win["orbit"])
            ri, wi = rate(sel, *win["idle"]) if "idle" in win else (0.0, 0.0)
            dr, dw = ro - ri, wo - wi
            fr = win["ms"] / 1000
            line = "  %-16s orbit R %6.2fM/s W %6.2fM/s | idle R %6.2fM/s W %6.2fM/s | per frame +R %6.2fM +W %6.2fM" % (
                sel, ro / 1e6, wo / 1e6, ri / 1e6, wi / 1e6, dr * fr / 1e6, dw * fr / 1e6)
            if sel in bpt:
                b = float(bpt[sel])
                line += " | %.0f+%.0f MB/s, %.1f+%.1f MB/frame" % (ro * b / 1e6, wo * b / 1e6, dr * fr * b / 1e6,
                                                                   dw * fr * b / 1e6)
            print(line)


main()

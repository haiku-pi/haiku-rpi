#!/usr/bin/env python3
"""wavtone.py — what a recorded WAV file holds: per channel the RMS level, the frequency by zero
crossings, and with --expect HZ the share of the signal's power at that frequency (Goertzel), to
check a test tone played on the Pi and recorded on the bench host (the HDMI capture card's audio
input: arecord -D hw:3,0 -f S16_LE -r 48000 -c 2 -d 5 out.wav).

    tools/media-tests/wavtone.py FILE.wav [--expect HZ] [--skip SECONDS]

Prints "WAVTONE ch0 rms R freq F [power-at-HZ P%]" per channel and "WAVTONE PASS|FAIL" with
--expect (PASS: every channel has rms > 300 and > 80 % of its power within ±1 % of HZ).
"""
import argparse
import math
import struct
import sys
import wave


def goertzel_share(samples, rate, freq):
    """the share of the signal's power in a narrow band around freq"""
    n = len(samples)
    if n == 0:
        return 0.0
    total = sum(s * s for s in samples) / n
    if total == 0:
        return 0.0
    best = 0.0
    # scan ±1 % in 0.1 % steps: the two clocks (the Pi's and the capture card's) differ slightly
    for step in range(-10, 11):
        f = freq * (1 + step / 1000.0)
        w = 2 * math.pi * f / rate
        coeff = 2 * math.cos(w)
        s1 = s2 = 0.0
        for x in samples:
            s0 = x + coeff * s1 - s2
            s2, s1 = s1, s0
        power = (s1 * s1 + s2 * s2 - coeff * s1 * s2) * 2 / (n * n)
        best = max(best, power)
    return min(1.0, best / total)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("file")
    parser.add_argument("--expect", type=float)
    parser.add_argument("--skip", type=float, default=0.5)
    args = parser.parse_args()

    with wave.open(args.file) as w:
        channels, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        if width != 2:
            sys.exit("wavtone: 16-bit files only")
        w.setpos(min(w.getnframes(), int(args.skip * rate)))
        data = w.readframes(w.getnframes())
    count = len(data) // 2
    values = struct.unpack("<%dh" % count, data[:count * 2])

    ok = True
    for ch in range(channels):
        samples = values[ch::channels]
        if not samples:
            ok = False
            continue
        mean = sum(samples) / len(samples)
        samples = [s - mean for s in samples]
        rms = math.sqrt(sum(s * s for s in samples) / len(samples))
        crossings = sum(1 for a, b in zip(samples, samples[1:]) if a < 0 <= b)
        freq = crossings * rate / len(samples)
        line = "WAVTONE ch%d rms %.0f freq %.1f" % (ch, rms, freq)
        if args.expect:
            # Goertzel over at most 1 s keeps this quick in pure Python
            share = goertzel_share(samples[:rate], rate, args.expect)
            line += " power-at-%g %.0f%%" % (args.expect, share * 100)
            ok = ok and rms > 300 and share > 0.8
        print(line)
    if args.expect:
        print("WAVTONE %s" % ("PASS" if ok else "FAIL"))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

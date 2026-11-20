#!/usr/bin/env python3
"""colour-bars.py SHOT.png [REFERENCE.png] — finds 75 % colour bars (tools/media-tests/gen-colour-clips.sh: white
yellow cyan green magenta red blue black; white 100 %, the others 75 % = 191) anywhere in an HDMI snapshot (MediaPlayer's window, scaled or not) and
prints the colour at each bar's centre (a 9x9 mean). With REFERENCE (the same clip shown another way, e.g. through
the RGB path), also the largest per-channel difference: "max diff N" (the overlay check: N <= 3). Always the
largest difference from the ideal 75 % bars too ("ideal diff", which includes the capture chain's own error).
Exit status 1 when no bars are found."""
import struct, sys, zlib

def png_rgb(path):
    data = open(path, 'rb').read()
    pos, idat = 8, b''
    while pos < len(data):
        n, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
            bpp = 3 if ctype == 2 else 4
        elif typ == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, bpp, rows

ORDER = ['W', 'Y', 'C', 'G', 'M', 'R', 'B', 'K']
IDEAL = [(255, 255, 255), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]

def classify(p):
    on = [v > 100 for v in p[:3]]
    if all(v < 60 for v in p[:3]): return 'K'
    return {(1, 1, 1): 'W', (1, 1, 0): 'Y', (0, 1, 1): 'C', (0, 1, 0): 'G', (1, 0, 1): 'M', (1, 0, 0): 'R',
            (0, 0, 1): 'B'}.get(tuple(int(v) for v in on), '?')

def find_bars(img):
    w, h, bpp, rows = img
    for y in list(range(h // 2, h - 5, 7)) + list(range(h // 2, 5, -7)):
        line = rows[y]
        segs, start, cur = [], 0, None
        for x in range(w):
            c = classify(line[x * bpp:x * bpp + 3])
            if c != cur:
                if cur is not None: segs.append((cur, start, x))
                cur, start = c, x
        segs.append((cur, start, w))
        segs = [s for s in segs if s[2] - s[1] >= 20]
        for i in range(len(segs) - 7):
            if [s[0] for s in segs[i:i + 8]] == ORDER:
                widths = [s[2] - s[1] for s in segs[i:i + 7]]
                if max(widths) - min(widths) <= max(8, min(widths) // 5):
                    return y, segs[i:i + 8]
    return None

def centres(path):
    img = png_rgb(path)
    found = find_bars(img)
    if not found: return None
    y, segs = found
    w, h, bpp, rows = img
    out = []
    for c, x0, x1 in segs:
        cx = (x0 + x1) // 2
        s = [0, 0, 0]
        for yy in range(y - 4, y + 5):
            for xx in range(cx - 4, cx + 5):
                for k in range(3): s[k] += rows[yy][xx * bpp + k]
        out.append(tuple(round(v / 81) for v in s))
    return (segs[0][1], y, segs[-1][2] - segs[0][1]), out

shot = centres(sys.argv[1])
if shot is None:
    print(f'{sys.argv[1]}: no bars found'); sys.exit(1)
(x, y, width), bars = shot
print(f'{sys.argv[1]}: bars at x {x} y {y}, {width} wide: ' + ' '.join('%d,%d,%d' % b for b in bars))
ideal = max(abs(a - b) for bar, ib in zip(bars, IDEAL) for a, b in zip(bar, ib))
print(f'  ideal diff {ideal}')
if len(sys.argv) > 2:
    ref = centres(sys.argv[2])
    if ref is None:
        print(f'{sys.argv[2]}: no bars found'); sys.exit(1)
    diff = max(abs(a - b) for b1, b2 in zip(bars, ref[1]) for a, b in zip(b1, b2))
    print(f'  reference {sys.argv[2]}: ' + ' '.join('%d,%d,%d' % b for b in ref[1]))
    print(f'  max diff {diff}')

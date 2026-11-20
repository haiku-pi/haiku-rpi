#!/usr/bin/env python3
"""colour-probe.py PNG... — grades tools/pi-tests/colour-probe.sh's snapshots of sandprobe's color encoding
picture (`sandprobe enc CODE`): the plane at the screen's top left, 3/4 of 1280x720; top half eight 75 % bars
in BT.709 limited range, bottom half a luma ramp Y = 0 16 48 96 144 192 235 255. Prints, per snapshot, the bar
and ramp colours read (5x5 means at the centres) and which YCbCr -> RGB conversion (BT.601/709/2020, limited or
full range) predicts them best (mean absolute error per channel)."""
import struct, sys, zlib

def png_rgb(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w = 8, b'', 0
    while pos < len(data):
        n, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
            assert depth == 8 and ctype in (2, 6)
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

def mean(img, cx, cy):
    w, h, bpp, rows = img
    s = [0, 0, 0]
    for y in range(cy - 2, cy + 3):
        for x in range(cx - 2, cx + 3):
            for k in range(3): s[k] += rows[y][x * bpp + k]
    return [v / 25 for v in s]

BARS = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]
RAMP = [0, 16, 48, 96, 144, 192, 235, 255]

def bar_ycbcr(r, g, b):  # as sandprobe.cpp: BT.709 limited, truncated
    return (int(16 + (46.742 * r + 157.243 * g + 15.874 * b) / 256),
            int(128 + (-25.765 * r - 86.674 * g + 112.439 * b) / 256),
            int(128 + (112.439 * r - 102.129 * g - 10.310 * b) / 256))

MATRICES = {'601': (0.299, 0.114), '709': (0.2126, 0.0722), '2020': (0.2627, 0.0593)}

def to_rgb(ycc, kr, kb, full):
    y, cb, cr = ycc
    if full: yy, pb, pr = y / 255, (cb - 128) / 255, (cr - 128) / 255
    else: yy, pb, pr = (y - 16) / 219, (cb - 128) / 224, (cr - 128) / 224
    kg = 1 - kr - kb
    r = yy + 2 * (1 - kr) * pr
    b = yy + 2 * (1 - kb) * pb
    g = (yy - kr * r - kb * b) / kg
    return [min(255, max(0, round(v * 255))) for v in (r, g, b)]

for path in sys.argv[1:]:
    img = png_rgb(path)
    # the plane: 960x540 at (0,0); bars at y 135, ramp at y 405, x centres 60 + 120 i
    bars = [mean(img, 60 + 120 * i, 135) for i in range(8)]
    ramp = [mean(img, 60 + 120 * i, 405) for i in range(8)]
    inputs = [bar_ycbcr(*b) for b in BARS] + [(y, 128, 128) for y in RAMP]
    seen = bars + ramp
    fits = []
    for name, (kr, kb) in MATRICES.items():
        for full in (False, True):
            err = sum(abs(p - s) for ycc, got in zip(inputs, seen)
                      for p, s in zip(to_rgb(ycc, kr, kb, full), got)) / (len(inputs) * 3)
            fits.append((err, f'{name} {"full" if full else "limited"}'))
    fits.sort()
    print(f'{path}: best {fits[0][1]} (mean error {fits[0][0]:.1f}), next {fits[1][1]} ({fits[1][0]:.1f})')
    print('  bars ' + ' '.join('%d,%d,%d' % tuple(round(v) for v in c) for c in bars))
    print('  ramp ' + ' '.join('%d' % round(sum(c) / 3) for c in ramp))

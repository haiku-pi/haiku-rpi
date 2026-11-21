#!/usr/bin/env python3
"""shot-vs-hdmi.py SHOT HDMI [--rect X,Y,W,H]... [--crop X,Y] — compares a screenshot of the Pi (BScreen::GetBitmap:
the `screenshot` command, tools/haiku-tests/screenread; PNG or PPM) with an HDMI snapshot of the same moment
(scripts/hdmi-snap.sh), for the overlay read-back (docs/design/gpu-stage6.md §11). Images are decoded with ffmpeg.

SHOT may be a part of the screen: --crop X,Y is where its top left lies in HDMI.

Prints for the whole picture and each RECT (in HDMI coordinates; the edges' 3 pixels left out, where scalers
differ): the median, 95th percentile and largest per-pixel difference (the largest of the three channels), the
share of pixels that differ by more than 24, and the shift of SHOT against HDMI (-3...3 in x and y) that matches
best ("shift 0,0" = position exact). "holes": pixels black in SHOT (all channels < 8) but not in HDMI (a
channel > 48): what screenshots showed where an overlay was before the read-back.
"""
import subprocess, sys


def load(path):
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                            'stream=width,height', '-of', 'csv=p=0', path], capture_output=True, text=True,
                           check=True).stdout.split(',')
    w, h = int(probe[0]), int(probe[1])
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True, check=True).stdout
    assert len(raw) == w * h * 3, (path, len(raw), w, h)
    return w, h, raw


def pct(sorted_values, p):
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * p))] if sorted_values else 0


def region(shot, hdmi, crop, x0, y0, w, h, step=1, dx=0, dy=0):
    """per-pixel differences of SHOT (shifted by dx, dy) against HDMI in the HDMI rectangle"""
    sw, sh, s = shot
    hw, hh, d = hdmi
    cx, cy = crop
    out, holes = [], 0
    for y in range(y0, y0 + h, step):
        sy = y - cy + dy
        if not (0 <= sy < sh) or not (0 <= y < hh):
            continue
        for x in range(x0, x0 + w, step):
            sx = x - cx + dx
            if not (0 <= sx < sw) or not (0 <= x < hw):
                continue
            i, j = (sy * sw + sx) * 3, (y * hw + x) * 3
            a, b = s[i:i + 3], d[j:j + 3]
            out.append(max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])))
            if max(a) < 8 and max(b) > 48:
                holes += 1
    return out, holes


def report(name, shot, hdmi, crop, x0, y0, w, h):
    m = 3
    x0, y0, w, h = x0 + m, y0 + m, w - 2 * m, h - 2 * m
    diffs, holes = region(shot, hdmi, crop, x0, y0, w, h)
    if not diffs:
        print(f'{name}: no pixels')
        return
    diffs.sort()
    over = sum(1 for v in diffs if v > 24) / len(diffs)
    step = max(1, int((w * h / 40000) ** 0.5))
    best = None
    for dy in range(-3, 4):
        for dx in range(-3, 4):
            sample, _ = region(shot, hdmi, crop, x0, y0, w, h, step, dx, dy)
            if sample:
                mean = sum(sample) / len(sample)
                # ties: the smaller shift
                if best is None or (mean, abs(dx) + abs(dy)) < (best[0], abs(best[1]) + abs(best[2])):
                    best = (mean, dx, dy)
    print(f'{name} {x0},{y0} {w}x{h}: median {pct(diffs, .5)} p95 {pct(diffs, .95)} max {diffs[-1]}, '
          f'>24: {100 * over:.2f} %, holes {holes}, shift {best[1]},{best[2]} '
          f'(mean {best[0]:.2f})')


def main():
    args = sys.argv[1:]
    rects, crop = [], (0, 0)
    while '--rect' in args:
        i = args.index('--rect')
        rects.append(tuple(int(v) for v in args[i + 1].split(',')))
        del args[i:i + 2]
    if '--crop' in args:
        i = args.index('--crop')
        crop = tuple(int(v) for v in args[i + 1].split(','))
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    shot, hdmi = load(args[0]), load(args[1])
    print(f'{args[0]}: {shot[0]}x{shot[1]}; {args[1]}: {hdmi[0]}x{hdmi[1]}')
    report('all', shot, hdmi, crop, crop[0], crop[1], shot[0], shot[1])
    for r in rects:
        report('rect', shot, hdmi, crop, *r)


main()

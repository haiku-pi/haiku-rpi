#!/usr/bin/env python3
"""png2hvif.py — a Haiku vector icon (HVIF, the "BEOS:ICON" resource/attribute) from a raster icon, for
ports whose artwork is a bitmap or an SVG too detailed for Haiku's icon format (Photocraft's engraving).

    tools/haiku-icon/png2hvif.py IN.png OUT.hvif --color RRGGBB... [--size 64] [--blur R] [--preview OUT.png]

The image is blurred (--blur, a Gaussian radius in source pixels: fine line work such as hatching becomes
tone) and scaled to SIZE×SIZE (HVIF's canvas is 64 units) and every pixel is given the nearest of the
--color colors (the first is the background, left transparent outside the image's own alpha). Each color
from the second on becomes one shape covering the pixels of that color *and of every later color*, drawn in
order, so the later (inner) colors paint over a silhouette instead of leaving seams. A shape's paths are the
pixel-edge outlines of its regions (outer outlines counter-clockwise, holes clockwise: the non-zero fill
rule Haiku's icon renderer uses), simplified (Ramer-Douglas-Peucker, --epsilon pixels). Regions smaller
than --min-area pixels are dropped. Limits of the format: 255 styles, paths and shapes, 255 points a path.
--preview draws the same polygons with PIL, to check the result on this host.
"""
import argparse
import struct
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter


def nearest(rgb, palette):
    return min(range(len(palette)), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgb, palette[i])))


def loops(mask, w, h):
    """Pixel-edge boundary loops of the True cells, the region on the left of each directed edge."""
    inside = lambda x, y: 0 <= x < w and 0 <= y < h and mask[y][x]
    edges = {}  # start vertex -> list of end vertices
    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            # y grows downwards: with the region on the left, walk counter-clockwise on screen
            if not inside(x, y - 1):
                edges.setdefault((x + 1, y), []).append((x, y))
            if not inside(x - 1, y):
                edges.setdefault((x, y), []).append((x, y + 1))
            if not inside(x, y + 1):
                edges.setdefault((x, y + 1), []).append((x + 1, y + 1))
            if not inside(x + 1, y):
                edges.setdefault((x + 1, y + 1), []).append((x + 1, y))
    result = []
    while edges:
        start = next(iter(edges))
        loop = [start]
        prev = None
        cur = start
        while True:
            outs = edges.get(cur)
            if not outs:
                break
            if len(outs) > 1 and prev is not None:
                # a saddle: turn left (keeps diagonal neighbours apart, 4-connected regions)
                dx, dy = cur[0] - prev[0], cur[1] - prev[1]
                left = (cur[0] + dy, cur[1] - dx)
                nxt = left if left in outs else outs[0]
            else:
                nxt = outs[0]
            outs.remove(nxt)
            if not outs:
                del edges[cur]
            prev, cur = cur, nxt
            if cur == start:
                break
            loop.append(cur)
        result.append(loop)
    return result


def area(loop):
    return sum(loop[i][0] * loop[(i + 1) % len(loop)][1] - loop[(i + 1) % len(loop)][0] * loop[i][1]
        for i in range(len(loop))) / 2


def rdp(points, eps):
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = (dx * dx + dy * dy) ** 0.5
    best, index = -1, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        d = abs(dy * px - dx * py + x2 * y1 - y2 * x1) / norm if norm else ((px - x1) ** 2 + (py - y1) ** 2) ** 0.5
        if d > best:
            best, index = d, i
    if best <= eps:
        return [points[0], points[-1]]
    return rdp(points[:index + 1], eps)[:-1] + rdp(points[index:], eps)


def simplify(loop, eps):
    # split the closed loop at its two most distant points, simplify each half
    far = max(range(len(loop)), key=lambda i: (loop[i][0] - loop[0][0]) ** 2 + (loop[i][1] - loop[0][1]) ** 2)
    a = rdp(loop[:far + 1], eps)
    b = rdp(loop[far:] + [loop[0]], eps)
    return a[:-1] + b[:-1]


def coord(v):
    v = float(v)
    if v == int(v) and -32 <= v <= 95:
        return bytes([int(v) + 32])
    value = int((v + 128.0) * 102.0) | 0x8000
    return bytes([value >> 8, value & 255])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input')
    ap.add_argument('output')
    ap.add_argument('--color', action='append', required=True)
    ap.add_argument('--size', type=int, default=64)
    ap.add_argument('--epsilon', type=float, default=0.6)
    ap.add_argument('--min-area', type=float, default=2.0)
    ap.add_argument('--blur', type=float, default=0.0)
    ap.add_argument('--preview')
    args = ap.parse_args()
    palette = [tuple(int(c[i:i + 2], 16) for i in (0, 2, 4)) for c in args.color]
    size = args.size
    image = Image.open(args.input).convert('RGBA')
    if args.blur > 0:
        image = image.filter(ImageFilter.GaussianBlur(args.blur))
    image = image.resize((size, size), Image.LANCZOS)
    px = image.load()
    index = [[(nearest(px[x, y][:3], palette) if px[x, y][3] >= 128 else -1) for x in range(size)]
        for y in range(size)]
    scale = 64.0 / size
    styles, paths, shapes = [], [], []
    for c in range(len(palette)):
        mask = [[index[y][x] >= c for x in range(size)] for y in range(size)]
        shape_paths = []
        for loop in loops(mask, size, size):
            if abs(area(loop)) < args.min_area:
                continue
            eps = args.epsilon
            pts = simplify(loop, eps)
            while len(pts) > 255:
                eps *= 1.5
                pts = simplify(loop, eps)
            if len(pts) >= 3:
                shape_paths.append([(x * scale, y * scale) for x, y in pts])
        if not shape_paths:
            continue
        styles.append(palette[c])
        shapes.append((len(styles) - 1, list(range(len(paths), len(paths) + len(shape_paths)))))
        paths.extend(shape_paths)
    if len(styles) > 255 or len(paths) > 255 or len(shapes) > 255:
        sys.exit(f'png2hvif: too many paths ({len(paths)}): raise --epsilon or --min-area, or lower --size')
    out = bytearray(struct.pack('<I', 0x6669636e))  # FLAT_ICON_MAGIC 'ficn', little-endian: "ncif"
    out.append(len(styles))
    for r, g, b in styles:
        out += bytes([3, r, g, b])  # STYLE_TYPE_SOLID_COLOR_NO_ALPHA
    out.append(len(paths))
    for path in paths:
        out += bytes([(1 << 1) | (1 << 3), len(path)])  # closed, no curves
        for x, y in path:
            out += coord(x) + coord(y)
    out.append(len(shapes))
    for style, path_list in shapes:
        out += bytes([10, style, len(path_list)]) + bytes(path_list) + bytes([0])  # path source, no flags
    open(args.output, 'wb').write(out)
    print(f'png2hvif: {args.output}: {len(out)} bytes, {len(styles)} styles, {len(paths)} paths, '
        f'{sum(len(p) for p in paths)} points')
    if args.preview:
        big = 256
        k = big / 64.0
        im = Image.new('RGBA', (big, big), (0, 0, 0, 0))
        for style, path_list in shapes:
            # nested outlines of alternating orientation: non-zero = even-odd
            layer = Image.new('1', (big, big), 0)
            for i in path_list:
                one = Image.new('1', (big, big), 0)
                ImageDraw.Draw(one).polygon([(x * k, y * k) for x, y in paths[i]], fill=1)
                layer = ImageChops.logical_xor(layer, one)
            im.paste(Image.new('RGBA', (big, big), styles[style] + (255,)), (0, 0), layer.convert('L'))
        im.save(args.preview)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""bfs-corrupt.py IMG [--bitmap] [--root]: print a BFS image's layout; --bitmap zeroes its block bitmap, --root
its root directory's inode block. Both together give the corrupt volume of KNOWN-ISSUES C14 (an unreadable root
node plus a block bitmap the mount repairs in a transaction); docs/design/usb-storage-integrity.md, "Follow-ups"."""
import struct, sys
img = sys.argv[1]
with open(img, 'r+b') as f:
    f.seek(512)
    sb = f.read(512)
    bs, shift = struct.unpack_from('<II', sb, 40)
    nblocks, used = struct.unpack_from('<qq', sb, 48)
    bpag, agshift, nags, flags = struct.unpack_from('<iiii', sb, 72)
    def run(off):
        ag, start, ln = struct.unpack_from('<iHH', sb, off)
        return (ag << agshift) + start, ln
    log, root, idx = run(88), run(116), run(124)
    print(f'block {bs} blocks {nblocks} used {used} bpag {bpag} nags {nags} log {log} root {root} indices {idx}')
    zero = bytes(bs)
    if '--bitmap' in sys.argv:
        nbitmap = (nblocks + bs * 8 - 1) // (bs * 8)
        for b in range(1, 1 + nbitmap):
            f.seek(b * bs); f.write(zero)
        print(f'zeroed bitmap blocks 1..{nbitmap}')
    if '--root' in sys.argv:
        f.seek(root[0] * bs); f.write(zero)
        print(f'zeroed root inode block {root[0]}')

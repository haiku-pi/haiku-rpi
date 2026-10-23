#!/usr/bin/env python3
# fpwalk.py CORE IMAGES.txt fp lr [fp lr ...] — walk AArch64 frame records in an ELF core; print image+offset per frame
import struct, sys
core = open(sys.argv[1], 'rb').read()
phnum = struct.unpack_from('<H', core, 0x38)[0]; phoff = struct.unpack_from('<Q', core, 0x20)[0]
segs = []
for i in range(phnum):
    t, f, off, va, pa, fs, ms, al = struct.unpack_from('<IIQQQQQQ', core, phoff + i * 56)
    if t == 1: segs.append((va, va + fs, off))
def rd(a):
    for s, e, o in segs:
        if s <= a and a + 8 <= e and o + a - s + 8 <= len(core): return struct.unpack_from('<Q', core, o + a - s)[0]
    return None
imgs = []
for line in open(sys.argv[2]):
    p = line.split()
    if len(p) >= 7 and p[1].startswith('0x'): imgs.append((int(p[1], 16), int(p[2], 16), p[-1]))
def where(a):
    for s, e, n in imgs:
        if s <= a < e: return '%s+0x%x' % (n, a - s)
    return '?'
args = sys.argv[3:]
for k in range(0, len(args), 2):
    fp, lr = int(args[k], 16), int(args[k + 1], 16)
    print('--- fp %x' % fp); print('  lr %x %s' % (lr, where(lr)))
    for n in range(40):
        if not fp: break
        nfp, ra = rd(fp), rd(fp + 8)
        if ra is None: print('  (unreadable %x)' % fp); break
        print('  %x %s' % (ra, where(ra)))
        if nfp is None or nfp <= fp: break
        fp = nfp

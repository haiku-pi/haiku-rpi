#!/usr/bin/env python3
"""usb-pattern.py — a reproducible test pattern for a disk region, and a comparison of a read-back
against it (KNOWN-ISSUES C13, docs/design/usb-storage-integrity.md).

  usb-pattern.py gen FILE BASE_MIB SIZE_MIB   write the pattern for disk offset BASE_MIB: pseudo-random
                                              bytes (seed 1), each 512-byte sector starting with
                                              b"USBCHK" + its absolute LBA (8 bytes, little endian)
  usb-pattern.py cmp FILE READ BASE_MIB       compare READ (the region read back) with FILE: the number
                                              of bad sectors, and for runs of them what they hold
                                              (another sector of the pattern = misplaced data, zeros,
                                              or foreign bytes)
"""
import random
import struct
import sys

SECTOR = 512
TAG = b"USBCHK"


def gen(path, base_mib, size_mib):
    data = bytearray(random.Random(1).randbytes(size_mib << 20))
    lba0 = (base_mib << 20) // SECTOR
    for i in range(len(data) // SECTOR):
        data[i * SECTOR:i * SECTOR + 14] = TAG + struct.pack("<Q", lba0 + i)
    with open(path, "wb") as f:
        f.write(data)


def describe(sector):
    if sector[:6] == TAG:
        return "pattern LBA %d" % struct.unpack("<Q", sector[6:14])[0]
    if sector == bytes(SECTOR):
        return "zeros"
    return "foreign: " + sector[:16].hex()


def cmp(path, read_path, base_mib):
    want = open(path, "rb").read()
    got = open(read_path, "rb").read()
    lba0 = (base_mib << 20) // SECTOR
    n = min(len(want), len(got)) // SECTOR
    bad = [i for i in range(n) if want[i * SECTOR:(i + 1) * SECTOR] != got[i * SECTOR:(i + 1) * SECTOR]]
    print("sectors %d, bad %d, size want %d got %d" % (n, len(bad), len(want), len(got)))
    runs = []
    for i in bad:
        if runs and runs[-1][1] == i - 1:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    for a, b in runs[:40]:
        print("bad LBA %d..%d (%d sectors, offset %d KiB in the region): first holds %s, last %s" % (
            lba0 + a, lba0 + b, b - a + 1, a * SECTOR // 1024,
            describe(got[a * SECTOR:(a + 1) * SECTOR]), describe(got[b * SECTOR:(b + 1) * SECTOR])))
    if len(runs) > 40:
        print("... %d runs in all" % len(runs))


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "gen":
        gen(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif len(sys.argv) == 5 and sys.argv[1] == "cmp":
        cmp(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        sys.exit(__doc__)

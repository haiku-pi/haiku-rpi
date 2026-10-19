#!/usr/bin/env python3
"""make-locale-settings.py OUT [LANGUAGE...] — write ~/config/settings/Locale settings as Haiku's
FirstBootPrompt does: a flattened BMessage (Haiku format, "HMF1") with one "language" string per
preferred language (default: en). With that file on a writable boot volume the launch daemon starts
the desktop instead of the first-boot prompt (data/launch/user). The layout follows
headers/private/app/MessagePrivate.h and BMessage::Flatten(), BMessage::_HashName()."""

import struct
import sys

MESSAGE_FORMAT_HAIKU = 0x31464d48      # '1FMH'
MESSAGE_FLAG_VALID = 0x0001
FIELD_FLAG_VALID = 0x0001
HASH_TABLE_SIZE = 5                    # MESSAGE_BODY_HASH_TABLE_SIZE
B_STRING_TYPE = 0x43535452             # 'CSTR'
B_NULL_TOKEN = -1


def hash_name(name):
    result = 0
    for ch in name.encode():
        result = ((result << 7) ^ (result >> 24)) & 0xffffffff
        result ^= ch
    result ^= (result << 12) & 0xffffffff
    return result & 0xffffffff


def flatten(fields):
    """fields: [(name, [string, ...])] -> bytes"""
    hashTable = [-1] * HASH_TABLE_SIZE
    headers = b''
    data = b''
    for index, (name, values) in enumerate(fields):
        nameBytes = name.encode() + b'\0'
        items = b''.join(struct.pack('<I', len(v.encode()) + 1) + v.encode() + b'\0'
            for v in values)
        bucket = hash_name(name) % HASH_TABLE_SIZE
        nextField = hashTable[bucket]
        hashTable[bucket] = index
        headers += struct.pack('<HHIIIIi', FIELD_FLAG_VALID, len(nameBytes), B_STRING_TYPE,
            len(values), len(items), len(data), nextField)
        data += nameBytes + items
    header = struct.pack('<IIIiiiiiiIII5i', MESSAGE_FORMAT_HAIKU, 0, MESSAGE_FLAG_VALID,
        B_NULL_TOKEN, -1, -1, -1, B_NULL_TOKEN, -1, len(data), len(fields), HASH_TABLE_SIZE,
        *hashTable)
    return header + headers + data


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    languages = sys.argv[2:] or ['en']
    with open(sys.argv[1], 'wb') as f:
        f.write(flatten([('language', languages)]))

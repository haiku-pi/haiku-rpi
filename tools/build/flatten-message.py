#!/usr/bin/env python3
"""flatten-message.py OUT FIELD... — write a flattened BMessage (Haiku's format, "HMF1"), as settings
files are: e.g. ~/config/settings/Locale settings or networktime settings, for an image to ship
instead of the first run of a preferences application. Each FIELD is NAME:TYPE=VALUE with TYPE string,
bool or int32; a name given more than once gets several values. The layout follows
headers/private/app/MessagePrivate.h and BMessage::Flatten(), BMessage::_HashName().

    flatten-message.py "tools/build/data/Locale settings" "language:string=en"
"""

import struct
import sys

MESSAGE_FORMAT_HAIKU = 0x31464d48      # '1FMH'
MESSAGE_FLAG_VALID = 0x0001
FIELD_FLAG_VALID = 0x0001
FIELD_FLAG_FIXED_SIZE = 0x0002
HASH_TABLE_SIZE = 5                    # MESSAGE_BODY_HASH_TABLE_SIZE
B_NULL_TOKEN = -1

# type: (type code, fixed size or None, packer)
TYPES = {
    'string': (0x43535452, None, lambda v: v.encode() + b'\0'),                # 'CSTR'
    'bool': (0x424f4f4c, 1, lambda v: struct.pack('<B', v in ('true', '1'))),  # 'BOOL'
    'int32': (0x4c4f4e47, 4, lambda v: struct.pack('<i', int(v, 0))),           # 'LONG'
}


def hash_name(name):
    result = 0
    for ch in name.encode():
        result = ((result << 7) ^ (result >> 24)) & 0xffffffff
        result ^= ch
    result ^= (result << 12) & 0xffffffff
    return result & 0xffffffff


def flatten(fields):
    """fields: [(name, type, [value, ...])] -> bytes"""
    hashTable = [-1] * HASH_TABLE_SIZE
    headers = b''
    data = b''
    for index, (name, kind, values) in enumerate(fields):
        typeCode, fixedSize, pack = TYPES[kind]
        nameBytes = name.encode() + b'\0'
        if fixedSize is None:
            # variable size: each item is its size and its bytes
            items = b''.join(struct.pack('<I', len(pack(v))) + pack(v) for v in values)
            flags = FIELD_FLAG_VALID
        else:
            items = b''.join(pack(v) for v in values)
            flags = FIELD_FLAG_VALID | FIELD_FLAG_FIXED_SIZE
        bucket = hash_name(name) % HASH_TABLE_SIZE
        nextField = hashTable[bucket]
        hashTable[bucket] = index
        headers += struct.pack('<HHIIIIi', flags, len(nameBytes), typeCode, len(values),
            len(items), len(data), nextField)
        data += nameBytes + items
    header = struct.pack('<IIIiiiiiiIII5i', MESSAGE_FORMAT_HAIKU, 0, MESSAGE_FLAG_VALID,
        B_NULL_TOKEN, -1, -1, -1, B_NULL_TOKEN, -1, len(data), len(fields), HASH_TABLE_SIZE,
        *hashTable)
    return header + headers + data


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    fields = []
    for arg in sys.argv[2:]:
        nameType, value = arg.split('=', 1)
        name, kind = nameType.rsplit(':', 1)
        if kind not in TYPES:
            sys.exit(f'flatten-message: unknown type {kind}')
        for field in fields:
            if field[0] == name and field[1] == kind:
                field[2].append(value)
                break
        else:
            fields.append((name, kind, [value]))
    with open(sys.argv[1], 'wb') as f:
        f.write(flatten(fields))

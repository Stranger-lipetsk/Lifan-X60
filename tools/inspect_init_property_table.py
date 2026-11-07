#!/usr/bin/env python3
"""Read known property-permission table from a verified ARM init image.

Static evidence of table entries only; never executes init or infers real-device
property state, control-service behavior, MAC policy, or successful access.
"""
import hashlib
import struct
import sys
from pathlib import Path

EXPECTED_SHA = 'cfb65bc70fb72c0a813c9e7171025abb9a95bfcd9014aa47e6a66e07b17efbd8'
PREFIXES = ('service.', 'service.adb.root', 'service.adb.tcp.port', 'persist.sys.')


def load_segments(data):
    if len(data) < 52 or data[:6] != b'\x7fELF\x01\x01':
        raise ValueError('expected 32-bit little-endian ELF')
    phoff = struct.unpack_from('<I', data, 28)[0]
    entsize, count = struct.unpack_from('<HH', data, 42)
    if entsize < 32 or count > 100 or phoff + entsize * count > len(data):
        raise ValueError('invalid program headers')
    segments = []
    for i in range(count):
        typ, off, addr, _, size, _, flags, _ = struct.unpack_from('<8I', data, phoff+i*entsize)
        if typ == 1 and off + size <= len(data): segments.append((off, addr, size, flags))
    return segments


def table_entries(data):
    segments = load_segments(data)
    out = {s: [] for s in PREFIXES}
    for off, _, size, flags in segments:
        if not flags & 2: continue  # table is in the writable load segment
        for pos in range((off + 3) & ~3, off + size - 11, 4):
            ptr, uid, gid = struct.unpack_from('<III', data, pos)
            for start, addr, length, _ in segments:
                if addr <= ptr < addr + length:
                    string_offset = start + ptr - addr
                    end = data.find(b'\0', string_offset, min(string_offset + 100, start + length))
                    if end == -1: continue
                    name = data[string_offset:end].decode('ascii', 'replace')
                    if name in out and uid < 100000 and gid < 100000:
                        out[name].append((uid, gid))
                    break
    return out


def main():
    if len(sys.argv) != 2: raise SystemExit('usage: inspect_init_property_table.py VERIFIED_INIT')
    b = Path(sys.argv[1]).read_bytes()
    if hashlib.sha256(b).hexdigest() != EXPECTED_SHA: raise SystemExit('Unexpected init SHA-256')
    entries = table_entries(b)
    for name in PREFIXES:
        if len(entries[name]) != 1: raise SystemExit('ambiguous or missing table entry: ' + name)
    print('Property-permission-like table entries in verified boot init (prefix, numeric UID, GID):')
    for name in PREFIXES: print(name, *entries[name][0])
    print('Table presence alone does not prove enforcement, MAC permission, control-service permission or actual device state.')

if __name__ == '__main__': main()

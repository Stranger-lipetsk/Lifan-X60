#!/usr/bin/env python3
"""Generate only fixed synthetic Android 4.4 property areas for isolated CI.

Implements the AOSP 4.4 hybrid trie layout. Not a tool for reading or changing
properties on a device. Values are hard-coded and contain no user data.
"""
import struct
import sys

SIZE = 128 * 1024
HEADER = 128
VALUE_MAX = 92


def build(root_mode, auth_mode='0'):
    if root_mode not in ('0', '1') or auth_mode not in ('0', '1'): raise ValueError('synthetic modes must be 0 or 1')
    values = {
        'ro.secure': '1', 'ro.debuggable': '1', 'ro.adb.secure': auth_mode,
        'ro.kernel.qemu': '0', 'service.adb.tcp.port': '43127',
        'service.adb.root': root_mode,
    }
    buf = bytearray(SIZE)
    used = 20
    struct.pack_into('<IIII', buf, 0, used, 0, 0x504f5250, 0xfc6ed0ab)

    def allocate(size):
        nonlocal used
        off = used
        used += (size + 3) & ~3
        if HEADER + used > SIZE: raise ValueError('area full')
        return off

    def field(node, offset): return struct.unpack_from('<I', buf, HEADER + node + offset)[0]
    def write_field(node, offset, value): struct.pack_into('<I', buf, HEADER + node + offset, value)
    def make_node(token):
        b = token.encode('ascii')
        off = allocate(20 + len(b) + 1)
        struct.pack_into('<B', buf, HEADER + off, len(b))
        buf[HEADER + off + 20:HEADER + off + 20 + len(b)] = b
        return off

    for key, value in values.items():
        parent = 0
        for token in key.split('.'):
            off = field(parent, 16)
            if not off:
                off = make_node(token); write_field(parent, 16, off)
            while True:
                n = buf[HEADER + off]
                found = bytes(buf[HEADER + off + 20:HEADER + off + 20 + n]).decode('ascii')
                if token == found: break
                side = 8 if (len(token), token) < (len(found), found) else 12
                next_off = field(off, side)
                if not next_off:
                    next_off = make_node(token); write_field(off, side, next_off)
                off = next_off
            parent = off
        name, val = key.encode('ascii'), value.encode('ascii')
        info = allocate(4 + VALUE_MAX + len(name) + 1)
        struct.pack_into('<I', buf, HEADER + info, len(val) << 24)
        buf[HEADER + info + 4:HEADER + info + 4 + len(val)] = val
        buf[HEADER + info + 4 + VALUE_MAX:HEADER + info + 4 + VALUE_MAX + len(name)] = name
        write_field(parent, 4, info)
    struct.pack_into('<I', buf, 0, used)
    return bytes(buf)


if __name__ == '__main__':
    if len(sys.argv) != 4: raise SystemExit('usage: synthetic_property_area.py ROOT_MODE AUTH_MODE OUTPUT')
    with open(sys.argv[3], 'wb') as f: f.write(build(sys.argv[1], sys.argv[2]))

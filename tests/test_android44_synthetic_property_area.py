import struct
import unittest
from tools.android44_synthetic_property_area import build


def lookup(b, key):
    head = 128
    def field(n, off): return struct.unpack_from('<I', b, head+n+off)[0]
    cur = 0
    for token in key.split('.'):
        cur = field(cur, 16)
        while cur:
            n = b[head+cur]
            name = b[head+cur+20:head+cur+20+n].decode()
            if name == token: break
            cur = field(cur, 8 if (len(token), token) < (len(name), name) else 12)
        if not cur: return None
    info = field(cur, 4)
    if not info: return None
    serial = field(info, 0)
    return b[head+info+4:head+info+4+(serial >> 24)].decode()


class PropertyAreaTest(unittest.TestCase):
    def test_all_values_and_absent(self):
        for mode in '01':
            b = build(mode)
            self.assertEqual(len(b), 131072)
            self.assertEqual(struct.unpack_from('<II', b, 8), (0x504f5250, 0xfc6ed0ab))
            for key, val in {'ro.secure':'1', 'ro.debuggable':'1', 'ro.adb.secure':'0',
                             'ro.kernel.qemu':'0', 'service.adb.tcp.port':'43127', 'service.adb.root':mode}.items():
                self.assertEqual(lookup(b, key), val)
            for missing in ('service.adb.nope', 'ro', 'ro.foo', 'service.adb.tcp'):
                self.assertIsNone(lookup(b, missing))

    def test_reject_invalid_mode(self):
        with self.assertRaises(ValueError): build('x')

if __name__ == '__main__': unittest.main()

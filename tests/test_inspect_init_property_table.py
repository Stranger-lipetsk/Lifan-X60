import struct
import unittest
from tools.inspect_init_property_table import table_entries


class TableTest(unittest.TestCase):
    def test_synthetic_elf(self):
        b = bytearray(512)
        b[:6] = b'\x7fELF\x01\x01'
        struct.pack_into('<I', b, 28, 52)
        struct.pack_into('<HH', b, 42, 32, 1)
        struct.pack_into('<8I', b, 52, 1, 0, 0x8000, 0, 512, 512, 6, 4096)
        entries = [('service.', 1000, 0), ('service.adb.root', 2000, 0), ('service.adb.tcp.port', 2000, 0), ('persist.sys.', 1000, 0)]
        for i, (name, uid, gid) in enumerate(entries):
            offset = 200 + i * 35
            b[offset:offset+len(name)+1] = name.encode() + b'\0'
            struct.pack_into('<III', b, 360 + i*12, 0x8000+offset, uid, gid)
        result = table_entries(bytes(b))
        for name, uid, gid in entries: self.assertEqual(result[name], [(uid, gid)])

    def test_invalid(self):
        with self.assertRaises(ValueError): table_entries(b'not elf')

if __name__ == '__main__': unittest.main()

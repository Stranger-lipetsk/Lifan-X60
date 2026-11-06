import unittest
from tools.inspect_boot_cmdline import inspect


class BootHeaderTest(unittest.TestCase):
    def test_reads_legacy_header_cmdline_not_other_bytes(self):
        data = bytearray(700)
        data[:8] = b'ANDROID!'
        data[64:64+29] = b'hello androidboot.selinux=off'
        self.assertEqual(inspect(bytes(data)), 'hello androidboot.selinux=off')

    def test_rejects_bad_header(self):
        for data in (b'', b'NOIMAGE!' + bytes(700), b'ANDROID!' + bytes(10)):
            with self.assertRaises(ValueError):
                inspect(data)


if __name__ == '__main__':
    unittest.main()

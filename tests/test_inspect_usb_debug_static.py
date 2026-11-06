import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('usb_debug', ROOT / 'tools/inspect_usb_debug_static.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class USBHintsTest(unittest.TestCase):
    def test_filters_ascii_hints_without_executing(self):
        data = b'\x00ordinary text\x00/system/bin/adbd\x00tcp port 5555\x00\x01'
        self.assertEqual(module.relevant_strings(data), ['/system/bin/adbd', 'tcp port 5555'])

    def test_neighbor_strings_include_numeric_settings(self):
        self.assertEqual(module.nearby_strings(b'\x00abc\x00service.adb.tcp.port\x005555\x00xyz\x00', 'service.adb.tcp.port', 1), ['abc', 'service.adb.tcp.port', '5555'])

    def test_empty_input(self):
        self.assertEqual(module.relevant_strings(b'\x00\xff'), [])


if __name__ == '__main__':
    unittest.main()

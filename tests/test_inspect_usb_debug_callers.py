import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('usb_callers', ROOT / 'tools/inspect_usb_debug_callers.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ScanTest(unittest.TestCase):
    def test_ascii_and_utf16_search(self):
        self.assertEqual(module.matches(b'xusbnet_adb_support\x00'), ['usbnet_adb_support', 'usbnet_adb'])
        self.assertIn('el_debug_tool', module.matches('el_debug_tool'.encode('utf-16le')))
        self.assertEqual(module.matches(b'ordinary unrelated data'), [])

    def test_reads_compressed_entry_not_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with zipfile.ZipFile(root / 'test.apk', 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('classes.dex', b'prefix usbnet_adb_support suffix')
            (root / 'link').symlink_to(root / 'test.apk')
            found, gaps, counts = module.scan(root)
            self.assertIn(('test.apk', 'classes.dex', 'usbnet_adb_support'), found)
            self.assertFalse(gaps)
            self.assertEqual(counts, (1, 1, 1))

    def test_oversize_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'file').write_bytes(b'1234')
            limit = module.MAX_FILE
            try:
                module.MAX_FILE = 2
                found, gaps, counts = module.scan(root)
                self.assertEqual(gaps, [('file', 'file too large')])
            finally:
                module.MAX_FILE = limit


if __name__ == '__main__':
    unittest.main()

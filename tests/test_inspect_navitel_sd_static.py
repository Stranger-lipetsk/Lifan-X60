import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('navitel_sd', ROOT / 'tools/inspect_navitel_sd_static.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StaticHintsTest(unittest.TestCase):
    def test_only_selected_entries_and_ascii_hints(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fake.apk'
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as apk:
                apk.writestr('classes.dex', b'\x00NavitelContent/Maps\x00')
                apk.writestr('lib/armeabi-v7a/libtest.so', b'\x00test.nm7\x00')
                apk.writestr('lib/x86_64/libtest.so', b'\x00hidden.ns2\x00')
            hits, skipped, count = module.inspect(path)
            self.assertEqual(count, 2)
            self.assertFalse(skipped)
            self.assertEqual(hits[0][1], ['navitelcontent'])
            self.assertEqual(hits[1][1], ['.nm7'])

    def test_limit_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'fake.apk'
            with zipfile.ZipFile(path, 'w') as apk:
                apk.writestr('classes.dex', b'12345')
            limit = module.MAX_ENTRY
            try:
                module.MAX_ENTRY = 4
                self.assertEqual(module.inspect(path), ([], ['classes.dex'], 0))
            finally:
                module.MAX_ENTRY = limit


if __name__ == '__main__':
    unittest.main()

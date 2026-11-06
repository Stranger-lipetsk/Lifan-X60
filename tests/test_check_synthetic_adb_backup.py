import importlib.util
import io
import tarfile
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_synthetic_adb_backup', ROOT / 'tools/check_synthetic_adb_backup.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SyntheticBackupTest(unittest.TestCase):
    def make_archive(self, path, encrypted=False):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as tar:
            item = tarfile.TarInfo('apps/com.navitel/f/lab-marker.txt')
            item.size = len(module.MARKER)
            tar.addfile(item, io.BytesIO(module.MARKER))
        name = b'AES-256' if encrypted else b'none'
        path.write_bytes(b'ANDROID BACKUP\n1\n1\n' + name + b'\n' + zlib.compress(data.getvalue()))

    def test_marker_is_read_without_extracting(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lab.ab'
            self.make_archive(path)
            self.assertEqual(module.inspect(path), [('apps/com.navitel/f/lab-marker.txt', module.MARKER)])

    def test_refuses_encrypted_or_truncated_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lab.ab'
            self.make_archive(path, encrypted=True)
            with self.assertRaises(ValueError):
                module.inspect(path)
            self.make_archive(path)
            path.write_bytes(path.read_bytes()[:-8])
            with self.assertRaises(ValueError):
                module.inspect(path)


if __name__ == '__main__':
    unittest.main()

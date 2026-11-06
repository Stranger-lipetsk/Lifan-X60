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
            for name, content in module.EXPECTED.items():
                item = tarfile.TarInfo(name)
                item.size = len(content)
                tar.addfile(item, io.BytesIO(content))
        name = b'AES-256' if encrypted else b'none'
        path.write_bytes(b'ANDROID BACKUP\n1\n1\n' + name + b'\n' + zlib.compress(data.getvalue()))

    def test_marker_is_read_without_extracting(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lab.ab'
            self.make_archive(path)
            self.assertEqual(dict(module.inspect(path)), module.EXPECTED)

    def test_requires_both_distinct_intact_test_files(self):
        entries = list(module.EXPECTED.items())
        module.verify(entries)
        for bad in (entries[:1], [entries[0], entries[0]], [entries[0], (entries[1][0], b'changed')]):
            with self.assertRaises(ValueError):
                module.verify(bad)

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

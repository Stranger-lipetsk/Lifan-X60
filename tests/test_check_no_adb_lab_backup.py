import importlib.util
import io
import tarfile
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('backup_lab', ROOT / 'tools/check_no_adb_lab_backup.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def make_backup(path, content):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tar:
        for name, body in content:
            info = tarfile.TarInfo(name)
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
    path.write_bytes(b'ANDROID BACKUP\n1\n1\nnone\n' + zlib.compress(buf.getvalue()))


class BackupLabTest(unittest.TestCase):
    def setUp(self):
        self.entries = [
            (module.PREFIX + 'f/lab-marker.txt', b'X60_BACKUP_ONLY_FIXTURE\n'),
            (module.PREFIX + 'sp/lab_probe.xml', b'<map><string name="lab_probe">X60_ONLY_SYNTHETIC_PREF</string></map>'),
        ]

    def test_accepts_both_synthetic_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'sample.ab'
            make_backup(path, self.entries)
            self.assertEqual(len(module.inspect(path)), 2)

    def test_refuses_missing_duplicate_and_other_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'sample.ab'
            for entries in (self.entries[:1], self.entries + [self.entries[0]],
                            self.entries + [('apps/com.navitel/f/data', b'x')]):
                make_backup(path, entries)
                with self.assertRaises(ValueError):
                    module.inspect(path)

    def test_refuses_truncated_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'sample.ab'
            make_backup(path, self.entries)
            path.write_bytes(path.read_bytes()[:-8])
            with self.assertRaises(ValueError):
                module.inspect(path)


if __name__ == '__main__':
    unittest.main()

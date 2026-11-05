import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_file_manager_image import validate


class ImageComparisonTests(unittest.TestCase):
    def make_dirs(self, root):
        base, out = root / 'base', root / 'out'
        for x in (base, out):
            (x / 'app').mkdir(parents=True)
            (x / 'build.prop').write_text('same')
        data = b'fixture-only'
        (out / 'app/AmazeFileManager.apk').write_bytes(data)
        return base, out, hashlib.sha256(data).hexdigest()

    def test_only_one_file_is_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            base, out, digest = self.make_dirs(Path(d))
            validate(base, out, digest)

    def test_changed_existing_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base, out, digest = self.make_dirs(Path(d))
            (out / 'build.prop').write_text('unexpected')
            with self.assertRaises(ValueError):
                validate(base, out, digest)

    def test_wrong_apk_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base, out, _ = self.make_dirs(Path(d))
            with self.assertRaises(ValueError):
                validate(base, out, '0' * 64)

    def test_preexisting_apk_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base, out, digest = self.make_dirs(Path(d))
            (base / 'app/AmazeFileManager.apk').write_bytes(b'old')
            with self.assertRaises(ValueError):
                validate(base, out, digest)


if __name__ == '__main__':
    unittest.main()

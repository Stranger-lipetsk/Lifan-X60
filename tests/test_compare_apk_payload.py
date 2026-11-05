import contextlib
import io
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from compare_apk_payload import compare


def apk(path, dex, manifest=b'manifest', extra=()):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('classes.dex', dex)
        z.writestr('AndroidManifest.xml', manifest)
        z.writestr('META-INF/CERT.SF', b'signature')
        for key, value in extra:
            z.writestr(key, value)


class CompareApkTests(unittest.TestCase):
    def test_only_dex_may_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / 'a.apk', Path(tmp) / 'b.apk'
            apk(a, b'old'); apk(b, b'new')
            with contextlib.redirect_stdout(io.StringIO()):
                compare(a, b)
            apk(b, b'new', b'other')
            with self.assertRaisesRegex(ValueError, 'classes.dex'):
                compare(a, b)
            apk(b, b'old')
            with self.assertRaisesRegex(ValueError, 'classes.dex'):
                compare(a, b)
            apk(b, b'new', extra=[('new', b'x')])
            with self.assertRaisesRegex(ValueError, 'names differ'):
                compare(a, b)

    def test_duplicate_entry_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / 'a.apk', Path(tmp) / 'b.apk'
            apk(a, b'old'); apk(b, b'new', extra=[('classes.dex', b'two')])
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                compare(a, b)


if __name__ == '__main__':
    unittest.main()

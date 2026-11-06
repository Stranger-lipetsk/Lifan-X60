import tempfile
import unittest
import zipfile
from pathlib import Path
from tools.compare_resigned_apk import compare


def apk(path, changes=None):
    entries = {'AndroidManifest.xml': b'manifest', 'classes.dex': b'dex',
               'META-INF/MANIFEST.MF': b'old', 'META-INF/CERT.RSA': b'old cert',
               'META-INF/androidx.test.version': b'library metadata', 'res/a': b'payload'}
    entries.update(changes or {})
    with zipfile.ZipFile(path, 'w') as out:
        for name, data in entries.items():
            out.writestr(name, data)


class ComparisonTest(unittest.TestCase):
    def test_signatures_only(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory)/'a.apk', Path(directory)/'b.apk'
            apk(a); apk(b, {'META-INF/MANIFEST.MF': b'new', 'META-INF/CERT.RSA': b'new'})
            self.assertEqual(compare(a, b), 4)
            apk(b, {'META-INF/androidx.test.version': b'changed'})
            with self.assertRaises(ValueError): compare(a, b)
            apk(b, {'classes.dex': b'changed'})
            with self.assertRaises(ValueError): compare(a, b)

    def test_duplicate_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            a = Path(directory)/'a.apk'
            with zipfile.ZipFile(a, 'w') as out:
                out.writestr('a', b'1'); out.writestr('a', b'2')
            with self.assertRaises(ValueError): compare(a, a)


if __name__ == '__main__':
    unittest.main()

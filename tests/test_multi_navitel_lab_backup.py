import io
import tarfile
import unittest
import zlib
from tools.check_multi_navitel_lab_backup import inspect, NAV, FIXTURE
from tools.check_synthetic_adb_backup import MARKER, PREFS

class MultiArchiveTest(unittest.TestCase):
    def archive(self, extra=None, drop=None):
        files = {NAV+'f/lab-marker.txt': MARKER, NAV+'sp/x60_lab_probe.xml': PREFS,
                 FIXTURE+'f/lab-marker.txt': b'X60_BACKUP_ONLY_FIXTURE\n',
                 FIXTURE+'sp/lab_probe.xml': b'<map><string name="lab_probe">X60_ONLY_SYNTHETIC_PREF</string></map>'}
        if drop: files.pop(drop)
        if extra: files.update(extra)
        b = io.BytesIO()
        with tarfile.open(fileobj=b, mode='w') as tar:
            for name, data in files.items():
                info = tarfile.TarInfo(name); info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        return b'ANDROID BACKUP\n1\n1\nnone\n' + zlib.compress(b.getvalue())

    def test_checks_both_targets(self):
        self.assertEqual(len(inspect(self.archive())), 4)

    def test_rejects_unexpected_and_missing(self):
        with self.assertRaises(ValueError):
            inspect(self.archive(extra={'apps/ru.lifanx60.backupblocked/f/marker': b'x'}))
        with self.assertRaises(ValueError):
            inspect(self.archive(drop=NAV+'f/lab-marker.txt'))

if __name__ == '__main__': unittest.main()

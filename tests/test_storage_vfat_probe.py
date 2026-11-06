import unittest
from pathlib import Path

ROOT = Path('tests/fixtures/storage-vfat-probe')


class DisposableVirtualStorageProbeTest(unittest.TestCase):
    def test_guard_and_fixed_path(self):
        s = (ROOT/'src/ru/lifanx60/storagegrouplab/MainActivity.java').read_text()
        for expected in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("ranchu")',
                         'Build.HARDWARE.contains("goldfish")', 'REFUSED_NON_EMULATOR',
                         '/mnt/media_rw/sdcard/x60-synthetic-probe.txt'):
            self.assertIn(expected, s)
        self.assertNotIn('getStringExtra', s)
        self.assertNotIn('.delete(', s)

    def test_controls(self):
        with_permission = (ROOT/'positive.xml').read_text()
        without_permission = (ROOT/'negative.xml').read_text()
        self.assertIn('android.permission.WRITE_EXTERNAL_STORAGE', with_permission)
        self.assertNotIn('android.permission.WRITE_EXTERNAL_STORAGE', without_permission)
        self.assertNotIn('sharedUserId', with_permission + without_permission)


if __name__ == '__main__':
    unittest.main()

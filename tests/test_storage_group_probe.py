import unittest
from pathlib import Path

FIXTURE = Path('tests/fixtures/storage-group-probe')


class DisposableStorageGroupProbeTest(unittest.TestCase):
    def test_fixed_emulator_only_synthetic_path(self):
        text = (FIXTURE/'src/ru/lifanx60/storagegrouplab/MainActivity.java').read_text()
        for s in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("ranchu")',
                  'Build.HARDWARE.contains("goldfish")', 'REFUSED_NON_EMULATOR',
                  '/data/local/tmp/x60-synthetic-usb/usb1/x60-synthetic-probe.txt'):
            self.assertIn(s, text)
        self.assertNotIn('getStringExtra', text)
        self.assertNotIn('.delete(', text)

    def test_permission_control(self):
        positive = (FIXTURE/'positive.xml').read_text()
        negative = (FIXTURE/'negative.xml').read_text()
        self.assertIn('android.permission.WRITE_EXTERNAL_STORAGE', positive)
        self.assertNotIn('android.permission.WRITE_EXTERNAL_STORAGE', negative)
        self.assertNotIn('sharedUserId', positive + negative)


if __name__ == '__main__':
    unittest.main()

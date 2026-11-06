import unittest
from pathlib import Path

ROOT = Path('tests/fixtures/no-adb-navitel-caller')


class DisposableNavitelBackupFixtureTest(unittest.TestCase):
    def test_emulator_guards_and_fixed_target(self):
        for name in ('MainActivity', 'RestoreActivity'):
            text = (ROOT / 'src/ru/lifanx60/backupcallerfixture' / (name + '.java')).read_text()
            self.assertIn('Build.FINGERPRINT.startsWith("generic")', text)
            self.assertIn('Build.HARDWARE.contains("goldfish")', text)
            self.assertIn('Build.HARDWARE.contains("ranchu")', text)
            self.assertIn('REFUSED_NON_EMULATOR', text)
            self.assertIn('synthetic.ab', text)
        main = (ROOT / 'src/ru/lifanx60/backupcallerfixture/MainActivity.java').read_text()
        self.assertIn('new String[] {"com.navitel"}', main)
        self.assertNotIn('getStringExtra', main)

    def test_manifest_uses_no_shared_uid(self):
        manifest = (ROOT / 'AndroidManifest.xml').read_text()
        self.assertIn('android.permission.BACKUP', manifest)
        self.assertNotIn('sharedUserId', manifest)
        self.assertIn('android:allowBackup="false"', manifest)


if __name__ == '__main__':
    unittest.main()

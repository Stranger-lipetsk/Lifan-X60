import unittest
from pathlib import Path

ROOT = Path('tests/fixtures/no-adb-navitel-vfat-caller')

class DisposableVfatBackupFixtureTest(unittest.TestCase):
    def test_fixed_emulator_and_synthetic_target(self):
        for name in ('MainActivity', 'RestoreActivity'):
            text = (ROOT/'src/ru/lifanx60/backupcallerfixture'/(name + '.java')).read_text()
            for guard in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("ranchu")',
                          'Build.HARDWARE.contains("goldfish")', 'REFUSED_NON_EMULATOR',
                          '/data/local/tmp/x60-vfat-model/sdcard', 'synthetic.ab'):
                self.assertIn(guard, text)
            self.assertNotIn('getStringExtra', text)
        main = (ROOT/'src/ru/lifanx60/backupcallerfixture/MainActivity.java').read_text()
        self.assertIn('new String[] {"com.navitel"}', main)

    def test_permissions_are_not_shared_uid(self):
        manifest = (ROOT/'AndroidManifest.xml').read_text()
        self.assertIn('android.permission.BACKUP', manifest)
        self.assertIn('android.permission.WRITE_EXTERNAL_STORAGE', manifest)
        self.assertNotIn('sharedUserId', manifest)

if __name__ == '__main__':
    unittest.main()

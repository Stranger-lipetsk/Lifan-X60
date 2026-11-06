import unittest
from pathlib import Path

ROOT = Path('tests/fixtures/no-adb-navitel-multi-caller/src/ru/lifanx60/backupcallerfixture')
class MultiBackupFixtureTest(unittest.TestCase):
    def test_is_only_for_disposable_emulator_and_fixed_targets(self):
        for name in ('MainActivity', 'RestoreActivity'):
            s = (ROOT/(name + '.java')).read_text()
            for item in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("ranchu")',
                         'Build.HARDWARE.contains("goldfish")', '/data/local/tmp/x60-vfat-model/sdcard', 'synthetic.ab'):
                self.assertIn(item, s)
            self.assertNotIn('getStringExtra', s)
        self.assertIn('new String[] {"com.navitel", "ru.lifanx60.backupfixture", "ru.lifanx60.backupblocked"}', (ROOT/'MainActivity.java').read_text())
        self.assertIn('android:allowBackup="false"', Path('tests/fixtures/backup-disallowed-target/AndroidManifest.xml').read_text())

if __name__ == '__main__': unittest.main()

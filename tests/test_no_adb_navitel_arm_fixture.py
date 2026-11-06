import unittest
from pathlib import Path

ROOT = Path('tests/fixtures/no-adb-navitel-arm-caller/src/ru/lifanx60/backupcallerfixture')
class ArmBackupFixtureTest(unittest.TestCase):
    def test_only_emulator_and_fixed_targets(self):
        for name in ('MainActivity', 'RestoreActivity'):
            s = (ROOT/(name + '.java')).read_text()
            for item in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("ranchu")',
                         'Build.HARDWARE.contains("goldfish")', 'getExternalFilesDir(null)', 'synthetic.ab'):
                self.assertIn(item, s)
            self.assertNotIn('getStringExtra', s)
        self.assertIn('new String[] {"com.navitel", "ru.lifanx60.backupfixture", "ru.lifanx60.backupblocked"}', (ROOT/'MainActivity.java').read_text())

if __name__ == '__main__': unittest.main()

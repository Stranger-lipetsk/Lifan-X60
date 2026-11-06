import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures'
A = '{http://schemas.android.com/apk/res/android}'


class FixtureGuardTest(unittest.TestCase):
    def test_lab_caller_is_not_shared_uid_and_has_narrow_permissions(self):
        manifest = ET.parse(FIXTURES / 'no-adb-backup-caller/AndroidManifest.xml').getroot()
        self.assertNotIn(A + 'sharedUserId', manifest.attrib)
        perms = {n.get(A + 'name') for n in manifest.findall('uses-permission')}
        self.assertEqual(perms, {'android.permission.BACKUP', 'android.permission.WRITE_EXTERNAL_STORAGE'})
        java = (FIXTURES / 'no-adb-backup-caller/src/ru/lifanx60/backupcallerfixture/MainActivity.java').read_text()
        self.assertIn('ru.lifanx60.backupfixture', java)
        self.assertNotIn('com.navitel', java)
        self.assertNotIn('fullRestore', java)
        self.assertIn('Build.FINGERPRINT.startsWith("generic")', java)

    def test_target_has_no_permissions(self):
        manifest = ET.parse(FIXTURES / 'no-adb-backup-target/AndroidManifest.xml').getroot()
        self.assertFalse(manifest.findall('uses-permission'))
        self.assertEqual(manifest.get('package'), 'ru.lifanx60.backupfixture')


if __name__ == '__main__':
    unittest.main()

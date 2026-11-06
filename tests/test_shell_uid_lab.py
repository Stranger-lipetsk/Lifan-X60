import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path('tests/fixtures/shell-uid-lab')
ANDROID = '{http://schemas.android.com/apk/res/android}'


class ShellUidFixtureTest(unittest.TestCase):
    def test_fixture_only_reports_own_uid(self):
        manifest = ET.parse(ROOT / 'AndroidManifest.xml').getroot()
        self.assertEqual(manifest.attrib['package'], 'ru.lifanx60.shelluidfixture')
        self.assertEqual(manifest.attrib[ANDROID + 'sharedUserId'], 'android.uid.shell')
        self.assertFalse(manifest.findall('uses-permission'))
        java = (ROOT / 'src/ru/lifanx60/shelluidfixture/MainActivity.java').read_text()
        self.assertIn('Build.FINGERPRINT.startsWith("generic")', java)
        self.assertIn('Process.myUid()', java)
        for forbidden in ('Runtime.getRuntime', 'ProcessBuilder', 'ParcelFileDescriptor', 'java.io', 'com.navitel'):
            self.assertNotIn(forbidden, java)


if __name__ == '__main__':
    unittest.main()

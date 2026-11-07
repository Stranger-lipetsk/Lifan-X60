import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path('tests/fixtures/storage-readonly-lab')
ANDROID = '{http://schemas.android.com/apk/res/android}'


class FixtureSafetyTest(unittest.TestCase):
    def test_manifest_has_no_requested_permissions_or_other_components(self):
        root = ET.parse(ROOT / 'AndroidManifest.xml').getroot()
        self.assertEqual(root.attrib['package'], 'ru.lifanx60.storagelab')
        self.assertFalse(root.findall('uses-permission'))
        app = root.find('application')
        self.assertEqual(app.attrib[ANDROID + 'allowBackup'], 'false')
        self.assertEqual([e.tag for e in app], ['activity'])
        self.assertNotIn(ANDROID + 'sharedUserId', root.attrib)

    def test_emulator_gate_precedes_probe(self):
        text = (ROOT / 'src/ru/lifanx60/storagelab/MainActivity.java').read_text()
        self.assertLess(text.index('!Build.FINGERPRINT.startsWith("generic")'), text.index('new StatFs("/data")'))
        self.assertLess(text.index('Build.HARDWARE.contains("goldfish")'), text.index('new FileReader("/proc/mounts")'))
        for forbidden in ('Runtime.getRuntime', 'ProcessBuilder', 'FileOutputStream', 'FileWriter', 'getPackageManager()', 'getInstalledPackages', 'java.net.', 'android.permission.'):
            self.assertNotIn(forbidden, text)


if __name__ == '__main__':
    unittest.main()

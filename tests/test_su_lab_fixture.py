import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

R = Path('tests/fixtures/su-lab')
A = '{http://schemas.android.com/apk/res/android}'


class SuLabTest(unittest.TestCase):
    def test_fixed_guard_and_identity_only(self):
        source = (R / 'src/ru/lifanx60/sulab/MainActivity.java').read_text()
        self.assertIn('generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys', source)
        self.assertIn('Build.HARDWARE.contains("goldfish")', source)
        self.assertIn('new ProcessBuilder("/system/xbin/x60-lab-su", "0", "/system/bin/id")', source)
        self.assertEqual(source.count('new ProcessBuilder('), 1)
        self.assertNotIn('com.navitel', source)
        for name in ('shell', 'ordinary'):
            root = ET.parse(R / 'manifests' / (name + '.xml')).getroot()
            self.assertFalse(root.findall('uses-permission'))
            self.assertEqual(root.attrib.get(A + 'sharedUserId'), 'android.uid.shell' if name == 'shell' else None)


if __name__ == '__main__':
    unittest.main()

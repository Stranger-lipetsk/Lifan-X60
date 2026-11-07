import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'tests/fixtures/system-prop-lab'

class GuardsTest(unittest.TestCase):
    def test_manifest_scoped_fixture(self):
        root = ET.parse(BASE / 'AndroidManifest.xml').getroot()
        android = '{http://schemas.android.com/apk/res/android}'
        self.assertEqual(root.get(android + 'sharedUserId'), 'android.uid.system')
        self.assertEqual(root.findall('uses-permission'), [])
        self.assertEqual(root.find('application').get(android + 'allowBackup'), 'false')

    def test_only_emulator_and_fixed_property(self):
        s = (BASE / 'src/ru/lifanx60/systempropfixture/MainActivity.java').read_text()
        for part in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("goldfish")',
                     'Build.HARDWARE.contains("ranchu")', 'ro.kernel.qemu', 'REFUSED_NON_EMULATOR',
                     'service.adb.tcp.port', 'Process.myUid() == 1000', 'ctl.restart'):
            self.assertIn(part, s)
        self.assertNotIn('persist.adb.tcp.port', s)
        self.assertNotIn('service.adb.root', s)

    def test_runner_guards(self):
        s = (ROOT / 'tools/experiment_system_property_adb_lab.sh').read_text()
        for part in ('GITHUB_ACTIONS:-', 'iptables -I OUTPUT', 'ip6tables -I OUTPUT',
                     'restarted=no', 'Guest TCP listener', 'no head unit'):
            self.assertIn(part, s)

if __name__ == '__main__': unittest.main()

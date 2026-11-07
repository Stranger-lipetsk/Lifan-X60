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
        permissions = root.findall('uses-permission')
        self.assertEqual(len(permissions), 1)
        self.assertEqual(permissions[0].get(android + 'name'), 'android.permission.CONNECTIVITY_INTERNAL')
        self.assertEqual(root.find('application').get(android + 'allowBackup'), 'false')

    def test_only_emulator_and_fixed_property(self):
        s = (BASE / 'src/ru/lifanx60/systempropfixture/MainActivity.java').read_text()
        for part in ('Build.FINGERPRINT.startsWith("generic")', 'Build.HARDWARE.contains("goldfish")',
                     'Build.HARDWARE.contains("ranchu")', 'ro.kernel.qemu', 'REFUSED_NON_EMULATOR',
                     'service.adb.tcp.port', 'service.adb.root', 'Process.myUid() == 1000', 'ctl.restart'):
            self.assertIn(part, s)
        self.assertNotIn('persist.adb.tcp.port', s)

    def test_firewall_probe_is_disposable_and_restores(self):
        s = (BASE / 'src/ru/lifanx60/systempropfixture/MainActivity.java').read_text()
        for part in ('firewall_probe', 'Process.myUid() != 1000', 'setFirewallEnabled',
                     'setFirewallInterfaceRule', 'FIREWALL_DROP_LOOPBACK_WHILE_',
                     'FIREWALL_CLEANUP_DISABLED', '127.0.0.1'):
            self.assertIn(part, s)
        self.assertIn('setEnabled.invoke(service, false)', s)

    def test_runner_guards(self):
        s = (ROOT / 'tools/experiment_system_property_adb_lab.sh').read_text()
        for part in ('GITHUB_ACTIONS:-', 'iptables -I OUTPUT', 'ip6tables -I OUTPUT',
                     'restarted=no', 'Guest TCP listener', 'no head unit',
                     '--ez firewall_probe true', 'FIREWALL_RESTORED_DISABLED=true'):
            self.assertIn(part, s)

if __name__ == '__main__': unittest.main()

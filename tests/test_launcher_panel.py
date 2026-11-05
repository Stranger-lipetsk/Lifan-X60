import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'


class PanelManifestTests(unittest.TestCase):
    def setUp(self):
        self.root = ET.parse(ROOT / 'launcher-panel/AndroidManifest.xml').getroot()

    def test_unique_package_and_supported_min_sdk(self):
        self.assertEqual(self.root.get('package'), 'ru.lifanx60.panelprobe')
        self.assertEqual(self.root.find('uses-sdk').get(ANDROID + 'minSdkVersion'), '19')

    def test_no_boot_receiver_permissions_services_or_home_filter(self):
        self.assertFalse(self.root.findall('uses-permission'))
        app = self.root.find('application')
        self.assertFalse(app.findall('receiver'))
        self.assertFalse(app.findall('service'))
        self.assertFalse(app.findall('activity-alias'))
        names = [node.get(ANDROID + 'name') for node in app.iter()
                 if node.tag in ('action', 'category')]
        self.assertEqual(sorted(names), sorted(['android.intent.action.MAIN', 'android.intent.category.LAUNCHER']))
        self.assertNotIn('android.intent.category.HOME', names)
        self.assertNotIn('android.intent.action.BOOT_COMPLETED', names)

    def test_three_explicit_known_targets(self):
        source = (ROOT / 'launcher-panel/src/ru/lifanx60/panelprobe/MainActivity.java').read_text()
        for name in ('tw.com.elead.el830.home.Home', 'com.android.launcher2.Launcher',
                     'com.amaze.filemanager.ui.activities.MainActivity'):
            self.assertIn(name, source)
        self.assertIn('setComponent(new ComponentName(packageName, activityName))', source)
        self.assertNotIn('setComponentEnabledSetting', source)
        self.assertNotIn('sendBroadcast', source)


if __name__ == '__main__':
    unittest.main()

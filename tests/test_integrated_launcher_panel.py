import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'


class IntegratedPanelTests(unittest.TestCase):
    def setUp(self):
        self.root = ET.parse(ROOT / 'launcher-panel-integrated/AndroidManifest.xml').getroot()

    def test_matches_experimental_home_package(self):
        self.assertEqual(self.root.get('package'), 'ru.lifanx60.panel')
        patch = (ROOT / 'tools/experiment_home_carousel.py').read_text()
        self.assertIn("'ru.lifanx60.panel'", patch)
        self.assertEqual(self.root.find('uses-sdk').get(ANDROID + 'minSdkVersion'), '19')

    def test_no_home_or_autostart(self):
        self.assertFalse(self.root.findall('uses-permission'))
        app = self.root.find('application')
        self.assertFalse(app.findall('receiver'))
        self.assertFalse(app.findall('service'))
        names = [n.get(ANDROID + 'name') for n in app.iter() if n.tag in ('action', 'category')]
        self.assertEqual(sorted(names), sorted(['android.intent.action.MAIN', 'android.intent.category.LAUNCHER']))

    def test_target_components_and_controlled_behavior(self):
        source = (ROOT / 'launcher-panel-integrated/src/ru/lifanx60/panel/MainActivity.java').read_text()
        self.assertIn('package ru.lifanx60.panel;', source)
        for name in ('tw.com.elead.el830.home.Home', 'com.android.launcher2.Launcher',
                     'com.amaze.filemanager.ui.activities.MainActivity'):
            self.assertIn(name, source)
        self.assertIn('setComponent(new ComponentName(packageName, activityName))', source)
        self.assertNotIn('setComponentEnabledSetting', source)
        self.assertNotIn('sendBroadcast', source)
        self.assertNotIn('com.navitel', source)


if __name__ == '__main__':
    unittest.main()

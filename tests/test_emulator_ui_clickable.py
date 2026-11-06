import unittest
from tools.emulator_ui_clickable import coordinates


class UiClickTest(unittest.TestCase):
    def test_finds_enabled_nearest_parent(self):
        xml = b'<hierarchy><node clickable="true" enabled="true" bounds="[10,20][90,40]"><node text="navitel-lab.apk" clickable="false" enabled="true" bounds="[20,20][80,40]"/></node></hierarchy>'
        self.assertEqual(coordinates(xml, 'navitel-lab.apk'), (50, 30))

    def test_rejects_ambiguous_or_disabled(self):
        node = '<node clickable="true" enabled="true" bounds="[1,2][5,8]"><node text="f.apk"/></node>'
        with self.assertRaises(ValueError): coordinates(('<hierarchy>' + node + node.replace('[1,2][5,8]', '[10,20][50,80]') + '</hierarchy>').encode(), 'f.apk')
        with self.assertRaises(ValueError): coordinates(b'<hierarchy><node text="f.apk" clickable="true" enabled="false" bounds="[1,2][3,4]"/></hierarchy>', 'f.apk')


if __name__ == '__main__':
    unittest.main()

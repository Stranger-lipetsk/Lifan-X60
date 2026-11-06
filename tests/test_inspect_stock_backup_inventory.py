import unittest
from tools.inspect_stock_backup_inventory import parse_manifest


def manifest(application=''):
    return '''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=2)
    A: package="example.app" (Raw: "example.app")
    A: android:sharedUserId(0x0101000b)="android.uid.system" (Raw: "android.uid.system")
    E: application (line=4)
%s
      E: activity (line=5)
        A: android:allowBackup(0x01010280)=(type 0x12)0x0
''' % application


class InventoryTest(unittest.TestCase):
    def test_default_does_not_read_child_attribute(self):
        self.assertEqual(parse_manifest(manifest()), ('example.app', 'default-true', 'android.uid.system', '-'))

    def test_explicit_false_true_and_agent(self):
        self.assertEqual(parse_manifest(manifest('      A: android:allowBackup(0x01010280)=(type 0x12)0x0\n      A: android:backupAgent(0x0101027f)=".Agent"'))[1:], ('false', 'android.uid.system', '.Agent'))
        self.assertEqual(parse_manifest(manifest('      A: android:allowBackup(0x01010280)=(type 0x12)0xffffffff'))[1], 'true')

    def test_unknown_is_not_default(self):
        self.assertEqual(parse_manifest(manifest('      A: android:allowBackup(0x01010280)=@0x7f010000'))[1], 'unknown')

    def test_fails_on_incomplete_or_duplicate(self):
        with self.assertRaises(ValueError):
            parse_manifest('  E: manifest\n    A: package="x"')
        with self.assertRaises(ValueError):
            parse_manifest(manifest('      A: android:allowBackup(0x01010280)=(type 0x12)0x0\n      A: android:allowBackup(0x01010280)=(type 0x12)0x0'))


if __name__ == '__main__':
    unittest.main()

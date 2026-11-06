import tempfile
import unittest
from pathlib import Path
from tools.inspect_stock_storage_permissions import definition, mappings


class StoragePermissionInspectionTest(unittest.TestCase):
    def test_finds_exact_permission_element(self):
        tree = '''  E: permission (line=1)
    A: android:name="android.permission.TEST" (Raw: "android.permission.TEST")
    A: android:protectionLevel=(type 0x11)0x12
  E: permission (line=2)
    A: android:name="android.permission.TEST_OTHER"
'''
        self.assertIn('0x12', definition(tree, 'android.permission.TEST'))
        self.assertNotIn('TEST_OTHER', definition(tree, 'android.permission.TEST'))
        with self.assertRaises(ValueError):
            definition(tree, 'android.permission.UNKNOWN')

    def test_scans_all_permission_xml_files_and_reports_missing(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'platform.xml').write_text('<permissions><permission name="android.permission.TEST"><group gid="media_rw"/></permission></permissions>')
            (root/'other.xml').write_text('<permissions><permission name="android.permission.TEST"><group gid="sdcard_rw"/></permission></permissions>')
            result = mappings(root, ('android.permission.TEST', 'android.permission.MISSING'))
            self.assertEqual(result['android.permission.TEST'], [('other.xml', ['sdcard_rw']), ('platform.xml', ['media_rw'])])
            self.assertEqual(result['android.permission.MISSING'], [])


if __name__ == '__main__':
    unittest.main()

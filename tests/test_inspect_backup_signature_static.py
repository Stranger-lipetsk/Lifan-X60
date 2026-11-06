import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('backup_sig', ROOT / 'tools/inspect_backup_signature_static.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StaticBackupSignatureTest(unittest.TestCase):
    def test_permission_block_excludes_next_permission(self):
        xml = ('  E: manifest (line=1)\n'
               '    E: permission (line=2)\n'
               '      A: android:name="android.permission.BACKUP"\n'
               '      A: android:protectionLevel=0x2\n'
               '    E: permission (line=3)\n'
               '      A: android:name="other"\n')
        block = module.find_backup_permission(xml)
        self.assertIn('0x2', block)
        self.assertNotIn('other', block)
        with self.assertRaises(ValueError):
            module.find_backup_permission('  E: manifest (line=1)')

    def test_method_selects_definition(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'pkg.smali'
            path.write_text('.method private grantSignaturePermission()Z\n    return v0\n.end method\n')
            self.assertIn('return v0', module.method(path, 'grantSignaturePermission'))
            with self.assertRaises(ValueError):
                module.method(path, 'missing')


if __name__ == '__main__':
    unittest.main()

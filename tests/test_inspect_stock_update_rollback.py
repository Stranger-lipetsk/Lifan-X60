import tempfile
import unittest
from pathlib import Path
from tools.inspect_stock_update_rollback import report


class StockRollbackTest(unittest.TestCase):
    def test_extracts_methods_and_checks_references(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'PackageManagerService.smali'
            p.write_text('''.method private deleteSystemPackageLI()V
iget v0, v1, Lx;->versionCode:I
invoke-virtual {}, Lx;->deleteInstalledPackageLI()V
invoke-virtual {}, Lx;->enableSystemPackageLPw()V
.end method
.method private deleteInstalledPackageLI()V
return-void
.end method
''')
            a, b = report(p)
            self.assertIn('versionCode', a)
            self.assertIn('return-void', b)
            p.write_text(p.read_text().replace('versionCode:I', 'other:I'))
            with self.assertRaises(ValueError): report(p)


if __name__ == '__main__':
    unittest.main()

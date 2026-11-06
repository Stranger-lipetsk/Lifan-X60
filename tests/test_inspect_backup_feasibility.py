import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('inspect_backup_feasibility', ROOT / 'tools/inspect_backup_feasibility.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BackupInspectionTest(unittest.TestCase):
    def test_selected_backup_method_is_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'smali/com/android/server'
            path.mkdir(parents=True)
            (path / 'BackupManagerService.smali').write_text(
                '.method public adbBackup()V\n  const v0, 0x8000\n  return-void\n.end method\n'
                '.method public unrelated()V\n  return-void\n.end method\n')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                module.scan_framework(tmp)
            self.assertIn('adbBackup', out.getvalue())
            self.assertIn('0x8000', out.getvalue())
            self.assertNotIn('unrelated', out.getvalue())

    def test_refuses_missing_framework(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                module.scan_framework(tmp)


if __name__ == '__main__':
    unittest.main()

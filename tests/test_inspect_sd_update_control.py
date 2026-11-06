import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('inspect_sd_update_control', ROOT / 'tools/inspect_sd_update_control.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdateControlTest(unittest.TestCase):
    def test_extracts_matching_complete_method_not_other(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Test.smali').write_text(
                '.class LTest;\n.method public onClick()V\n'
                '    const-string v0, "FW_UPGRADE"\n    return-void\n.end method\n'
                '.method public other()V\n    return-void\n.end method\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                module.inspect_smali(root)
            self.assertIn('onClick()V', output.getvalue())
            self.assertIn('FW_UPGRADE', output.getvalue())
            self.assertNotIn('other()V', output.getvalue())
            self.assertIn('Selected methods: 1', output.getvalue())

    def test_refuses_missing_smali(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(RuntimeError):
                module.inspect_smali(Path(temp))


if __name__ == '__main__':
    unittest.main()

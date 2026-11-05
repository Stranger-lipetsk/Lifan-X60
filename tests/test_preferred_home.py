import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from inspect_preferred_home import inspect


class PreferredHomeTests(unittest.TestCase):
    def test_extracts_selected_and_missing_methods(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pm = root / 'smali/com/android/server/pm'
            pm.mkdir(parents=True)
            (pm / 'Settings.smali').write_text('.method public readDefaultPreferredAppsLPw()V\n return-void\n.end method\n')
            (pm / 'PackageManagerService.smali').write_text('.method public boot()V\n invoke-virtual {v0}, LX;->readDefaultPreferredAppsLPw()V\n.end method\n')
            out = io.StringIO()
            inspect(root, out)
            self.assertIn('pm/Settings.smali: .method public readDefaultPreferredAppsLPw', out.getvalue())
            self.assertIn('PreferredComponent.smali: not found', out.getvalue())
            self.assertIn('Methods or contexts selected: 2', out.getvalue())

    def test_rejects_unexpected_layout_and_empty_results(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                inspect(root, io.StringIO())
            (root / 'smali/com/android/server/pm').mkdir(parents=True)
            with self.assertRaises(ValueError):
                inspect(root, io.StringIO())


if __name__ == '__main__':
    unittest.main()

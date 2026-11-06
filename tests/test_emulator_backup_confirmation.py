import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('emulator_backup_confirmation', ROOT / 'tools/emulator_backup_confirmation.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConfirmTest(unittest.TestCase):
    def test_only_exact_enabled_clickable_button(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'ui.xml'
            path.write_text('<hierarchy><node text="Back up my data" enabled="true" clickable="true" bounds="[10,20][30,40]"/></hierarchy>')
            self.assertEqual(module.coordinates(path, 'Back up my data'), (20, 30))
            with self.assertRaises(ValueError):
                module.coordinates(path, 'Restore my data')
            path.write_text('<hierarchy><node text="Back up my data" enabled="false" clickable="true" bounds="[10,20][30,40]"/></hierarchy>')
            with self.assertRaises(ValueError):
                module.coordinates(path, 'Back up my data')


if __name__ == '__main__':
    unittest.main()

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('su_static', ROOT / 'tools/inspect_su_static.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SUStaticTest(unittest.TestCase):
    def test_string_selection(self):
        self.assertEqual(module.selected_strings(b'\0normal\0permission denied\0UID check\0'),
                         ['permission denied', 'UID check'])


if __name__ == '__main__':
    unittest.main()

import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from inspect_navitel_native import symbols


class TestNativeSymbols(unittest.TestCase):
    @patch('inspect_navitel_native.subprocess.run')
    def test_readelf_records_binding_and_normalizes_versions(self, run):
        run.return_value = SimpleNamespace(stdout='''
Symbol table '.dynsym' contains 4 entries:
   Num:    Value  Size Type    Bind   Vis      Ndx Name
     0: 00000000     0 NOTYPE  LOCAL  DEFAULT  UND
     1: 00000000     0 FUNC    GLOBAL DEFAULT  UND strlen@LIBC (2)
     2: 00001234     9 FUNC    GLOBAL DEFAULT    7 foo@@LIBC (2)
     3: 00000000     0 NOTYPE  WEAK   DEFAULT  UND optional
''')
        self.assertEqual(symbols(Path('fixture.so')), [
            ('strlen', 'GLOBAL', 'UND'), ('foo', 'GLOBAL', '7'),
            ('optional', 'WEAK', 'UND')])
        run.assert_called_once()

    @patch('inspect_navitel_native.subprocess.run')
    def test_ignores_non_global_symbols(self, run):
        run.return_value = SimpleNamespace(stdout='''
  2: 00000123 4 FUNC LOCAL DEFAULT 7 private_function
''')
        self.assertEqual(symbols(Path('fixture.so')), [])


if __name__ == '__main__':
    unittest.main()

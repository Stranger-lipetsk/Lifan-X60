import contextlib
import importlib.util
import io
import struct
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
            package = root / 'smali/tw/com/elead/example'
            package.mkdir(parents=True)
            (package / 'Test.smali').write_text(
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

    def test_elf32_load_segment_maps_string_to_virtual_address(self):
        data = bytearray(256)
        data[:6] = b'\x7fELF\x01\x01'
        struct.pack_into('<I', data, 28, 52)
        struct.pack_into('<HH', data, 42, 32, 1)
        struct.pack_into('<8I', data, 52, 1, 0, 0x8000, 0, 256, 256, 5, 4096)
        data[120:126] = b'hello\0'
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'binary'
            path.write_bytes(data)
            self.assertEqual(module.literal_addresses(path, ('hello',)), [('hello', 120, 0x8078)])

    def test_refuses_missing_smali(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(RuntimeError):
                module.inspect_smali(Path(temp))


if __name__ == '__main__':
    unittest.main()

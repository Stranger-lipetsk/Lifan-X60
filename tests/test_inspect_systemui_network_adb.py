import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('systemui_adb', ROOT / 'tools/inspect_systemui_network_adb.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SystemUIInspectTest(unittest.TestCase):
    def test_finds_only_method_containing_property(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'One.smali'
            path.write_text('.class public Lexample/One;\n.super Ljava/lang/Object;\n'
                            '.method public first()V\n    return-void\n.end method\n'
                            '.method public second()V\n    const-string v0, "service.adb.tcp.port"\n'
                            '    return-void\n.end method\n', encoding='utf-8')
            files, hits, classes = module.inspect(Path(tmp))
            self.assertEqual(len(files), 1)
            self.assertEqual(len(hits), 1)
            self.assertIn('second()V', hits[0][1])
            self.assertEqual(classes, {'Lexample/One;'})

    def test_empty_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(module.inspect(tmp), ([], [], set()))


if __name__ == '__main__':
    unittest.main()

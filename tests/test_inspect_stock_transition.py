import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from inspect_stock_transition import selected, contexts


class InspectMethodsTest(unittest.TestCase):
    def test_find_constructor_and_specific_method(self):
        content = ('.class public Lx;\n'
                   '.method public constructor <init>()V\n  return-void\n.end method\n'
                   '.method private scanPackageLI()V\n'
                   ' invoke-direct {p0}, Lx;->verifySignaturesLP()Z\n'
                   ' return-void\n.end method\n')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'x.smali'
            path.write_text(content)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                selected(path, ['<init>'])
                contexts(path, ['->verifySignaturesLP('], filter_names=('scanPackageLI',))
            self.assertIn('<init>()V', out.getvalue())
            self.assertIn('->verifySignaturesLP(', out.getvalue())

    def test_missing_method_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'x.smali'
            path.write_text('.class Lx;\n')
            with self.assertRaises(ValueError):
                selected(path, ['loadPreferences'])


if __name__ == '__main__':
    unittest.main()

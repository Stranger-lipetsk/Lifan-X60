import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import inspect_home_integration as probe


class HomeIntegrationInspectionTests(unittest.TestCase):
    def test_inventory_selects_ui_and_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home = root / 'smali/tw/com/elead/el830/home'
            home.mkdir(parents=True)
            (root / 'AndroidManifest.xml').write_text('<manifest/>')
            (home / 'Home.smali').write_text('''\.method private loadApplications(Z)V
    invoke-virtual {v0}, Ltw/com/elead/el830/home/HomeApp;->getEleadApps()Ljava/util/ArrayList;
    return-void
.end method
'''.replace('\\.method', '.method'))
            (home / 'Other.smali').write_text('''.method public go()V
    invoke-virtual {v0, v1}, Ltw/com/elead/el830/home/HomeApp;->gotoEleadApplication(Ljava/lang/String;)Z
    return-void
.end method
''')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                probe.main(root)
            self.assertIn('Home.smali .method private loadApplications', out.getvalue())
            self.assertIn('Other.smali .method public go', out.getvalue())
            self.assertIn('Methods selected: 2', out.getvalue())

    def test_refuses_missing_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'no smali'):
                probe.main(tmp)


if __name__ == '__main__':
    unittest.main()

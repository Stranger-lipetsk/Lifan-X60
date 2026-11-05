import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import experiment_home_carousel as patch


def stock_method(name):
    report = (ROOT / 'reports/stock-home-integration.txt').read_text(encoding='utf8')
    pattern = re.compile(r'(?ms)^\.method [^\n]*\b' + re.escape(name) + r'\([^\n]*\n.*?^\.end method')
    found = pattern.findall(report)
    if len(found) != 1:
        raise AssertionError(f'Expected exactly one stock method {name}')
    return found[0]


class OfflineHomePatchTests(unittest.TestCase):
    def setUp(self):
        self.initial = stock_method('initDefault_EL830CLF01')
        self.apps = stock_method('loadEleadApplications')
        self.ui = stock_method('loadApplications')

    def test_initial_list_appended_before_clone(self):
        result = patch.list_patch(self.initial)
        for package in patch.PACKAGES:
            self.assertEqual(result.count('"' + package + '"'), 1)
            self.assertLess(result.index('"' + package + '"'), result.index('->clone()'))
        self.assertIn('"com.navitel"', result)
        self.assertIn('"com.fpt.mirrorlink.android"', result)
        with self.assertRaises(ValueError):
            patch.list_patch(result)

    def test_new_app_branch_restricted_and_enable_gate_not_removed(self):
        result = patch.custom_app_method(self.apps)
        for package in patch.PACKAGES:
            self.assertIn('"' + package + '"', result)
        self.assertIn('goto/16 :cond_6', result)
        self.assertIn('->bMenuItem:Z', result)
        self.assertIn('->enable:Z', result)
        self.assertIn('->setActivity(', result)
        self.assertEqual(result.count('const-string v9, "com.fpt.mirrorlink.android"'), 1)
        self.assertNotIn('->gotoEleadApplication(', result)
        with self.assertRaises(ValueError):
            patch.custom_app_method(result)

    def test_ui_only_two_packages_uses_real_icons_and_label(self):
        result = patch.custom_ui_method(self.ui)
        for package in patch.PACKAGES:
            self.assertIn('"' + package + '"', result)
        self.assertIn('goto/16 :cond_4', result)
        self.assertIn('->loadIcon(', result)
        self.assertIn('->loadLabel(', result)
        block = result[result.index(':lifan_setup_ui'):]
        self.assertEqual(block.count('aput-object v13, v11, v12'), 3)
        self.assertIn('"com.navitel"', result)
        with self.assertRaises(ValueError):
            patch.custom_ui_method(result)

    def test_fail_closed_on_mismatched_stock(self):
        with self.assertRaises(ValueError):
            patch.list_patch(self.initial.replace('->clone()', '->unexpected()'))
        with self.assertRaises(ValueError):
            patch.custom_app_method(self.apps.replace('if-eqz v9, :cond_6', 'if-eqz v9, :different'))
        with self.assertRaises(ValueError):
            patch.custom_ui_method(self.ui.replace('if-eqz v11, :cond_4', 'if-eqz v11, :different'))

    def test_other_methods_untouched(self):
        dummy = '.method private unrelated()V\n    return-void\n.end method\n'
        app = dummy + self.initial + '\n' + self.apps
        ui = dummy + self.ui
        self.assertTrue(patch.patch_app(app).startswith(dummy))
        self.assertTrue(patch.patch_ui(ui).startswith(dummy))


if __name__ == '__main__':
    unittest.main()

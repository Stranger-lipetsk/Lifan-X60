import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import check_integrated_laboratory_image as check


class IntegratedImageTests(unittest.TestCase):
    def setUp(self):
        self.old = {p: ('file', 10, sha) for p, sha in check.OLD.items()}
        self.old[check.AMAZE] = ('file', 10, check.AMAZE_SHA)
        self.old['build.prop'] = ('file', 5, 'unchanged')
        self.expected = {p: 'new-' + p for p in check.OLD}
        self.expected['priv-app/Navitel-large.apk'] = check.NAVITEL_SHA
        self.expected[check.PANEL] = 'panel-sha'
        self.new = dict(self.old)
        for p, sha in self.expected.items():
            self.new[p] = ('file', 11, sha)

    def run_validation(self):
        with patch.object(check, 'tree', side_effect=[self.old, self.new]), contextlib.redirect_stdout(io.StringIO()):
            check.validate(Path('before'), Path('after'), self.expected)

    def test_expected_four_changes(self):
        self.run_validation()

    def test_unexpected_change_and_bad_digest_fail(self):
        self.new['build.prop'] = ('file', 5, 'wrong')
        with self.assertRaisesRegex(ValueError, 'unexpected image differences'):
            self.run_validation()
        self.new['build.prop'] = self.old['build.prop']
        self.new[check.PANEL] = ('file', 11, 'wrong')
        with self.assertRaisesRegex(ValueError, 'new file mismatch'):
            self.run_validation()

    def test_baseline_and_missing_panel_fail(self):
        self.old[check.AMAZE] = ('file', 10, 'wrong')
        self.new[check.AMAZE] = self.old[check.AMAZE]
        with self.assertRaisesRegex(ValueError, 'Amaze'):
            self.run_validation()
        self.old[check.AMAZE] = ('file', 10, check.AMAZE_SHA)
        self.new[check.AMAZE] = self.old[check.AMAZE]
        del self.new[check.PANEL]
        with self.assertRaisesRegex(ValueError, 'unexpected image differences'):
            self.run_validation()

    def test_rejects_unexpected_navitel(self):
        self.expected['priv-app/Navitel-large.apk'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'invalid expected'):
            self.run_validation()


if __name__ == '__main__':
    unittest.main()

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import check_navitel_candidate_image as check


class CompareNavitelImages(unittest.TestCase):
    def test_only_expected_change(self):
        old = {check.DEST: ('file', 111095055, check.ORIGINAL), 'other': ('file', 1, 'same')}
        new = {check.DEST: ('file', 99176587, check.CANDIDATE), 'other': ('file', 1, 'same')}
        with patch.object(check, 'tree', side_effect=[old, new]), contextlib.redirect_stdout(io.StringIO()):
            check.validate(Path('before'), Path('after'))
        new['other'] = ('file', 1, 'different')
        with patch.object(check, 'tree', side_effect=[old, new]), self.assertRaisesRegex(ValueError, 'unexpected'):
            check.validate(Path('before'), Path('after'))
        new['other'] = old['other']
        new[check.DEST] = ('file', 12, 'wrong')
        with patch.object(check, 'tree', side_effect=[old, new]), self.assertRaisesRegex(ValueError, 'SHA/type'):
            check.validate(Path('before'), Path('after'))


if __name__ == '__main__':
    unittest.main()

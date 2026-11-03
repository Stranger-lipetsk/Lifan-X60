import unittest
from tools.check_stock_fsck import validate


class StockFsckTests(unittest.TestCase):
    report = '''e2fsck 1.47.0 (5-Feb-2023)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
Padding at end of inode bitmap is not set. Fix? no

/tmp/system.img: ********** WARNING: Filesystem still has errors **********
/tmp/system.img: 1399/23040 files (0.0% non-contiguous), 85475/92160 blocks
'''

    def test_only_known_warning(self):
        validate(self.report, 4)

    def test_extra_issue_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.report + 'Free blocks count wrong. Fix? no\n', 4)

    def test_missing_warning_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.report.replace('Padding at end of inode bitmap is not set. Fix? no', ''), 4)

    def test_unexpected_status_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.report, 0)


if __name__ == '__main__':
    unittest.main()

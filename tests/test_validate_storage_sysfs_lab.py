import unittest
from html import escape
from tools.validate_storage_sysfs_lab import validate


def ui(sd='1048576', p5='UNKNOWN'):
    text = f'LAB ONLY\nP5_CAPACITY_BYTES={p5}\nLAB_SD_CAPACITY_BYTES={sd}\nPROBE_MOUNTS_BEGIN\nPROBE_MOUNTS_END'
    return '<h><n text="' + escape(text, quote=True).replace('\n', '&#10;') + '" /></h>'


class SysfsLabTest(unittest.TestCase):
    def test_match(self):
        self.assertIn('agree', validate(ui(), '2048\n', '179 0 1024 mmcblk0\n'))

    def test_absent(self):
        self.assertIn('absent', validate(ui('UNKNOWN'), 'No such file', ''))

    def test_shell_only(self):
        self.assertIn('UNKNOWN to app', validate(ui('UNKNOWN'), '2048\n', '179 0 1024 mmcblk0\n'))

    def test_mismatch(self):
        with self.assertRaises(ValueError): validate(ui('42'), '2048', '179 0 1024 mmcblk0')

    def test_impossible_without_shell(self):
        with self.assertRaises(ValueError): validate(ui(), '', '')


if __name__ == '__main__':
    unittest.main()

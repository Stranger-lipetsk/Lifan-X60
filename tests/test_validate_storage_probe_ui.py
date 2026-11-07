import unittest
from html import escape
from tools.validate_storage_probe_ui import validate

MOUNT = '/dev/block/mtdblock1 /data ext4 rw,seclabel 0 0\n'
DF = 'Filesystem Size Used Free Blksize\n/data 100.0M 60.0M 40.0M 4096\n'


def ui(available=30000, mount='/dev/block/mtdblock1 /data ext4 rw,seclabel'):
    text = ('LAB ONLY\nTOTAL_KIB=102400\nFREE_KIB=40960\nAVAILABLE_KIB=' + str(available) +
            '\nPROBE_MOUNTS_BEGIN\n' + mount + '\nPROBE_MOUNTS_END')
    return '<hierarchy><node text="' + escape(text, quote=True).replace('\n', '&#10;') + '" /></hierarchy>'


class StorageProbeTest(unittest.TestCase):
    def test_valid(self):
        values, _ = validate(ui(), MOUNT, DF)
        self.assertEqual(values['AVAILABLE_KIB'], 30000)

    def test_zero_available_is_valid(self):
        self.assertEqual(validate(ui(0), MOUNT, DF)[0]['AVAILABLE_KIB'], 0)

    def test_impossible_available(self):
        with self.assertRaises(ValueError): validate(ui(50000), MOUNT, DF)

    def test_wrong_mount(self):
        with self.assertRaises(ValueError): validate(ui(mount='tmpfs /data tmpfs rw'), MOUNT, DF)

    def test_no_df(self):
        with self.assertRaises(ValueError): validate(ui(), MOUNT, 'bad')

    def test_not_generic_guard(self):
        with self.assertRaises(ValueError): validate(ui().replace('LAB ONLY', 'OTHER'), MOUNT, DF)


if __name__ == '__main__':
    unittest.main()

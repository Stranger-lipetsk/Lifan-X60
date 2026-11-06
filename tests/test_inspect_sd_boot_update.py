import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('inspect_sd_boot_update', ROOT / 'tools/inspect_sd_boot_update.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SdBootInspectionTest(unittest.TestCase):
    def test_text_lines_include_partition_and_image(self):
        lines = module.text_matches('plain text\nwrite /dev/block/mmcblk0p5\nload system.img\n')
        self.assertEqual([x[0] for x in lines], [2, 3])

    def test_scan_does_not_follow_symlink_and_reports_binary_strings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'init.rc').write_text('service upgrade /sbin/update\nmount ext4 /dev/block/mmcblk0p5 /data\n')
            (root / 'binary').write_bytes(b'\x00unrelated\x00/dev/block/mmcblk0p3\x00system.img\x00')
            (root / 'link').symlink_to('init.rc')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                module.inspect(root)
            result = out.getvalue()
            self.assertIn('Symlinks: 1', result)
            self.assertIn('Text: init.rc', result)
            self.assertIn('Binary strings: binary', result)
            self.assertIn('/dev/block/mmcblk0p3', result)
            self.assertNotIn('Text: link', result)


if __name__ == '__main__':
    unittest.main()

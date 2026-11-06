import os
from pathlib import Path
import tempfile
import unittest
from tools.hibernate_tar_lab import FILES, compare, metadata

class CopyCheck(unittest.TestCase):
    def test_detects_changed_content_and_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            src, dst = Path(d)/'a', Path(d)/'b'
            for root in (src, dst):
                for relative in FILES:
                    p = root/relative
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text('synthetic\n')
                (root/'data/com.navitel/files/link-to-marker').symlink_to('lab-marker.txt')
                os.link(root/FILES[0], root/'data/com.navitel/files/hardlink-to-marker')
            compare(src, dst)
            (dst/FILES[1]).write_text('different')
            with self.assertRaises(AssertionError): compare(src, dst)
            (dst/FILES[1]).write_text('synthetic\n')
            original_mode = (dst/FILES[1]).stat().st_mode & 0o777
            (dst/FILES[1]).chmod(original_mode ^ 0o100)
            with self.assertRaises(AssertionError): compare(src, dst)
            (dst/FILES[1]).chmod(original_mode)
            link = dst/'data/com.navitel/files/link-to-marker'
            link.unlink()
            link.symlink_to('wrong-target')
            with self.assertRaises(AssertionError): compare(src, dst)

    def test_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'link'
            p.symlink_to('nonexistent')
            self.assertEqual(metadata(p)['target'], 'nonexistent')

if __name__ == '__main__': unittest.main()

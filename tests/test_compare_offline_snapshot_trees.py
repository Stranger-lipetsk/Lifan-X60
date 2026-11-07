import os
import shutil
import tempfile
import unittest
from pathlib import Path
from tools.compare_offline_snapshot_trees import compare


class TreeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.src = Path(self.tmp.name) / 'src'; self.dst = Path(self.tmp.name) / 'dst'
        self.src.mkdir(); (self.src / 'd').mkdir(); (self.src / 'd/f').write_bytes(b'synthetic')
        (self.src / 'link').symlink_to('d/f')
        shutil.copytree(self.src, self.dst, symlinks=True)

    def tearDown(self): self.tmp.cleanup()

    def test_match(self):
        stats, _ = compare(self.src, self.dst)
        self.assertEqual((stats['compared_files'], stats['compared_dirs'], stats['compared_symlinks']), (1, 1, 1))
        self.assertEqual(stats['content_mismatch'], 0)

    def test_changes_and_extra(self):
        (self.dst / 'd/f').write_bytes(b'altered!!')
        (self.dst / 'link').unlink(); (self.dst / 'link').symlink_to('other')
        (self.dst / 'extra').write_bytes(b'x')
        stats, _ = compare(self.src, self.dst)
        self.assertEqual(stats['content_mismatch'], 2)
        self.assertEqual(stats['extra'], 1)

    def test_xattr(self):
        try: os.setxattr(self.src / 'd/f', 'user.test', b'value')
        except OSError: self.skipTest('user xattrs unsupported')
        stats, names = compare(self.src, self.dst)
        self.assertEqual(stats['xattr_mismatch'], 1)
        self.assertEqual(names['user.test'], 1)

    def test_permissions(self):
        mode = os.stat(self.src / 'd/f').st_mode & 0o777
        os.chmod(self.dst / 'd/f', mode ^ 0o100)
        stats, _ = compare(self.src, self.dst)
        self.assertEqual(stats['metadata_mismatch_files'], 1)


if __name__ == '__main__': unittest.main()

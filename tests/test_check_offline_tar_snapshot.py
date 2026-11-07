import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from tools.check_offline_tar_snapshot import archive_name, verify


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        (self.root / 'file').write_bytes(b'synthetic')
        (self.root / 'directory').mkdir()
        (self.root / 'link').symlink_to('file')
        self.archive = Path(self.temp.name) / 'backup.tar'
        self.write()

    def tearDown(self): self.temp.cleanup()

    def write(self):
        with tarfile.open(self.archive, 'w') as ar:
            ar.add(self.root, arcname='.', recursive=True)

    def test_success_and_corrupt_source(self):
        counts, _, _ = verify(self.root, self.archive)
        self.assertEqual(counts, {'files': 1, 'dirs': 1, 'symlinks': 1})
        (self.root / 'file').write_bytes(b'changed!!')
        with self.assertRaisesRegex(ValueError, 'content mismatch'): verify(self.root, self.archive)

    def test_missing(self):
        (self.root / 'new').write_bytes(b'new')
        with self.assertRaisesRegex(ValueError, 'omitted'): verify(self.root, self.archive)

    def test_uid_and_mode(self):
        os.chmod(self.root / 'file', 0o600 if os.stat(self.root / 'file').st_mode & 0o777 != 0o600 else 0o644)
        with self.assertRaisesRegex(ValueError, 'metadata mismatch'): verify(self.root, self.archive)

    def test_symlink(self):
        (self.root / 'link').unlink(); (self.root / 'link').symlink_to('elsewhere')
        with self.assertRaisesRegex(ValueError, 'symlink mismatch'): verify(self.root, self.archive)

    def test_hardlink_and_fifo(self):
        os.link(self.root / 'file', self.root / 'hardlink')
        os.mkfifo(self.root / 'fifo')
        self.write()
        counts, special, _ = verify(self.root, self.archive)
        self.assertEqual(counts['files'], 2)
        self.assertEqual(special, 1)

    def test_duplicate_and_unsafe_paths(self):
        self.assertEqual(archive_name('./foo/bar'), 'foo/bar')
        for bad in ('../escape', '/absolute', './dir/../../escape'):
            with self.assertRaises(ValueError): archive_name(bad)
        with tarfile.open(self.archive, 'a') as ar:
            info = tarfile.TarInfo('./file'); info.size = 0; ar.addfile(info, io.BytesIO(b''))
        with self.assertRaises(ValueError): verify(self.root, self.archive)


if __name__ == '__main__': unittest.main()

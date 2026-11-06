import io
import tempfile
import unittest
from pathlib import Path
from tools.lazy_mount_fixture_writer import run


class WriterTest(unittest.TestCase):
    def test_expected_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'marker'
            p.write_bytes(b'INITIAL\n')
            out = io.StringIO()
            self.assertEqual(run(p, io.StringIO('before-switch\nafter-switch\nfinish\n'), out), 0)
            self.assertIn('OLD_FD_CONTAINS_BOTH=true', out.getvalue())
            self.assertEqual(p.read_bytes(), b'INITIAL\nWRITE_AFTER_SNAPSHOT_BEFORE_SWITCH\nWRITE_AFTER_SWITCH_OLD_FD\n')

    def test_unknown_command_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'marker'; p.write_text('INITIAL\n')
            with self.assertRaises(ValueError):
                run(p, io.StringIO('unexpected\n'), io.StringIO())

    def test_missing_operation_is_not_success(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'marker'; p.write_text('INITIAL\n')
            self.assertEqual(run(p, io.StringIO('finish\n'), io.StringIO()), 1)

if __name__ == '__main__': unittest.main()

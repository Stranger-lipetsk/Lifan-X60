import subprocess
import unittest
from pathlib import Path


class LegacyBackupDisabledTest(unittest.TestCase):
    def test_script_refuses_before_device_actions(self):
        script = Path(__file__).resolve().parents[1] / 'tools/backup-device.sh'
        for args in ([], ['--small'], ['--with-navi'], ['--help']):
            result = subprocess.run(['sh', str(script), *args], capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 1)
            self.assertIn('DISABLED', result.stderr)
            self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()

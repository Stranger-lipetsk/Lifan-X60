"""Host-only tests with mocked Android commands; never installs a real APK."""
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/one_apk_install.sh'


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.bin = root / 'bin'
        self.bin.mkdir()
        self.apk = root / 'example.apk'
        self.apk.write_bytes(b'fake apk for unit tests')
        self.digest = hashlib.sha256(self.apk.read_bytes()).hexdigest()
        self.calls = root / 'calls'
        self.mock('id', 'echo "${MOCK_UID:-0}"')
        self.mock('getprop', 'echo "${MOCK_BOOT:-1}"')
        self.mock('pm', '''echo "$*" >> "$MOCK_CALLS"
case "$1 $2" in
    'list packages') [ "${MOCK_PM_FAIL:-0}" = 0 ] || exit 1; printf '%s\\n' 'package:android' "${MOCK_INSTALLED:-package:other.app}" ;;
    'install '*) echo Success ;;
    'path '*) echo 'package:/data/app/test.example-1.apk' ;;
    *) exit 1 ;;
esac''')
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'], MOCK_CALLS=str(self.calls))

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, *flags, digest=None, package='test.example', **env):
        variables = self.env.copy()
        variables.update(env)
        return subprocess.run(['sh', str(SCRIPT), *flags, str(self.apk), package, digest or self.digest],
                              env=variables, text=True, capture_output=True)

    def log(self):
        return self.calls.read_text() if self.calls.exists() else ''

    def test_default_is_dry_run(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DRY RUN', result.stdout)
        self.assertNotIn('install ', self.log())

    def test_install_needs_confirmation(self):
        result = self.run_script('--install')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install ', self.log())

    def test_installs_only_after_explicit_confirmation(self):
        result = self.run_script('--install', '--confirm-desktop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install ', self.log())
        self.assertNotIn(' -r ', self.log())
        self.assertIn('path test.example', self.log())

    def test_existing_package_is_not_replaced(self):
        result = self.run_script('--install', '--confirm-desktop', MOCK_INSTALLED='package:test.example')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install ', self.log())

    def test_hash_mismatch_fails_before_pm(self):
        result = self.run_script('--install', '--confirm-desktop', digest='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_boot_root_and_pm_fail_closed(self):
        for env in ({'MOCK_BOOT': '0'}, {'MOCK_UID': '2000'}, {'MOCK_PM_FAIL': '1'}):
            with self.subTest(env=env):
                self.calls.unlink(missing_ok=True)
                result = self.run_script('--install', '--confirm-desktop', **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('install ', self.log())

    def test_invalid_package_rejected(self):
        result = self.run_script(package='test;bad')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()

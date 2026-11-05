import contextlib
import io
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from inspect_stock_file_access import inspect, scan_apks


class TraceTests(unittest.TestCase):
    def test_smali_detects_picker_and_reports_method(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'DocumentsUI' / 'smali'
            folder.mkdir(parents=True)
            (folder / 'DocumentsActivity.smali').write_text(
                '.method public test()V\n const-string v0, "android.intent.action.GET_CONTENT"\n.end method\n')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                inspect(Path(temp))
            self.assertIn('hits: 1', output.getvalue())
            self.assertIn('Full method', output.getvalue())

    def test_apk_scan_includes_extensionless_apk_and_reports_literal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for n in range(11):
                path = root / ('Launcher2' if n == 0 else f'{n}.apk')
                with zipfile.ZipFile(path, 'w') as apk:
                    data = b'android.provider.action.MANAGE_ROOT' if n == 0 else b'other'
                    apk.writestr('classes.dex', data)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                scan_apks(root)
            self.assertIn('literal match: Launcher2', out.getvalue())
            self.assertIn('ZIP/APK files scanned: 11', out.getvalue())

    def test_scan_reports_independent_literals_in_secondary_dex(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for n in range(10):
                with zipfile.ZipFile(root / f'{n}.apk', 'w') as apk:
                    apk.writestr('classes.dex', b'ordinary')
                    if n == 2:
                        apk.writestr('classes2.dex', b'android.intent.action.GET_CONTENT\x00application/vnd.android.package-archive')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                scan_apks(root)
            result = out.getvalue()
            self.assertIn('### GET_CONTENT: 1 APK(s)\nliteral match: 2.apk', result)
            self.assertIn('### APK_MIME: 1 APK(s)\nliteral match: 2.apk', result)
            self.assertIn('### MANAGE_ROOT: 0 APK(s)', result)
            self.assertIn('### OPEN_DOCUMENT: 0 APK(s)', result)

    def test_scan_rejects_missing_apks(self):
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(SystemExit):
            scan_apks(Path(temp))


if __name__ == '__main__':
    unittest.main()

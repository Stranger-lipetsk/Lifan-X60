import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.scan_android_artifacts import scan_file


class ScanAndroidArtifactsTests(unittest.TestCase):
    def test_scans_dex_and_native_members_in_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / "sample.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("classes.dex", b"Lcom/nforetek/bt/service/NfServiceSpp;")
                archive.writestr("lib/armeabi/bluelet.so", b"\x00SPP RFCOMM\x00")
                archive.writestr("assets/irrelevant.txt", b"SPP")
            hits = scan_file(apk, ("com.nforetek.bt.service.NfServiceSpp", "SPP", "RFCOMM"))
            joined = "\n".join(hits)
            self.assertIn("classes.dex", joined)
            self.assertIn("bluelet.so", joined)
            self.assertNotIn("irrelevant.txt", joined)

    def test_scans_raw_native_file(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "daemon"
            binary.write_bytes(b"\x00SPP server uses /dev/rfcomm0\x00")
            hits = scan_file(binary, ("SPP", "/dev/rfcomm"))
            self.assertEqual(len(hits), 1)
            self.assertIn("/dev/rfcomm0", hits[0])


if __name__ == "__main__":
    unittest.main()

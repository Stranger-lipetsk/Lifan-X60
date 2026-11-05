import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from experiment_launcher_manifest import remove_home, parse, HOME, ACTIVITY, PACKAGE


def binary_manifest(package=PACKAGE, activity=ACTIVITY, homes=1):
    strings = ['manifest', 'package', package, 'application', 'activity', 'name', activity,
               'intent-filter', 'action', 'android.intent.action.MAIN', 'category', HOME,
               'android.intent.category.DEFAULT', 'android.intent.category.MONKEY']
    strings = list(dict.fromkeys(strings))
    idx = {s: i for i, s in enumerate(strings)}
    blobs, offsets = bytearray(), []
    for s in strings:
        raw = s.encode('utf8')
        assert len(raw) < 128
        offsets.append(len(blobs))
        blobs.extend(bytes([len(s), len(raw)]) + raw + b'\0')
    while len(blobs) % 4:
        blobs.append(0)
    pool_size = 28 + len(offsets) * 4 + len(blobs)
    pool = (struct.pack('<HHIIIIII', 1, 28, pool_size, len(offsets), 0, 0x100,
                        28 + len(offsets) * 4, 0)
            + b''.join(struct.pack('<I', n) for n in offsets) + blobs)
    def start(name, attrs=()):
        attr = b''.join(struct.pack('<IIIHBBI', 0xffffffff, idx[k], idx[v], 8, 0, 3, idx[v]) for k, v in attrs)
        return (struct.pack('<HHIII', 0x102, 16, 36 + len(attr), 1, 0xffffffff)
                + struct.pack('<IIHHHHHH', 0xffffffff, idx[name], 20, 20, len(attrs), 0, 0, 0) + attr)
    def end(name):
        return struct.pack('<HHIIIII', 0x103, 16, 24, 1, 0xffffffff, 0xffffffff, idx[name])
    body = bytearray(pool)
    def leaf(name, value):
        body.extend(start(name, [('name', value)])); body.extend(end(name))
    body.extend(start('manifest', [('package', package)]))
    body.extend(start('application')); body.extend(start('activity', [('name', activity)]))
    body.extend(start('intent-filter'))
    leaf('action', 'android.intent.action.MAIN')
    for _ in range(homes): leaf('category', HOME)
    leaf('category', 'android.intent.category.DEFAULT'); leaf('category', 'android.intent.category.MONKEY')
    for name in ('intent-filter', 'activity', 'application', 'manifest'): body.extend(end(name))
    return struct.pack('<HHI', 3, 8, len(body) + 8) + body


class LauncherManifestTests(unittest.TestCase):
    def test_removes_only_home_category(self):
        before = binary_manifest()
        after = remove_home(before)
        self.assertEqual(len(before) - len(after), 80)
        tree = parse(after).semantic()
        self.assertNotIn(HOME, repr(tree))
        self.assertIn(ACTIVITY, repr(tree))
        self.assertIn('android.intent.category.DEFAULT', repr(tree))
        self.assertIn('android.intent.category.MONKEY', repr(tree))
        with self.assertRaisesRegex(ValueError, 'expected one HOME'):
            remove_home(after)

    def test_wrong_input_fails_closed(self):
        for value in (binary_manifest(homes=0), binary_manifest(homes=2),
                      binary_manifest(package='wrong.package'), binary_manifest(activity='wrong.Activity')):
            with self.assertRaises(ValueError):
                remove_home(value)
        with self.assertRaises(ValueError):
            remove_home(binary_manifest()[:-1])


if __name__ == '__main__':
    unittest.main()

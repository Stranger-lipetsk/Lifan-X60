#!/usr/bin/env python3
"""
Минимальный парсер AndroidManifest.xml (AXML) без aapt.
Извлекает: package, versionName, versionCode, minSdkVersion, targetSdkVersion, label, разрешения.
"""
import struct
import sys
import zipfile

RES_IDS = {
    0x0101020C: 'minSdkVersion',
    0x01010270: 'targetSdkVersion',
    0x0101021B: 'versionCode',
    0x0101021C: 'versionName',
    0x01010001: 'label',
}


class Axml:
    def __init__(self, data):
        self.d = data
        self.strings = []
        self.resmap = []
        self._parse_header()

    def _parse_header(self):
        d = self.d
        if len(d) < 8 or struct.unpack('<H', d[0:2])[0] != 0x0003:
            raise ValueError('не AXML')
        pos = 8
        total = struct.unpack('<I', d[4:8])[0]
        while pos + 8 <= min(total, len(d)):
            ctype, hsize, csize = struct.unpack('<HHI', d[pos:pos + 8])
            if csize < 8:
                break
            chunk = d[pos:pos + csize]
            if ctype == 0x0001:      # string pool
                self._parse_strings(chunk, hsize)
            elif ctype == 0x0180:    # resource map
                n = (csize - hsize) // 4
                self.resmap = list(struct.unpack('<%dI' % n, chunk[hsize:hsize + n * 4]))
            pos += csize

    def _parse_strings(self, chunk, hsize):
        count, style_count, flags, strings_start, styles_start = struct.unpack(
            '<IIIII', chunk[hsize:hsize + 20])
        utf8 = bool(flags & 0x100)
        offs = struct.unpack('<%dI' % count, chunk[hsize + 20: hsize + 20 + count * 4])
        base = hsize + strings_start
        out = []
        for off in offs:
            p = base + off
            try:
                if utf8:
                    # u16len, u8len
                    n = chunk[p]
                    p += 2 if n & 0x80 else 1
                    ln = chunk[p]
                    if ln & 0x80:
                        ln = ((ln & 0x7F) << 8) | chunk[p + 1]
                        p += 2
                    else:
                        p += 1
                    out.append(chunk[p:p + ln].decode('utf-8', 'replace'))
                else:
                    ln = struct.unpack('<H', chunk[p:p + 2])[0]
                    p += 2
                    if ln & 0x8000:
                        ln2 = struct.unpack('<H', chunk[p:p + 2])[0]
                        ln = ((ln & 0x7FFF) << 16) | ln2
                        p += 2
                    out.append(chunk[p:p + ln * 2].decode('utf-16-le', 'replace'))
            except Exception:
                out.append('')
        self.strings = out

    def str_at(self, i):
        return self.strings[i] if 0 <= i < len(self.strings) else ''

    def parse(self):
        d = self.d
        pos = 8
        total = struct.unpack('<I', d[4:8])[0]
        info = {'permissions': [], 'features': []}
        while pos + 8 <= min(total, len(d)):
            ctype, hsize, csize = struct.unpack('<HHI', d[pos:pos + 8])
            if csize < 8:
                break
            if ctype == 0x0102:      # START_TAG
                ns_i, name_i, attr_start, attr_size, attr_count = struct.unpack(
                    '<iiHHH', d[pos + 8: pos + 20])
                tag = self.str_at(name_i)
                attrs = {}
                p = pos + 8 + attr_start
                for _ in range(attr_count):
                    a_ns, a_name, a_raw, a_tsize, a_res0, a_type = struct.unpack(
                        '<iiiHBB', d[p:p + 16])
                    val = self._attr_value(a_type, d[p + 16:p + 20], a_raw)
                    aname = self.str_at(a_name)
                    key = RES_IDS.get(a_res0, aname)
                    attrs[key] = val
                    p += a_tsize
                if tag == 'manifest':
                    info['package'] = attrs.get('package', info.get('package', ''))
                    info['versionName'] = attrs.get('versionName', '')
                    info['versionCode'] = attrs.get('versionCode', '')
                elif tag == 'uses-sdk':
                    info['minSdkVersion'] = attrs.get('minSdkVersion', '')
                    info['targetSdkVersion'] = attrs.get('targetSdkVersion', '')
                elif tag == 'uses-permission':
                    n = attrs.get('name', '')
                    if n:
                        info['permissions'].append(n)
                elif tag == 'uses-feature':
                    n = attrs.get('name', '')
                    if n:
                        info['features'].append(n)
            pos += csize
        return info

    def _attr_value(self, t, raw4, raw_idx):
        if t == 0x03:
            return self.str_at(struct.unpack('<i', raw4)[0])
        if t == 0x12:
            return bool(raw4[0])
        if t in (0x10, 0x11):
            return struct.unpack('<i', raw4)[0]
        if t == 0x01:
            return self.str_at(raw_idx)
        return struct.unpack('<i', raw4)[0]


def apk_info(path):
    with zipfile.ZipFile(path) as z:
        man = z.read('AndroidManifest.xml')
        names = z.namelist()
    a = Axml(man)
    info = a.parse()
    info['_apk_size'] = None
    info['_dex'] = [n for n in names if n.endswith('.dex')]
    info['_native'] = [n for n in names if n.endswith('.so')][:8]
    info['_abis'] = sorted({n.split('/')[1] for n in names
                            if n.startswith('lib/') and '/' in n[4:]})
    return info


if __name__ == '__main__':
    for p in sys.argv[1:]:
        try:
            i = apk_info(p)
            print(f'=== {p}')
            for k in ('package', 'versionName', 'versionCode', 'minSdkVersion',
                      'targetSdkVersion', '_dex', '_native', '_abis'):
                if k in i:
                    print(f'  {k}: {i[k]}')
            print(f'  разрешений: {len(i.get("permissions", []))}')
        except Exception as e:
            print(f'=== {p}: ОШИБКА {e}')

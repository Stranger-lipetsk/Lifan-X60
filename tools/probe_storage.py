#!/usr/bin/env python3
"""
Проба накопителей и путей Navitel в system.img.

Отвечает на вопросы:
  * откуда берётся русский язык (есть ли res/values-ru в framework-res.apk);
  * какие пути к картам использует Navitel и что он ищет на накопителях;
  * какие точки монтирования и симлинки есть в системе (SD / USB / emmc_data);
  * какие версии Navitel доступны для скачивания официально.

Использование: python3 tools/probe_storage.py <system.img> [<отчёты>]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

PATHS_OF_INTEREST = [
    '/storage/', '/mnt/', '/sdcard', '/extsd', '/usb', '/emmc_data',
    'Navngo', 'NavitelContent', 'navitel', 'NaviTel', 'Maps', 'maps',
]


def sh(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return (p.stdout or '') + (p.stderr or '')


def debugfs_dump(img, inner_path, out_file):
    """Вытаскивает один файл из образа."""
    if os.path.exists(out_file):
        os.remove(out_file)
    sh(f'debugfs -R "dump {inner_path} {out_file}" "{img}"')
    return out_file if os.path.exists(out_file) and os.path.getsize(out_file) > 0 else None


def locale_report(fr_apk, out):
    out.append('=== 1. ЛОКАЛИ в framework-res.apk ===')
    if not fr_apk:
        out.append('  framework-res.apk не извлечён')
        return
    try:
        with zipfile.ZipFile(fr_apk) as z:
            names = z.namelist()
            res_dirs = sorted({n.split('/')[1] for n in names
                               if n.startswith('res/') and n.count('/') > 1})
        vals = [d for d in res_dirs if d.startswith('values')]
        out.append(f'  всего каталогов ресурсов: {len(res_dirs)}')
        out.append(f'  варианты values*: {len(vals)}')
        out.append('  ' + ', '.join(vals[:60]))
        ru = [d for d in vals if re.search(r'ru', d)]
        out.append(f'  >>> русские варианты: {ru if ru else "НЕ НАЙДЕНЫ"}')
        # посмотрим, есть ли строки вообще
        for probe in ('resources.arsc',):
            if probe in names:
                out.append(f'  {probe}: есть ({z.getinfo(probe).file_size} байт)')
    except Exception as e:
        out.append(f'  ошибка: {e}')

    # ищем упоминания языков в resources.arsc (имена конфигураций)
    try:
        raw = zipfile.ZipFile(fr_apk).read('resources.arsc')
        txt = b' '.join(re.findall(rb'[\x20-\x7e]{2,}', raw)).decode('latin-1')
        langs = sorted(set(re.findall(r'\b(ru|zh|en|de|fr|es|it|pt|tr|pl|uk|kk)\b', txt)))
        out.append(f'  языковые коды в resources.arsc: {langs}')
    except Exception as e:
        out.append(f'  resources.arsc: {e}')


def navitel_apk_report(apk, out, title):
    out.append(f'=== Navitel APK: {title} ===')
    if not apk:
        out.append('  не извлечён')
        return
    out.append(f'  размер: {os.path.getsize(apk)} байт')
    try:
        with zipfile.ZipFile(apk) as z:
            names = z.namelist()
            out.append(f'  файлов: {len(names)}')
            libs = [n for n in names if n.endswith('.so')][:10]
            out.append(f'  нативные библиотеки: {libs}')
            blob = b''
            for n in names:
                if n.endswith('.dex') or n == 'resources.arsc':
                    blob += z.read(n)[:40_000_000]
        found = {}
        for pat in PATHS_OF_INTEREST:
            c = len(re.findall(re.escape(pat).encode(), blob, re.I))
            if c:
                found[pat] = c
        out.append(f'  упоминания путей (в dex/arsc): {found}')
        # конкретные строки-пути
        strings = re.findall(rb'/[a-zA-Z0-9_./-]{4,60}', blob)
        paths = sorted({s.decode('latin-1') for s in strings
                        if any(k in s.lower() for k in
                               (b'storage', b'mnt', b'sdcard', b'navi', b'extsd',
                                b'usb', b'emmc', b'ng'))})
        out.append(f'  найденные пути ({len(paths)}):')
        for p in paths[:40]:
            out.append(f'    {p}')
    except Exception as e:
        out.append(f'  ошибка: {e}')


def storage_config_report(img, tmp, out):
    out.append('=== 2. Точки монтирования и симлинки в системе ===')
    for f in ('fstab.el_imx6_solo_v2', 'init.rc', 'init.el_imx6_solo_v2.rc',
              'ueventd.el_imx6_solo_v2.rc'):
        p = debugfs_dump(img, f'/{f}', os.path.join(tmp, f))
        if not p:
            continue
        txt = open(p, errors='replace').read()
        hits = [ln.strip() for ln in txt.splitlines()
                if re.search(r'(storage|media_rw|extsd|usb|emmc_data|sdcard|vold)', ln, re.I)
                and not ln.strip().startswith('#')]
        out.append(f'  --- /{f} (совпадений {len(hits)}) ---')
        for h in hits[:25]:
            out.append(f'    {h}')

    # чтение /etc на предмет настроек навигации
    out.append('=== 3. /etc: настройки навигации и хранилищ ===')
    ls = sh(f'debugfs -R "ls -l /etc" "{img}"')
    out.append('  ' + ls.replace('\n', '\n  ')[:2500])
    for cand in ('eGTouchA_v2.5.2112.A-a.ini', 'ota.conf', 'hosts'):
        p = debugfs_dump(img, f'/etc/{cand}', os.path.join(tmp, cand))
        if p:
            txt = open(p, errors='replace').read()
            if re.search(r'(navi|storage|sdcard|map)', txt, re.I):
                out.append(f'  --- /etc/{cand} ---')
                out.append('  ' + txt[:1200].replace('\n', '\n  '))


def navitel_downloads(out):
    out.append('=== 4. Доступные официальные сборки Navitel ===')
    base = 'https://download.navitel.ru/Android/'
    candidates = [
        'Navitel-v12.6.1552-Google-full.apk',
        'Navitel-v11.11.1128-Google-full.apk',
        'Navitel-v11.11.1110-Google-full.apk',
        'Navitel-11.11.1128-full-armeabi.apk',
        'Navitel-v11.11.659-Google-full.apk',
        'Navitel-9.13.73-full-armeabi.apk',
    ]
    for c in candidates:
        url = base + c
        try:
            req = urllib.request.Request(url, method='HEAD',
                                         headers={'User-Agent': 'Mozilla/5.0'})
            r = urllib.request.urlopen(req, timeout=30)
            size = r.headers.get('Content-Length')
            ctype = r.headers.get('Content-Type')
            out.append(f'  {c}: {r.status} | {size} байт | {ctype}')
        except Exception as e:
            code = getattr(e, 'code', '')
            out.append(f'  {c}: ОШИБКА {code} {e}')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    img = sys.argv[1]
    rep_dir = sys.argv[2] if len(sys.argv) > 2 else 'reports'
    os.makedirs(rep_dir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='probe_')
    out = []

    def w(s=''):
        print(s, flush=True)
        out.append(str(s))

    w(f'образ: {img} ({os.path.getsize(img)} байт)')

    fr = debugfs_dump(img, '/framework/framework-res.apk', os.path.join(tmp, 'framework-res.apk'))
    locale_report(fr, out)

    nav_stock = debugfs_dump(img, '/priv-app/Navitel-9.13.73-large.apk',
                             os.path.join(tmp, 'navitel-stock.apk'))
    navitel_apk_report(nav_stock, out, 'стоковый 9.13.73 из прошивки')

    storage_config_report(img, tmp, out)
    navitel_downloads(out)

    path = os.path.join(rep_dir, 'проба-накопители.txt')
    open(path, 'w').write('\n'.join(out))
    print(f'\nотчёт: {path}')
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
Проход 3: определение eMMC (MBR/GPT), разбор кастомных APK, поиск скрытых
настроек, оценка объёма RAM, разбор config.ini/para_fw.
"""
import os
import re
import struct
import subprocess
import sys
import zipfile


def sh(cmd):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return p.stdout + p.stderr
    except Exception as e:
        return str(e)


def mbr_report(path):
    out = []
    with open(path, 'rb') as f:
        mbr = f.read(512)
    if mbr[510:512] != b'\x55\xaa':
        out.append(f'{path}: нет MBR-подписи 0x55AA (первые байты {mbr[:16].hex()})')
        return out
    total_sectors = None
    # защитный MBR (GPT)
    out.append('=== Таблица разделов (MBR) ===')
    for i in range(4):
        e = mbr[446 + i * 16: 446 + (i + 1) * 16]
        status, ctype = e[0], e[4]
        start, size = struct.unpack('<II', e[8:16])
        if size == 0 and start == 0:
            continue
        out.append(f'  раздел {i+1}: type=0x{ctype:02x} status={status:#x} '
                   f'start_sector={start} sectors={size} '
                   f'({size * 512 / 1024 / 1024:.1f} МиБ) конец={(start+size)*512/1024/1024:.1f} МиБ')
        total_sectors = max(total_sectors or 0, start + size)
    if total_sectors:
        out.append(f'  >>> оценка полного размера носителя по таблице: '
                   f'{total_sectors * 512 / 1024**3:.2f} ГиБ')
    # сигнатуры внутри
    with open(path, 'rb') as f:
        head = f.read(64 * 1024 * 1024)
    for name, sig in (('ext4', b'\x53\xef'), ('FAT32', b'FAT32'),
                      ('ANDROID!', b'ANDROID!'), ('gzip', b'\x1f\x8b\x08')):
        idx = head.find(sig)
        if idx >= 0:
            out.append(f'  найдена сигнатура {name} @ {idx}')
    return out


def apk_info(path):
    """Манифест APK: пакет, minSdk, targetSdk, разрешения (через aapt-less разбор)."""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            data = z.read('AndroidManifest.xml')
            strs = b'\x00'.join(re.findall(rb'[\x20-\x7e]{4,}', data))
            txt = strs.decode('latin-1')
            pkgs = re.findall(r'(?:[a-z][a-z0-9_]*\.){2,}[A-Za-z0-9_]+', txt)
            perms = sorted(set(re.findall(r'android\.permission\.[A-Z_]+', txt)))
            return {
                'entries': len(names),
                'dex': [n for n in names if n.endswith('.dex')],
                'apk_native': [n for n in names if n.endswith('.so')][:10],
                'packages': sorted(set(pkgs))[:5],
                'permissions': perms[:25],
            }
    except Exception as e:
        return {'error': str(e)}


def main():
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    rep = []

    def w(s=''):
        rep.append(str(s))
        print(s, flush=True)

    # ---------- 1. разделы из sd_boot.img ----------
    w('################ 1. РАЗМЕТКА НОСИТЕЛЯ (sd_boot.img)')
    for root, _, files in os.walk(src):
        for fn in files:
            if fn.lower() in ('sd_boot.img', 'system.img', 'boot.img'):
                p = os.path.join(root, fn)
                w(f'--- {fn} ({os.path.getsize(p)} байт) ---')
                for line in mbr_report(p):
                    w(line)
                w()

    # ---------- 2. config.ini / sys_info.cfg / video.cfg ----------
    w('################ 2. КОНФИГИ ПАРАМЕТРОВ (para_fw / backup)')
    for root, _, files in os.walk(src):
        for fn in files:
            if fn.lower() in ('config.ini', 'sys_info.cfg', 'video.cfg', 'tp_verinfo'):
                p = os.path.join(root, fn)
                raw = open(p, 'rb').read()
                w(f'--- {p} ({len(raw)} байт) ---')
                w(raw[:4000].decode('utf-8', 'replace'))
                w(f'hex: {raw[:128].hex()}')
                w()

    # ---------- 3. кастомные APK ----------
    w('################ 3. КАСТОМНЫЕ ПРИЛОЖЕНИЯ (Elead/Lifan)')
    apk_dirs = []
    for root, dirs, files in os.walk(src):
        for fn in files:
            if fn.endswith('.apk') and re.search(r'(EL\d|Home|Settings|Avin|IQQI|MediaPlayer|Radio|BT)', fn, re.I):
                apk_dirs.append(os.path.join(root, fn))
    w(f'найдено APK: {len(apk_dirs)}')
    for p in apk_dirs[:40]:
        info = apk_info(p)
        w(f'--- {os.path.basename(p)} ({os.path.getsize(p)} байт)')
        for k, v in info.items():
            if k == 'permissions':
                w(f'    права: {", ".join(v)}')
            else:
                w(f'    {k}: {v}')

    # ---------- 4. поиск инженерного меню и скрытых настроек ----------
    w()
    w('################ 4. ИНЖЕНЕРНОЕ МЕНЮ / СКРЫТЫЕ НАСТРОЙКИ')
    keys = ('factory', 'engineering', 'engineer', 'adb', 'root', 'debug',
            'mcu', 'gpio', 'calibration', 'touch', 'can', 'password', '8888',
            'update', 'upgrade', 'hidden', 'secret')
    for p in apk_dirs:
        if not re.search(r'(ElSettings|Home|Settings)', p, re.I):
            continue
        try:
            with zipfile.ZipFile(p) as z:
                data = z.read('classes.dex')
        except Exception:
            continue
        found = {}
        for k in keys:
            n = len(re.findall(k.encode(), data, re.I))
            if n:
                found[k] = n
        w(f'--- {os.path.basename(p)}: {found}')

    # ---------- 5. RAM: ищем в бинарниках упоминания объёма ----------
    w()
    w('################ 5. ПРИЗНАКИ ОБЪЁМА RAM (эвристика)')
    for root, _, files in os.walk(src):
        for fn in files:
            if fn.endswith(('.img', '.bin')) and os.path.getsize(os.path.join(root, fn)) < 60_000_000:
                p = os.path.join(root, fn)
                s = sh(f'strings -n 6 "{p}" | grep -iE "MemTotal|Memory: [0-9]|512MB|1024MB|totalram|DDR3|el_data|para_fw" | sort -u | head -30')
                if s.strip():
                    w(f'--- {fn} ---')
                    w(s)

    open(os.path.join(out_dir, 'проход3.txt'), 'w').write('\n'.join(rep))


if __name__ == '__main__':
    main()

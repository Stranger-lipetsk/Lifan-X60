#!/usr/bin/env python3
"""
Глубокий разбор Home.apk: как оболочка запускает приложения и что делает с MirrorLink.

Ищет в dex строки констант (LDC) вокруг упоминаний MirrorLink/package names,
чтобы найти точные имена пакетов и активностей.
"""
import os
import re
import sys
import zipfile

KEYS = ['mirrorlink', 'fpt.', 'packageName', 'Intent', 'startActivity',
        'getLaunchIntentForPackage', 'setClassName', 'ComponentName', 'APK_PATH']


def dex_strings(path, member):
    try:
        with zipfile.ZipFile(path) as z:
            data = z.read(member)
    except Exception:
        return []
    out = []
    for m in re.finditer(rb'[\x20-\x7e]{4,}', data):
        s = m.group().decode('latin-1')
        out.append(s)
    return out


def main():
    apk = sys.argv[1]
    out = []

    def w(s=''):
        print(s, flush=True)
        out.append(str(s))

    with zipfile.ZipFile(apk) as z:
        members = [n for n in z.namelist() if n.endswith('.dex')]
    w(f'dex-файлов: {len(members)} -> {members}')

    all_str = []
    for mem in members:
        all_str.extend(dex_strings(apk, mem))
    w(f'строк извлечено: {len(all_str)}')

    w('\n=== 1. Всё, что похоже на MirrorLink / FPT ===')
    for s in sorted(set(all_str)):
        if 'mirror' in s.lower() or 'fpt' in s.lower():
            w(f'  {s}')

    w('\n=== 2. Строки APK/пути, которые оболочка пытается открыть ===')
    for s in sorted(set(all_str)):
        if re.search(r'\.apk\b|/data/|/mnt/|/system/app|/storage/', s, re.I):
            w(f'  {s}')

    w('\n=== 3. Пакеты, которые оболочка знает (полный список) ===')
    pkgs = sorted({s for s in all_str
                   if re.fullmatch(r'(com|tw|org|net)\.[a-z0-9_]+(\.[a-z0-9_]+)+', s)})
    for p in pkgs:
        w(f'  {p}')

    w('\n=== 4. Строки с Manifest.permission / action запуска ===')
    for s in sorted(set(all_str)):
        if s.startswith('android.intent.action.') or s.startswith('android.intent.category.'):
            w(f'  {s}')

    open('reports/разбор-home-глубокий.txt', 'w').write('\n'.join(out))
    print('\nотчёт: reports/разбор-home-глубокий.txt')


if __name__ == '__main__':
    main()

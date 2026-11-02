#!/usr/bin/env python3
"""
Правка system.img БЕЗ пересборки файловой системы.

В отличие от build_system.py (который распаковывает образ и собирает ext4
заново через mke2fs), этот скрипт меняет файлы прямо в существующей
файловой системе через debugfs. Суперблок, размер, журнал и размещение
inode остаются заводскими — то есть ФС остаётся ровно такой, какую
ядро 3.0.35 уже успешно монтировало.

Использование:
    python3 tools/inplace_patch.py --system system.img --out patched.img
    python3 tools/inplace_patch.py --system system.img --out patched.img \
        --remove /priv-app/Navitel-9.13.73-large.apk \
        --add-apk /path/App.apk:/app \
        --add-file /path/script.sh:/etc/script.sh
"""
import argparse
import os
import re
import shutil
import subprocess
import sys


def debugfs(img, cmd, sudo=()):
    full = list(sudo) + ['debugfs', '-w', '-R', cmd, img]
    p = subprocess.run(full, capture_output=True, text=True)
    return (p.stdout or '') + (p.stderr or ''), p.returncode


def has_sudo():
    if os.geteuid() == 0:
        return []
    r = subprocess.run(['sudo', '-n', 'true'], capture_output=True)
    return ['sudo', '-n'] if r.returncode == 0 else []


def stat_mode(img, path, sudo):
    out, _ = debugfs(img, f'stat {path}', sudo)
    m = re.search(r'Mode:\s+(\d+)', out)
    if m:
        return int(m.group(1), 8)
    return None


def file_size(img, path, sudo):
    out, _ = debugfs(img, f'stat {path}', sudo)
    m = re.search(r'Size:\s+(\d+)', out)
    return int(m.group(1)) if m else None


def free_blocks(img, sudo):
    out, _ = debugfs(img, 'stats', sudo)
    m = re.search(r'Free blocks:\s+(\d+)', out)
    b = re.search(r'Block size:\s*(\d+)', out)
    if m and b:
        return int(m.group(1)) * int(b.group(1))
    return None


def read_file(img, path, sudo, dest):
    out, _ = debugfs(img, f'dump {path} {dest}', sudo)
    return os.path.exists(dest)


def apply_props(img, pairs, sudo):
    """Правит /build.prop: заменяет существующий ключ или добавляет новый.

    Почему в build.prop: это единственное место, которое читается до
    запуска Android. Часовой пояс лежит в persist.sys.timezone — если его
    там нет, система берёт пояс из настроек, а они сбрасываются при
    перепрошивке (раздел data форматируется).
    """
    tmp = '/tmp/build.prop.patch'          # читаем (файл создаёт debugfs)
    tmp_w = '/tmp/build.prop.patch.new'    # пишем отдельно: первый может
                                           # принадлежать root после dump
    if not read_file(img, '/build.prop', sudo, tmp):
        print('  ВНИМАНИЕ: /build.prop не найден, свойства не заданы')
        return
    with open(tmp, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()

    changed, added = [], []
    for pair in pairs:
        if '=' not in pair:
            print(f'  пропуск (нет =): {pair}')
            continue
        key, val = pair.split('=', 1)
        found = False
        for i, ln in enumerate(lines):
            if ln.strip().startswith(key + '='):
                old = ln.split('=', 1)[1]
                if old == val:
                    print(f'  свойство уже такое: {key}={val}')
                else:
                    lines[i] = f'{key}={val}'
                    changed.append(f'{key}: {old} -> {val}')
                found = True
                break
        if not found:
            lines.append(f'{key}={val}')
            added.append(f'{key}={val}')

    if changed or added:
        with open(tmp_w, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
        os.chmod(tmp_w, 0o644)
        debugfs(img, 'rm /build.prop', sudo)
        out, rc = debugfs(img, f'write "{tmp_w}" /build.prop', sudo)
        debugfs(img, 'sif /build.prop mode 0100644', sudo)
        debugfs(img, 'sif /build.prop uid 0', sudo)
        debugfs(img, 'sif /build.prop gid 0', sudo)
        print(f'  build.prop: строк {len(lines)}')
        for c in changed:
            print(f'  свойство заменено: {c}')
        for a in added:
            print(f'  свойство добавлено: {a}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--system', required=True, help='исходный system.img')
    ap.add_argument('--out', required=True, help='куда писать результат')
    ap.add_argument('--remove', action='append', default=[],
                    help='путь внутри образа, который удалить')
    ap.add_argument('--add-apk', action='append', default=[],
                    metavar='ФАЙЛ:/КАТАЛОГ', help='добавить APK')
    ap.add_argument('--add-file', action='append', default=[],
                    metavar='ФАЙЛ:/ПУТЬ', help='добавить файл')
    ap.add_argument('--set-prop', action='append', default=[],
                    metavar='КЛЮЧ=ЗНАЧЕНИЕ',
                    help='задать свойство в /build.prop (заменяет или добавляет)')
    args = ap.parse_args()

    sudo = has_sudo()
    if sudo:
        print('использую sudo для записи в образ')

    if not os.path.exists(args.system):
        sys.exit(f'нет файла {args.system}')

    shutil.copyfile(args.system, args.out)
    os.chmod(args.out, 0o644)
    print(f'копия: {args.system} -> {args.out} ({os.path.getsize(args.out)} байт)')

    free_before = free_blocks(args.out, sudo)
    if free_before:
        print(f'свободно в образе до правок: {free_before / 1024 / 1024:.1f} МиБ')

    # ---- удаление ----
    for path in args.remove:
        sz = file_size(args.out, path, sudo)
        out, rc = debugfs(args.out, f'rm {path}', sudo)
        if 'File not found' in out or rc != 0:
            print(f'  НЕ НАЙДЕНО (пропуск): {path}')
        else:
            print(f'  удалено: {path}'
                  + (f' ({sz / 1024 / 1024:.1f} МиБ)' if sz else ''))

    # ---- добавление APK ----
    for spec in args.add_apk:
        src, destdir = spec.split(':', 1)
        if not os.path.exists(src):
            print(f'  НЕТ ФАЙЛА: {src}')
            continue
        name = os.path.basename(src)
        dest = destdir.rstrip('/') + '/' + name
        if file_size(args.out, dest, sudo) is not None:
            print(f'  заменяю: {dest}')
        debugfs(args.out, f'rm {dest}', sudo)
        out, rc = debugfs(args.out, f'write "{src}" {dest}', sudo)
        if 'could not' in out.lower() or 'error' in out.lower():
            print(f'  ОШИБКА записи {dest}: {out.strip()[:200]}')
            continue
        debugfs(args.out, f'sif {dest} mode 0100644', sudo)
        print(f'  добавлено: {dest} ({os.path.getsize(src)} байт)')

    # ---- добавление прочих файлов (с правом исполнения для .sh) ----
    for spec in args.add_file:
        src, dest = spec.split(':', 1)
        if not os.path.exists(src):
            print(f'  НЕТ ФАЙЛА: {src}')
            continue
        # если файл уже есть, debugfs создаст рядом копию («файл.1») —
        # поэтому прежнюю запись удаляем всегда, до записи
        existed = file_size(args.out, dest, sudo) is not None
        debugfs(args.out, f'rm {dest}', sudo)
        if existed:
            print(f'  заменяю: {dest}')
        out, rc = debugfs(args.out, f'write "{src}" {dest}', sudo)
        if 'could not' in out.lower() or 'error' in out.lower():
            print(f'  ОШИБКА записи {dest}: {out.strip()[:200]}')
            continue
        mode = '0100755' if src.endswith('.sh') else '0100644'
        debugfs(args.out, f'sif {dest} mode {mode}', sudo)
        print(f'  добавлено: {dest} (режим {mode})')

    # ---- свойства в /build.prop ----
    if args.set_prop:
        apply_props(args.out, args.set_prop, sudo)

    freed = free_blocks(args.out, sudo)
    if freed:
        print(f'свободно в образе после правок: {freed / 1024 / 1024:.1f} МиБ')

    # ---- проверка целостности ----
    print('--- проверка ФС ---')
    p = subprocess.run(list(sudo) + ['e2fsck', '-fn', args.out],
                       capture_output=True, text=True)
    txt = (p.stdout or '') + (p.stderr or '')
    clean = p.returncode in (0, 1) and 'FILE SYSTEM WAS MODIFIED' not in txt
    print('e2fsck:', 'чисто' if p.returncode == 0 else f'код {p.returncode}')
    for ln in txt.splitlines():
        if any(k in ln for k in ('Pass 1', 'Pass 5', 'files', 'blocks')):
            print('  ' + ln.strip())

    print(f'\nГОТОВО: {args.out}')
    print(f'размер: {os.path.getsize(args.out)} байт')
    if not clean:
        sys.exit('внимание: e2fsck сообщил о проблемах')


if __name__ == '__main__':
    main()

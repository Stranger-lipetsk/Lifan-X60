#!/usr/bin/env python3
"""
Сборка модифицированного system.img для ГУ Elead EL-830C-LF01 (Lifan X60 FL).

Что делает (Стратегия A — сохраняем штатный Android 4.4.2 и весь функционал):

  1. Достаёт system.img из архива прошивки (RAR) или берёт готовый.
  2. (опционально) монтирует/распаковывает содержимое через debugfs во временную папку.
  3. Применяет действия:
       --remove <путь-в-системе>      удалить файл (например, тяжёлый Navitel)
       --add-apk <файл.apk>[:имя]     добавить APK в /system/app (или /priv-app через /)
       --add-file <локальный>:<путь>  добавить произвольный файл
       --set-prop k=v                изменить/добавить свойство в /system/build.prop
  4. Пересобирает ext4-образ через make_ext4fs и (опционально) обрезает до нужного
     размера (по умолчанию 512 МиБ — как раздел p3).
  5. Считает sha256 и пишет отчёт.

Требуется: e2fsprogs с make_ext4fs и debugfs (в Ubuntu: apt install e2fsprogs
+e2fsprogs-extra), либо mke2fs + debugfs (fallback, всегда есть).

Примеры:

  # Просто пересобрать образ после удаления тяжёлого Navitel и замены шрифтов
  python3 tools/build_system.py --fw архив.rar --out out/system.img \
      --remove /priv-app/Navitel-9.13.73-large.apk \
      --set-prop ro.product.locale.language=ru

  # Добавить свои APK (Torque и обновлённый Navitel ставим уже после прошивки,
  # но можно и сразу вшить)
  python3 tools/build_system.py --system system.img --out out/system.img \
      --add-apk TorquePro.apk:/app \
      --add-apk Navitel-11.11.1128.apk:/app
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile


def run(cmd, check=True, quiet=False):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if not quiet:
        print(f'$ {" ".join(cmd)}')
    if p.returncode != 0 and check:
        sys.stderr.write((p.stdout or '') + (p.stderr or ''))
        raise SystemExit(f'команда завершилась с кодом {p.returncode}: {cmd[0]}')
    return p


def extract_system_img_from_rar(rar, workdir):
    """Распаковывает system.img из RAR (7z/unrar)."""
    outdir = os.path.join(workdir, 'rar')
    os.makedirs(outdir, exist_ok=True)
    if shutil.which('7z'):
        run(['7z', 'x', '-y', '-aos', f'-o{outdir}', rar], quiet=True)
    elif shutil.which('unrar'):
        run(['unrar', 'x', '-o+', rar, outdir + '/'], quiet=True)
    else:
        raise SystemExit('нужен 7z или unrar')
    for root, _, files in os.walk(outdir):
        for fn in files:
            if fn.lower() == 'system.img':
                return os.path.join(root, fn)
    raise SystemExit('system.img не найден в архиве')


def dump_tree(img, dst):
    """Распаковывает всё содержимое ext4-образа через debugfs rdump."""
    os.makedirs(dst, exist_ok=True)
    p = run(['debugfs', '-R', f'rdump / "{dst}"', img], check=False)
    # rdump ругается на chown в непривилегированном режиме — это нормально
    if not os.listdir(dst):
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit('debugfs не смог распаковать образ')


def apply_actions(root, actions):
    log = []
    for act in actions:
        kind = act[0]
        if kind == 'remove':
            target = os.path.join(root, act[1].lstrip('/'))
            if os.path.exists(target):
                shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)
                log.append(f'удалено: {act[1]}')
            else:
                log.append(f'НЕ НАЙДЕНО (пропуск): {act[1]}')
        elif kind == 'add-apk':
            src, dest_dir = act[1], act[2]
            d = os.path.join(root, dest_dir.strip('/'))
            os.makedirs(d, exist_ok=True)
            name = os.path.basename(src)
            shutil.copy2(src, os.path.join(d, name))
            os.chmod(os.path.join(d, name), 0o644)
            log.append(f'добавлено APK: {dest_dir}/{name} ({os.path.getsize(src)} байт)')
        elif kind == 'add-file':
            src, dest = act[1], act[2]
            target = os.path.join(root, dest.lstrip('/'))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(src, target)
            log.append(f'добавлен файл: {dest}')
        elif kind == 'set-prop':
            key, val = act[1], act[2]
            bp = os.path.join(root, 'build.prop')
            lines = []
            if os.path.exists(bp):
                with open(bp, 'r', errors='replace') as f:
                    lines = f.read().splitlines()
            done = False
            for i, ln in enumerate(lines):
                if ln.strip().startswith(key + '='):
                    lines[i] = f'{key}={val}'
                    done = True
            if not done:
                lines.append(f'{key}={val}')
            with open(bp, 'w') as f:
                f.write('\n'.join(lines) + '\n')
            log.append(f'свойство: {key}={val}')
    return log


def build_image(root, out_img, size_mb=512):
    """Собирает ext4-образ. Сначала пробует make_ext4fs, иначе mke2fs -d."""
    root = os.path.abspath(root)
    need = 0
    for r, d, fs in os.walk(root):
        for fn in fs:
            p = os.path.join(r, fn)
            try:
                need += os.path.getsize(p)
            except OSError:
                pass
    need_mb = int(need / 1024 / 1024 * 1.25) + 64
    size_mb = max(size_mb, need_mb)
    print(f'содержимое: {need/1024/1024:.0f} МиБ -> образ {size_mb} МиБ')

    if os.path.exists(out_img):
        os.remove(out_img)

    if shutil.which('make_ext4fs'):
        run(['make_ext4fs', '-l', f'{size_mb}M', '-a', 'system', '-S',
             os.path.join(root, 'file_contexts'), out_img, root], check=False)
        if os.path.exists(out_img) and os.path.getsize(out_img) > 0:
            return out_img
        # повтор без selinux-файла
        run(['make_ext4fs', '-l', f'{size_mb}M', '-a', 'system', out_img, root], check=False)
        if os.path.exists(out_img) and os.path.getsize(out_img) > 0:
            return out_img

    # fallback: mke2fs -d (e2fsprogs >= 1.43)
    tmp = out_img + '.tmp'
    if os.path.exists(tmp):
        os.remove(tmp)
    with open(tmp, 'wb') as f:
        f.truncate(size_mb * 1024 * 1024)
    p = run(['mke2fs', '-q', '-F', '-t', 'ext4', '-L', 'system', '-d', root, tmp],
            check=False)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit('не удалось собрать ext4 (нужен make_ext4fs или mke2fs -d)')
    os.replace(tmp, out_img)
    return out_img


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--fw', help='архив прошивки (rar/zip) — извлечь system.img')
    ap.add_argument('--system', help='готовый system.img')
    ap.add_argument('--out', default='out/system.img', help='куда сохранить результат')
    ap.add_argument('--size-mb', type=int, default=512,
                    help='размер образа (по умолчанию 512 МиБ = раздел p3)')
    ap.add_argument('--remove', action='append', default=[],
                    help='удалить путь из системы (можно много раз)')
    ap.add_argument('--add-apk', action='append', default=[], metavar='APK[:/dir]',
                    help='добавить APK в /app (по умолчанию) или указанный каталог')
    ap.add_argument('--add-file', action='append', default=[], metavar='ЛОКАЛ:ПУТЬ',
                    help='добавить произвольный файл')
    ap.add_argument('--set-prop', action='append', default=[], metavar='k=v',
                    help='изменить свойство в build.prop')
    ap.add_argument('--keep-work', action='store_true', help='не удалять временную папку')
    args = ap.parse_args()

    if not args.fw and not args.system:
        ap.error('нужен --fw или --system')

    work = tempfile.mkdtemp(prefix='lifan_build_')
    print(f'временная папка: {work}')
    try:
        img = args.system or extract_system_img_from_rar(args.fw, work)
        print(f'system.img: {img} ({os.path.getsize(img)} байт, sha256 {sha256(img)[:16]}…)')

        root = os.path.join(work, 'root')
        print('распаковка образа через debugfs...')
        dump_tree(img, root)
        n = sum(len(f) for _, _, f in os.walk(root))
        print(f'распаковано файлов: {n}')

        actions = []
        for p in args.remove:
            actions.append(('remove', p))
        for a in args.add_apk:
            if ':' in a:
                src, dest = a.rsplit(':', 1)
            else:
                src, dest = a, '/app'
            actions.append(('add-apk', src, dest))
        for a in args.add_file:
            src, dest = a.split(':', 1)
            actions.append(('add-file', src, dest))
        for a in args.set_prop:
            k, v = a.split('=', 1)
            actions.append(('set-prop', k, v))

        print('\n--- применение изменений ---')
        for line in apply_actions(root, actions):
            print('  ' + line)

        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or '.', exist_ok=True)
        print('\n--- сборка образа ---')
        out = build_image(root, os.path.abspath(args.out), args.size_mb)
        size = os.path.getsize(out)
        print(f'\nГОТОВО: {out}')
        print(f'  размер: {size} байт ({size/1024/1024:.1f} МиБ)')
        print(f'  sha256: {sha256(out)}')
        print('\nДальше: положить как system.img рядом с boot.img/sd_boot.img на SD-карту')
        print('и прошить штатным способом (см. docs/06-инструкция-модернизации.md)')
    finally:
        if args.keep_work:
            print(f'рабочая папка сохранена: {work}')
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()

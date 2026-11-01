#!/usr/bin/env python3
"""
Сборка модифицированного system.img для ГУ Elead EL-830C-LF01 (Lifan X60 FL).

Стратегия A: остаёмся на штатном Android 4.4.2 и сохраняем ВЕСЬ заводской
функционал (камера заднего вида, радио, Bluetooth, климат, кнопки руля).
Меняем только содержимое /system.

Что делает:
  1. Берёт system.img из архива прошивки (RAR/ZIP) либо готовый файл.
  2. Распаковывает его через debugfs во временный каталог.
  3. Применяет правки: --remove, --add-apk, --add-file, --set-prop.
  4. Выставляет права и владельца root:root как в Android.
  5. Собирает ext4 ровно на 512 МиБ (размер раздела p3) с фичами,
     совместимыми с ядром 3.0.35 (без 64bit / metadata_csum!).
  6. Проверяет результат и печатает sha256.

Требуется: mke2fs (e2fsprogs), debugfs, 7z или unrar.

Примеры:

  python3 tools/build_system.py --fw firmware.rar --out out/system.img \\
      --remove /priv-app/Navitel-9.13.73-large.apk \\
      --set-prop ro.product.locale.language=ru --set-prop ro.product.locale.region=RU

  python3 tools/build_system.py --system system.img --out out/system.img \\
      --add-apk TorquePro.apk:/app --add-apk Navitel-11.11.1128.apk:/app
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

# заполняется в main(): ['sudo', '-n'] — чтобы chown/сборка работали от root
SUDO = []

# Фичи ext4, совместимые с ядром 3.0.35 (i.MX6, Android 4.4).
# 64bit и metadata_csum появились позже — с ними ядро раздел НЕ смонтирует!
FEATURE_VARIANTS = [
    '^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file,^quota,^casefold,^bigalloc',
    '^64bit,^metadata_csum,^orphan_file,^quota,^casefold',
    '^64bit,^metadata_csum',
    '^64bit',
    None,          # по умолчанию
]


def _sudo(cmd):
    return SUDO + list(cmd) if SUDO else list(cmd)


def run(cmd, check=True, quiet=True):
    if not quiet:
        print(f'$ {" ".join(cmd)}')
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        raise SystemExit(f'команда не найдена: {cmd[0]}')
    if p.returncode != 0 and check:
        sys.stderr.write((p.stdout or '') + (p.stderr or ''))
        raise SystemExit(f'ошибка выполнения: {cmd[0]} (код {p.returncode})')
    return p


# --------------------------------------------------------------------------
# 1. Достать system.img
# --------------------------------------------------------------------------
def extract_system_img(rar, workdir):
    if not os.path.exists(rar):
        raise SystemExit(f'файл прошивки не найден: {rar}')
    print(f'архив: {rar} ({os.path.getsize(rar)} байт)')
    outdir = os.path.join(workdir, 'rar')
    os.makedirs(outdir, exist_ok=True)

    attempts = [
        (['7z', 'x', '-y', '-aos', f'-o{outdir}', rar], '7z'),
        (['7zz', 'x', '-y', f'-o{outdir}', rar], '7zz'),
        (['unrar', 'x', '-o+', rar, outdir + '/'], 'unrar'),
        (['unrar-free', '-x', rar, outdir], 'unrar-free'),
        (['bsdtar', '-xf', rar, '-C', outdir], 'bsdtar'),
    ]
    errors = []
    for cmd, name in attempts:
        if not shutil.which(cmd[0]):
            errors.append(f'{name}: не установлен')
            continue
        r = subprocess.run(cmd, capture_output=True, text=True)
        found = None
        for root, _, files in os.walk(outdir):
            for fn in files:
                if fn.lower() == 'system.img':
                    found = os.path.join(root, fn)
                    break
            if found:
                break
        if found:
            print(f'распаковано через {name}')
            return found
        errors.append(f'{name}: код {r.returncode} '
                      f'{((r.stderr or r.stdout) or "").strip()[:160]}')

    alt = os.path.join(os.path.dirname(os.path.abspath(rar)), 'system.img')
    if os.path.exists(alt):
        print(f'использую готовый {alt}')
        return alt
    raise SystemExit('system.img не найден. Попытки:\n  ' + '\n  '.join(errors))


# --------------------------------------------------------------------------
# 2. Распаковать образ
# --------------------------------------------------------------------------
def dump_tree(img, dst):
    os.makedirs(dst, exist_ok=True)
    if not os.path.exists(img):
        raise SystemExit(f'образ не найден: {img}')
    print(f'debugfs rdump: {img} ({os.path.getsize(img)} байт)')
    run(['debugfs', '-R', f'rdump / "{dst}"', img], check=False)
    lf = os.path.join(dst, 'lost+found')
    if os.path.isdir(lf):
        shutil.rmtree(lf, ignore_errors=True)
    n = sum(len(f) for _, _, f in os.walk(dst))
    print(f'распаковано файлов: {n}')
    if n == 0:
        raise SystemExit('debugfs не смог распаковать образ')


def content_stats(root):
    total = 0
    seen = set()
    biggest = []
    for r, _, fs in os.walk(root):
        for fn in fs:
            p = os.path.join(r, fn)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            key = (st.st_dev, st.st_ino)
            if key in seen:
                continue
            seen.add(key)
            total += st.st_size
            biggest.append((st.st_size, os.path.relpath(p, root)))
    biggest.sort(reverse=True)
    return total, biggest[:10]


# --------------------------------------------------------------------------
# 3. Правки
# --------------------------------------------------------------------------
def apply_actions(root, actions):
    log = []
    for act in actions:
        kind = act[0]
        if kind == 'remove':
            target = os.path.join(root, act[1].lstrip('/'))
            if os.path.exists(target):
                if os.path.isdir(target):
                    shutil.rmtree(target)
                else:
                    os.remove(target)
                log.append(f'удалено: {act[1]}')
            else:
                log.append(f'НЕ НАЙДЕНО (пропуск): {act[1]}')

        elif kind == 'add-apk':
            src, dest_dir = act[1], act[2]
            if not os.path.exists(src):
                log.append(f'НЕТ ФАЙЛА: {src}')
                continue
            d = os.path.join(root, dest_dir.strip('/'))
            os.makedirs(d, exist_ok=True)
            name = os.path.basename(src)
            dst = os.path.join(d, name)
            shutil.copyfile(src, dst)
            os.chmod(dst, 0o644)
            log.append(f'добавлено APK: {dest_dir}/{name} ({os.path.getsize(src)} байт)')

        elif kind == 'add-file':
            src, dest = act[1], act[2]
            target = os.path.join(root, dest.lstrip('/'))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(src, target)
            log.append(f'добавлен файл: {dest}')

        elif kind == 'set-prop':
            key, val = act[1], act[2]
            bp = os.path.join(root, 'build.prop')
            lines = []
            if os.path.exists(bp):
                with open(bp, 'r', errors='replace') as f:
                    lines = f.read().splitlines()
            replaced = False
            for i, ln in enumerate(lines):
                if ln.strip().startswith(key + '='):
                    lines[i] = f'{key}={val}'
                    replaced = True
            if not replaced:
                lines.append(f'{key}={val}')
            with open(bp, 'w') as f:
                f.write('\n'.join(lines) + '\n')
            log.append(f'свойство: {key}={val} '
                       f'({"заменено" if replaced else "добавлено"})')
    return log


# --------------------------------------------------------------------------
# 4. Права и владельцы
# --------------------------------------------------------------------------
def fix_ownership(root):
    """root:root + права как в Android. Без прав — просто корректные mode."""
    owner_ok = False
    if os.geteuid() == 0:
        subprocess.run(['chown', '-R', '0:0', root], capture_output=True)
        owner_ok = True
    elif SUDO:
        p = subprocess.run(SUDO + ['chown', '-R', '0:0', root],
                           capture_output=True, text=True)
        owner_ok = p.returncode == 0

    if owner_ok and os.geteuid() != 0 and SUDO:
        # файлы теперь принадлежат root — меняем права тоже через sudo
        subprocess.run(SUDO + ['find', root, '-type', 'd', '-exec', 'chmod', '755', '{}', '+'],
                       capture_output=True)
        subprocess.run(SUDO + ['find', root, '-type', 'f', '!', '-name', 'su',
                               '-exec', 'chmod', '644', '{}', '+'], capture_output=True)
        subprocess.run(SUDO + ['find', root, '-type', 'f', '-perm', '-111',
                               '!', '-name', 'su', '-exec', 'chmod', '755', '{}', '+'],
                       capture_output=True)
        subprocess.run(SUDO + ['find', root, '-type', 'f', '-name', 'su',
                               '-exec', 'chmod', '6755', '{}', '+'], capture_output=True)
        n = sum(len(f) for _, _, f in os.walk(root))
        print(f'права выставлены через sudo: файлов {n}; владелец root:root')
        return owner_ok

    files = dirs = 0
    for r, ds, fs in os.walk(root):
        for d in ds:
            try:
                os.chmod(os.path.join(r, d), 0o755)
                dirs += 1
            except OSError:
                pass
        for fn in fs:
            fp = os.path.join(r, fn)
            if os.path.islink(fp):
                continue
            try:
                mode = 0o755 if (os.stat(fp).st_mode & 0o111) else 0o644
                if fn == 'su':
                    mode = 0o6755
                os.chmod(fp, mode)
                files += 1
            except OSError:
                pass
    print(f'права: файлов {files}, каталогов {dirs}; '
          f'владелец {"root:root" if owner_ok else "не изменён (нет прав — допустимо)"}')
    # после chown на root сам пользователь может потерять доступ — вернём чтение
    subprocess.run(_sudo(['chmod', '-R', 'a+rX', root]), capture_output=True)
    return owner_ok


# --------------------------------------------------------------------------
# 5. Сборка образа
# --------------------------------------------------------------------------
def build_image(root, out_img, size_mb=512):
    total, biggest = content_stats(root)
    print(f'содержимое: {total / 1024 / 1024:.1f} МиБ '
          f'(раздел p3 = {size_mb} МиБ)')
    print('  крупнейшие файлы:')
    for sz, rel in biggest:
        print(f'    {sz / 1024 / 1024:8.1f} МиБ  /{rel}')

    limit = size_mb * 1024 * 1024
    if total + 20 * 1024 * 1024 > limit:
        raise SystemExit(
            f'ОШИБКА: содержимое не влезает в {size_mb} МиБ '
            f'({total / 1024 / 1024:.0f} МиБ + служебные). Удали лишнее через --remove.')

    os.makedirs(os.path.dirname(os.path.abspath(out_img)) or '.', exist_ok=True)
    if os.path.exists(out_img):
        os.remove(out_img)
    tmp = out_img + '.tmp'

    last = ''
    for feats in FEATURE_VARIANTS:
        if os.path.exists(tmp):
            os.remove(tmp)
        with open(tmp, 'wb') as f:
            f.truncate(size_mb * 1024 * 1024)
        cmd = ['mke2fs', '-q', '-F', '-t', 'ext4', '-b', '4096', '-I', '256',
               '-L', 'system', '-E', 'nodiscard']
        if feats:
            cmd += ['-O', feats]
        cmd += ['-d', root, tmp]
        p = subprocess.run(_sudo(cmd), capture_output=True, text=True)
        if p.returncode == 0:
            print(f'собрано (фичи: {feats or "по умолчанию"})')
            os.replace(tmp, out_img)
            break
        last = (p.stdout or '') + (p.stderr or '')
        print(f'  вариант "{feats}" не подошёл, пробую следующий')
    else:
        print('--- последняя ошибка mke2fs ---')
        print(last[-2000:])
        if os.path.exists(tmp):
            os.remove(tmp)
        raise SystemExit('не удалось собрать ext4')

    try:
        os.chmod(out_img, 0o644)
    except OSError:
        pass

    h = subprocess.run(_sudo(['dumpe2fs', '-h', out_img]),
                       capture_output=True, text=True).stdout
    print('--- параметры ФС ---')
    for ln in h.splitlines():
        if ln.startswith(('Filesystem features', 'Block size', 'Inode size',
                          'Filesystem volume name', 'Block count')):
            print('  ' + ln.strip())
    if '64bit' in h or 'metadata_csum' in h:
        raise SystemExit('ОШИБКА: в ФС остались фичи, несовместимые с ядром 3.0.35')
    return out_img


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--fw', help='архив прошивки (rar/zip) — взять system.img оттуда')
    ap.add_argument('--system', help='готовый system.img')
    ap.add_argument('--out', default='out/system.img', help='результат')
    ap.add_argument('--size-mb', type=int, default=512,
                    help='размер образа в МиБ (раздел p3 = 512)')
    ap.add_argument('--remove', action='append', default=[], metavar='ПУТЬ',
                    help='удалить путь из системы (можно несколько раз)')
    ap.add_argument('--add-apk', action='append', default=[], metavar='APK[:/каталог]',
                    help='добавить APK (по умолчанию в /app)')
    ap.add_argument('--add-file', action='append', default=[], metavar='ЛОКАЛ:ПУТЬ',
                    help='добавить произвольный файл')
    ap.add_argument('--set-prop', action='append', default=[], metavar='k=v',
                    help='изменить свойство в build.prop')
    ap.add_argument('--keep-work', action='store_true', help='не удалять временную папку')
    args = ap.parse_args()

    if not args.fw and not args.system:
        ap.error('нужен --fw или --system')

    global SUDO
    if os.geteuid() != 0 and shutil.which('sudo'):
        if subprocess.run(['sudo', '-n', 'true'], capture_output=True).returncode == 0:
            SUDO = ['sudo', '-n']
            print('использую sudo для chown и сборки образа')

    work = tempfile.mkdtemp(prefix='lifan_build_')
    print(f'временная папка: {work}')
    try:
        img = args.system or extract_system_img(args.fw, work)
        print(f'system.img: {img} ({os.path.getsize(img)} байт)')
        print(f'  sha256 исходного: {sha256(img)[:32]}…')

        root = os.path.join(work, 'root')
        dump_tree(img, root)

        actions = [('remove', p) for p in args.remove]
        for a in args.add_apk:
            src, dest = (a.rsplit(':', 1) if ':' in a else (a, '/app'))
            actions.append(('add-apk', src, dest))
        for a in args.add_file:
            src, dest = a.split(':', 1)
            actions.append(('add-file', src, dest))
        for a in args.set_prop:
            k, v = a.split('=', 1)
            actions.append(('set-prop', k, v))

        print('\n--- изменения ---')
        for line in apply_actions(root, actions):
            print('  ' + line)

        print('\n--- права ---')
        fix_ownership(root)

        print('\n--- сборка ---')
        out = build_image(root, os.path.abspath(args.out), args.size_mb)
        size = os.path.getsize(out)
        print(f'\nГОТОВО: {out}')
        print(f'  размер: {size} байт ({size / 1024 / 1024:.1f} МиБ)')
        print(f'  sha256: {sha256(out)}')
        print('\nДальше: положить как system.img на SD рядом с boot.img, u-boot.bin,')
        print('MCU_FW.hex и sd_boot.img (штатными!) и прошить штатным способом.')
        print('Подробно: docs/06-инструкция-модернизации.md')
    finally:
        if args.keep_work:
            print(f'рабочая папка сохранена: {work}')
        else:
            subprocess.run(_sudo(['rm', '-rf', work]), capture_output=True)
            shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()

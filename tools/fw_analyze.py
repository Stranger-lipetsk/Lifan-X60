#!/usr/bin/env python3
"""
Глубокий разбор прошивки ГУ Lifan X60 FL.

Что делает:
  * определяет формат образов (Android sparse / ext4 / boot image / uImage / U-Boot)
  * распаковывает boot.img: ядро, ramdisk, dtb; вытаскивает версию ядра
  * разбирает ramdisk (cpio): init.rc, init.*.rc, fstab, *.prop
  * монтирует system.img через debugfs и собирает: build.prop, список файлов,
    список APK, версии фреймворка, наличие root/gapps
  * анализирует u-boot.bin и MCU_FW.hex на маркеры платформы
  * пишет текстовые отчёты в указанную папку

Использование:
  python3 tools/fw_analyze.py <папка_с_образами> <папка_отчётов>
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
import gzip
import lzma
import bz2

SPARSE_MAGIC = 0xED26FF3A
ANDROID_MAGIC = b'ANDROID!'
UIMAGE_MAGIC = 0x27051956


def run(cmd, timeout=900, check=False):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           errors='replace')
        if check and p.returncode != 0:
            return p.returncode, (p.stdout or '') + (p.stderr or '')
        return p.returncode, (p.stdout or '') + (p.stderr or '')
    except FileNotFoundError:
        return 127, f'НЕТ КОМАНДЫ: {cmd[0]}'
    except subprocess.TimeoutExpired:
        return 124, f'ТАЙМАУТ: {cmd[:2]}'


def up4(n, page):
    return ((n + page - 1) // page) * page


# ----------------------------------------------------------------------------
# Android sparse image -> raw
# ----------------------------------------------------------------------------
def sparse_to_raw(src, dst):
    with open(src, 'rb') as f:
        hdr = f.read(28)
        magic, major, minor, fhsz, chsz, blksz, total_blks, total_chunks, crc = \
            struct.unpack('<IHHHHIIII', hdr)
        assert magic == SPARSE_MAGIC, 'не sparse image'
        with open(dst, 'wb') as out:
            written = 0
            for _ in range(total_chunks):
                ch = f.read(12)
                ctype, _, csize, total = struct.unpack('<HHII', ch)
                if ctype == 0xCAC1:          # raw
                    out.write(f.read(csize * blksz))
                elif ctype == 0xCAC2:        # fill
                    val = f.read(4)
                    out.write(val * (csize * blksz // 4))
                elif ctype == 0xCAC3:        # don't care
                    out.write(b'\x00' * (csize * blksz))
                elif ctype == 0xCAC4:        # crc32
                    f.read(4)
                else:
                    raise ValueError(f'неизвестный chunk type {ctype:#x}')
                written += 1
    return written


# ----------------------------------------------------------------------------
# Android boot image (v0/v1/v2)
# ----------------------------------------------------------------------------
def parse_boot_image(path, out_dir, log):
    with open(path, 'rb') as f:
        data = f.read(4096)
        if not data.startswith(ANDROID_MAGIC):
            log(f'  ! это не ANDROID! boot image, первые байты: {data[:16].hex()}')
            return None
        (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size,
         second_addr, tags_addr, page_size) = struct.unpack('<IIIIIIII', data[8:40])
        header_version = struct.unpack('<I', data[40:44])[0]
        os_version = struct.unpack('<I', data[44:48])[0]
        name = data[48:64].split(b'\x00')[0].decode('utf-8', 'replace')
        cmdline = data[64:576].split(b'\x00')[0].decode('utf-8', 'replace')
        os_ver = f'{(os_version >> 25) & 0x7f}.{(os_version >> 18) & 0x7f}.{(os_version >> 11) & 0x7f}'
        log(f'  page_size={page_size} kernel={kernel_size} ramdisk={ramdisk_size} '
            f'second={second_size} header_ver={header_version} os={os_ver} name="{name}"')

        f.seek(0)
        full = f.read()

    def cut(off, size):
        return full[off:off + size]

    base = page_size
    kernel = cut(base, kernel_size)
    rd_off = base + up4(kernel_size, page_size)
    ramdisk = cut(rd_off, ramdisk_size)
    sec_off = rd_off + up4(ramdisk_size, page_size)
    second = cut(sec_off, second_size)

    open(os.path.join(out_dir, 'kernel'), 'wb').write(kernel)
    open(os.path.join(out_dir, 'ramdisk.cpio.gz'), 'wb').write(ramdisk)
    if second_size:
        open(os.path.join(out_dir, 'second.img'), 'wb').write(second)

    info = {'page_size': page_size, 'kernel_size': kernel_size,
            'ramdisk_size': ramdisk_size, 'cmdline': cmdline, 'name': name,
            'os_version': os_ver, 'header_version': header_version}

    # версия ядра из бинарника
    m = re.search(rb'Linux version ([0-9][^\x00\n]{0,180})', kernel)
    if m:
        info['kernel_version'] = m.group(1).decode('utf-8', 'replace')
        log(f'  ВЕРСИЯ ЯДРА: {info["kernel_version"]}')
    m2 = re.search(rb'gcc version ([^\x00\n]{0,80})', kernel)
    if m2:
        info['gcc'] = m2.group(1).decode('utf-8', 'replace')

    # маркеры платформы в ядре
    marks = set()
    for pat in (rb'(sun[0-9]i[a-z0-9_]{0,8})', rb'(rk3[0-9][a-z0-9_]{0,6})',
                rb'(mt[0-9]{4}[a-z]?)', rb'(px[3-6])', rb'(\btegra\w*)',
                rb'(imx[0-9][a-z0-9]{0,6})', rb'(s5p\w*|exynos\w*)',
                rb'(meson\w*)', rb'(msm[0-9]{4})', rb'(atom[a-z0-9]*)'):
        for mm in re.finditer(pat, kernel, re.I):
            try:
                s = mm.group(1).decode('ascii', 'replace')
            except Exception:
                continue
            if len(s) > 3:
                marks.add(s.lower())
    info['soc_marks'] = sorted(marks)[:120]

    # dtb в конце ядра / second
    for nm, blob in (('kernel', kernel), ('second', second)):
        if b'\xd0\x0d\xfe\xed' in blob:
            idx = blob.find(b'\xd0\x0d\xfe\xed')
            open(os.path.join(out_dir, f'{nm}.dtb'), 'wb').write(blob[idx:])
            log(f'  найден DTB внутри {nm} @ {idx}')
            break

    return info


def decompress_ramdisk(src, out_cpio, log):
    with open(src, 'rb') as f:
        blob = f.read()
    if not blob:
        return False
    magic = blob[:6]
    try:
        if magic[:2] == b'\x1f\x8b':
            data = gzip.decompress(blob)
        elif blob[:6] == b'\xfd7zXZ\x00':
            data = lzma.decompress(blob)
        elif magic[:3] == b'BZh':
            data = bz2.decompress(blob)
        elif blob[:4] == b'\x04\x22\x4d\x18':
            data = lz4_decompress_file(src, log)
            if data is None:
                return False
        elif blob[:5] == b'\x5d\x00\x00':
            data = lzma.decompress(blob, format=lzma.FORMAT_ALONE)
        else:
            data = blob   # уже cpio
        open(out_cpio, 'wb').write(data)
        log(f'  ramdisk распакован: {len(blob)} -> {len(data)} байт')
        return True
    except Exception as e:
        log(f'  ! ошибка распаковки ramdisk: {e}')
        return False


def lz4_decompress_file(src, log):
    rc, out = run(['lz4', '-d', '-f', src, src + '.raw'])
    if rc != 0:
        log(f'  ! lz4 недоступен: {out[:200]}')
        return None
    return open(src + '.raw', 'rb').read()


def parse_cpio(path, out_dir, log):
    """Распаковка newc cpio (в т.ч. с несколькими сегментами)."""
    names = []
    files = {}
    with open(path, 'rb') as f:
        proc = data = None
        while True:
            hdr = f.read(110)
            if len(hdr) < 110 or not hdr.startswith(b'070701'):
                break
            try:
                flds = [int(hdr[6 + i * 8: 14 + i * 8], 16) for i in range(13)]
            except ValueError:
                break
            (ino, mode, uid, gid, nlink, mtime, fsize,
             dmaj, dmin, rmaj, rmin, namesize, chksum) = flds
            name = f.read(namesize - 1).decode('utf-8', 'replace')
            f.read(1)
            pad = (-(110 + namesize)) % 4
            f.read(pad)
            if name == 'TRAILER!!!':
                break
            body = f.read(fsize)
            f.read((-fsize) % 4)
            names.append((mode, fsize, name))
            files[name] = (mode, body)
    log(f'  в ramdisk {len(names)} записей')
    os.makedirs(out_dir, exist_ok=True)
    for mode, body in files.values():
        pass
    for name, (mode, body) in files.items():
        # сохраняем только текстовые/конфигурационные файлы
        base = os.path.basename(name)
        if base.endswith(('.rc', '.prop', '.sh')) or base in (
                'fstab', 'init', 'ueventd.rc', 'default.prop') or 'fstab' in base:
            dest = os.path.join(out_dir, name.lstrip('/').replace('/', '_'))
            try:
                with open(dest, 'wb') as f:
                    f.write(body)
            except OSError:
                pass
    return names, files


# ----------------------------------------------------------------------------
# ext4 / system.img
# ----------------------------------------------------------------------------
def analyze_system(img, work, reports, log):
    raw = img
    with open(img, 'rb') as f:
        magic = struct.unpack('<I', f.read(4))[0]
    if magic == SPARSE_MAGIC:
        log('  system.img = Android sparse image -> конвертирую в raw')
        raw = os.path.join(work, 'system.raw.img')
        sparse_to_raw(img, raw)
        log(f'  raw размер: {os.path.getsize(raw)} байт')

    rc, out = run(['file', raw])
    log(f'  file: {out.strip()}')

    # листинг через debugfs
    listing = ''
    rc, out = run(['debugfs', '-R', 'ls -l /', raw], timeout=300)
    log(f'  debugfs rc={rc}')
    listing += f'=== debugfs ls -l / ===\n{out}\n'

    # полный рекурсивный листинг
    rc2, out2 = run(['debugfs', '-R', 'ls -l -p -R /', raw], timeout=1800)
    listing += f'\n=== рекурсивный листинг ===\n{out2}\n'

    # вытаскиваем ключевые файлы
    root_dir = os.path.join(work, 'sysroot')
    os.makedirs(root_dir, exist_ok=True)
    rc3, out3 = run(['debugfs', '-R', f'rdump / "{root_dir}"', raw], timeout=2400)
    log(f'  rdump rc={rc3}: {out3.strip()[:300]}')

    key_files = []
    for root, dirs, files in os.walk(root_dir):
        for fn in files:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, root_dir)
            base = fn.lower()
            if base in ('build.prop', 'default.prop', 'init.rc', 'init.environ.rc',
                        'recovery-resource.dat', 'system.prop') or \
               base.startswith('fstab') or base.endswith('.prop'):
                key_files.append((rel, p))
    log(f'  найдено .prop/rc файлов: {len(key_files)}')

    props_dir = os.path.join(reports, 'props')
    os.makedirs(props_dir, exist_ok=True)
    for rel, p in key_files:
        try:
            if os.path.getsize(p) > 2_000_000:
                continue
            shutil.copy2(p, os.path.join(props_dir, rel.replace('/', '_')))
        except OSError:
            pass

    # карта системы: список всех файлов, размеры
    rows = []
    apks = []
    libs = set()
    for root, dirs, files in os.walk(root_dir):
        for fn in files:
            p = os.path.join(root, fn)
            rel = '/' + os.path.relpath(p, root_dir).replace(os.sep, '/')
            try:
                sz = os.path.getsize(p)
            except OSError:
                sz = -1
            rows.append((sz, rel))
            if fn.endswith('.apk'):
                apks.append((sz, rel))
            if fn.endswith('.so'):
                libs.add(rel)
    rows.sort(reverse=True)

    with open(os.path.join(reports, 'system-файлы.txt'), 'w') as f:
        f.write(f'Всего файлов: {len(rows)}\n\n')
        f.write('=== Крупнейшие 300 ===\n')
        for sz, rel in rows[:300]:
            f.write(f'{sz:>12} {rel}\n')
        f.write('\n=== APK (%d) ===\n' % len(apks))
        for sz, rel in sorted(apks):
            f.write(f'{sz:>12} {rel}\n')
        f.write('\n=== SO (%d) ===\n' % len(libs))
        for rel in sorted(libs):
            f.write(rel + '\n')

    with open(os.path.join(reports, 'system-листинг-debugfs.txt'), 'w') as f:
        f.write(listing[:8_000_000])

    return {'files': len(rows), 'apks': len(apks), 'libs': len(libs),
            'root_dir': root_dir, 'props': [r for r, _ in key_files]}


# ----------------------------------------------------------------------------
# u-boot / MCU
# ----------------------------------------------------------------------------
def analyze_uboot(path, log):
    rc, out = run(['file', path])
    log(f'  file: {out.strip()}')
    with open(path, 'rb') as f:
        blob = f.read(64)
    info = {'head_hex': blob[:32].hex()}
    if len(blob) >= 4:
        info['head_u32'] = hex(struct.unpack('>I', blob[:4])[0])
    rc, s = run(['strings', '-n', '5', path], timeout=120)
    interesting = [ln for ln in s.splitlines() if re.search(
        r'(sun\w*i|rk3\d|board|dram|ddr|uboot|u-boot|spl|nand|emmc|mmc\d|'
        r'lifan|px[3-6]|mt\d{4}|allwinner|rockchip|telechips|mstar|img|logo)',
        ln, re.I)]
    info['strings'] = interesting[:300]
    with open(os.path.join(os.path.dirname(path), 'uboot-strings.txt'), 'w') as f:
        f.write('\n'.join(interesting))
    log(f'  интересных строк: {len(interesting)}')
    return info


def analyze_mcu(path, log):
    with open(path, 'r', errors='replace') as f:
        head = f.read(4000)
    lines = [ln for ln in head.splitlines() if ln.startswith(':')][:20]
    info = {'first_lines': lines, 'size': os.path.getsize(path)}
    # Intel HEX: байт 9-10 в записи = тип
    types = set()
    with open(path, 'r', errors='replace') as f:
        for ln in f:
            if len(ln) > 11 and ln.startswith(':'):
                types.add(ln[7:9])
    info['record_types'] = sorted(types)
    log(f'  Intel HEX, типы записей: {sorted(types)}')
    return info


# ----------------------------------------------------------------------------
def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src_dir = sys.argv[1]
    rep_dir = sys.argv[2]
    os.makedirs(rep_dir, exist_ok=True)
    log_lines = []

    def log(msg):
        print(msg, flush=True)
        log_lines.append(msg)

    work = tempfile.mkdtemp(prefix='fw_')
    log(f'Рабочая папка: {work}')
    log(f'Исходники: {src_dir}')

    # ищем образы во всех подпапках (в архиве могла быть вложенная папка)
    images = {}
    for root, dirs, files in os.walk(src_dir):
        for fn in files:
            if fn.lower().endswith(('.img', '.bin', '.hex')):
                p = os.path.join(root, fn)
                images.setdefault(fn.lower(), []).append(p)

    log('\n=== Найденные образы ===')
    for k, v in sorted(images.items()):
        for p in v:
            log(f'  {p}  {os.path.getsize(p)} байт')
    if not images:
        log('!! образы не найдены — распаковка архива не удалась?')
        return

    summary = {}

    # ---- boot.img ----
    boots = [p for k, v in images.items() if k == 'boot.img' for p in v]
    boot_dir = os.path.join(work, 'boot')
    os.makedirs(boot_dir, exist_ok=True)
    if boots:
        log('\n=== boot.img ===')
        info = parse_boot_image(boots[0], boot_dir, log)
        if info:
            summary['boot'] = info
            rd = os.path.join(boot_dir, 'ramdisk.cpio.gz')
            cpio = os.path.join(boot_dir, 'ramdisk.cpio')
            if os.path.exists(rd) and decompress_ramdisk(rd, cpio, log):
                names, files = parse_cpio(cpio, os.path.join(rep_dir, 'ramdisk'), log)
                with open(os.path.join(rep_dir, 'ramdisk-список.txt'), 'w') as f:
                    for mode, size, name in names:
                        f.write(f'{size:>10} {mode:06o} {name}\n')
                summary['ramdisk_files'] = len(names)

    # ---- sd_boot.img ----
    sds = [p for k, v in images.items() if k == 'sd_boot.img' for p in v]
    if sds:
        log('\n=== sd_boot.img ===')
        with open(sds[0], 'rb') as f:
            head = f.read(1024)
        log(f'  первые байты: {head[:32].hex()}')
        rc, out = run(['file', sds[0]])
        log(f'  file: {out.strip()}')
        sd_dir = os.path.join(work, 'sdboot')
        os.makedirs(sd_dir, exist_ok=True)
        if head.startswith(ANDROID_MAGIC):
            parse_boot_image(sds[0], sd_dir, log)
        else:
            # частая картина: u-boot с зашитым ядром/ramdisk -> просто строки
            rc, s = run(['strings', '-n', '6', sds[0]], timeout=300)
            keep = [ln for ln in s.splitlines() if re.search(
                r'(Linux version|android|init\.rc|recovery|board|sun\d+i|rk3\d|px[3-6]|mt\d{4})',
                ln, re.I)]
            with open(os.path.join(rep_dir, 'sd_boot-строки.txt'), 'w') as f:
                f.write('\n'.join(keep[:3000]))
            log(f'  сохранено {len(keep)} строк')
            for ln in keep[:20]:
                log('   ' + ln[:150])

    # ---- u-boot.bin ----
    ubs = [p for k, v in images.items() if k in ('u-boot.bin', 'uboot.bin', 'u-boot.img') for p in v]
    if ubs:
        log('\n=== u-boot.bin ===')
        summary['uboot'] = analyze_uboot(ubs[0], log)
        shutil.copy2(os.path.join(os.path.dirname(ubs[0]), 'uboot-strings.txt'),
                     os.path.join(rep_dir, 'uboot-строки.txt'))

    # ---- MCU_FW.hex ----
    mcus = [p for k, v in images.items() if k.endswith('.hex') for p in v]
    if mcus:
        log('\n=== MCU_FW.hex ===')
        summary['mcu'] = analyze_mcu(mcus[0], log)

    # ---- system.img ----
    sysimgs = [p for k, v in images.items() if k == 'system.img' for p in v]
    if sysimgs:
        log('\n=== system.img ===')
        try:
            summary['system'] = analyze_system(sysimgs[0], work, rep_dir, log)
        except Exception as e:
            log(f'!! ошибка разбора system.img: {e}')

    # ---- ключевые свойства ----
    props_out = os.path.join(rep_dir, 'build-props-сводка.txt')
    with open(props_out, 'w') as f:
        f.write('=== Ключевые свойства Android ===\n')
        keys = ('ro.build.version.release', 'ro.build.version.sdk',
                'ro.build.version.security_patch', 'ro.build.description',
                'ro.build.fingerprint', 'ro.product.board', 'ro.product.device',
                'ro.product.model', 'ro.product.name', 'ro.product.cpu.abi',
                'ro.board.platform', 'ro.hardware', 'ro.kernel.qemu',
                'ro.sf.lcd_density', 'ro.opengles.version', 'ro.zygote',
                'persist.sys.language', 'ro.build.date', 'ro.build.type',
                'ro.secure', 'ro.debuggable', 'ro.adb.secure')
        found = {}
        for root, dirs, files in os.walk(os.path.join(rep_dir, 'props')):
            for fn in files:
                p = os.path.join(root, fn)
                try:
                    txt = open(p, errors='replace').read()
                except OSError:
                    continue
                for ln in txt.splitlines():
                    ln = ln.strip()
                    if '=' in ln and not ln.startswith('#'):
                        k, v = ln.split('=', 1)
                        found.setdefault(k.strip(), []).append((fn, v.strip()))
        for k in keys:
            if k in found:
                f.write(f'{k} = {found[k][0][1]}\n')
        f.write('\n=== ВСЕ найденные свойства (сводно) ===\n')
        for k in sorted(found):
            f.write(f'{k} = {found[k][0][1]}\n')

    # ---- итог ----
    log('\n=== ИТОГ ===')
    with open(os.path.join(rep_dir, 'ИТОГ.txt'), 'w') as f:
        f.write('ИТОГ разбора прошивки\n=====================\n\n')
        for k, v in summary.items():
            f.write(f'{k}: {v}\n\n')
        f.write('\nЛОГ:\n' + '\n'.join(log_lines))
    log('готово')


if __name__ == '__main__':
    main()

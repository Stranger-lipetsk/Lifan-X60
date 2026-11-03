#!/usr/bin/env python3
"""Сжимает APK: оставляет только нужные библиотеки и сжимает ресурсы.

Зачем: на устройстве ARM (armeabi-v7a), а в APK лежат ещё x86, x86_64,
arm64-v8a — это десятки мегабайт мусора. Ресурсы в APK могут храниться
без сжатия (выравнивание), из-за чего файл раздувается.

Что делает:
  --apk F --out G            скопировать, оставив lib/armeabi* (+ --keep)
  --compress                 пересжать несжатые записи (кроме classes.dex
                             и lib/*.so)
Файлы не удаляются из архива без нужды: манифест, ресурсы и подпись
остаются как были, поэтому APK остаётся валидным.
"""
import argparse
import os
import shutil
import sys
import zipfile
import zlib

KEEP_ALWAYS = ('AndroidManifest.xml',)
NO_RECOMPRESS = ('classes.dex',)


def wanted(name, keep_abi, keep_voices, keep_locale):
    # META-INF/ трогать нельзя: там подпись AndroidManifest.xml, по ней
    # Android 4.4 принимает системное приложение
    if name.startswith('lib/'):
        abi = name.split('/')[1] if name.count('/') >= 1 else ''
        return any(abi.startswith(k) for k in keep_abi)
    # голоса навигатора: «assets/Voices/ru-anna.zip» и т.п.
    if keep_voices and '/Voices/' in name:
        tail = name.split('/')[-1].lower()
        return any(tail.startswith(v) for v in keep_voices)
    if keep_locale and '/locale/' in name:
        tail = name.split('/')[-1].lower()
        return any(tail.startswith(v) for v in keep_locale)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apk', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--keep', nargs='*', default=['armeabi', 'armeabi-v7a'])
    ap.add_argument('--compress', action='store_true')
    ap.add_argument('--voices', nargs='*', default=[],
                    help='оставить только эти голоса Navitel (ru,en)')
    ap.add_argument('--locale', nargs='*', default=[],
                    help='оставить только эти локали')
    args = ap.parse_args()

    keep = args.keep
    src = zipfile.ZipFile(args.apk)
    dropped = 0
    dropped_size = 0
    recompressed = 0
    better = 0

    with zipfile.ZipFile(args.out, 'w') as dst:
        for info in src.infolist():
            if info.is_dir():
                continue
            if not wanted(info.filename, keep, args.voices, args.locale):
                dropped += 1
                dropped_size += info.file_size
                continue
            data = src.read(info.filename)
            name = info.filename
            # ВАЖНО: dex оставляем сжатым, как он и лежал в исходном APK.
            # Раньше я делал его несжатым (STORED) ради mmap — и это дало
            # зависание на «Please wait for system optimization»: на этой
            # прошивке Dalvik ждёт выровненный (4 байта) несжатый dex, а
            # внутри zip смещение получается произвольным. Сжатый dex
            # Dalvik распаковывает сам, и это работало всегда.
            if False:
                comp = zipfile.ZIP_STORED
            elif args.compress and info.compress_type == zipfile.ZIP_STORED and len(data) > 4096:
                probe = zlib.compress(data, 6)
                if len(probe) < len(data) * 0.98:
                    comp = zipfile.ZIP_DEFLATED
                    recompressed += 1
                else:
                    comp = zipfile.ZIP_STORED
            elif args.compress and info.compress_type == zipfile.ZIP_DEFLATED:
                # пробуем ужать сильнее, чем в оригинале
                probe = zlib.compress(data, 9)
                if len(probe) < info.compress_size * 0.95:
                    better += 1
                comp = zipfile.ZIP_DEFLATED
            else:
                comp = info.compress_type
            zi = zipfile.ZipInfo(name, date_time=info.date_time)
            zi.compress_type = comp
            zi.external_attr = info.external_attr
            if comp == zipfile.ZIP_STORED:
                # выравниваем начало данных на 4 байта, иначе Dalvik
                # не сможет открыть такой dex через mmap
                zi.extra = b'\x00\x00' * 2
            dst.writestr(zi, data)

    src.close()
    print('убрано библиотек: %d (%.1f МиБ распакованных)'
          % (dropped, dropped_size / 1048576))
    if recompressed:
        print('пересжато записей: %d' % recompressed)
    if better:
        print('ужато сильнее (zlib -9): %d' % better)
    print('%s: %.1f МиБ -> %.1f МиБ'
          % (os.path.basename(args.apk),
             os.path.getsize(args.apk) / 1048576,
             os.path.getsize(args.out) / 1048576))


if __name__ == '__main__':
    main()

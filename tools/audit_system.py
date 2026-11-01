#!/usr/bin/env python3
"""
Аудит system.img перед модификацией: что можно безопасно удалять, а что нельзя.

Проверяет:
  * клавиатуры (InputMethodService) — удаление единственной ломает ввод;
  * наличие русской локали в framework-res.apk;
  * лаунчеры и системные диалоги (удаление ломает загрузку);
  * объём и топ крупных файлов;
  * наличие установщика пакетов и root.

Использование:
  python3 tools/audit_system.py <распакованный_корень_system>
"""
import os
import re
import sys
import zipfile


def apk_blobs(path):
    """Возвращает содержимое классов и манифеста APK (для поиска признаков)."""
    out = b''
    try:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if n in ('AndroidManifest.xml', 'classes.dex') or \
                        re.match(r'classes\d+\.dex$', n):
                    out += z.read(n)
    except Exception:
        pass
    return out


def main(root):
    if not os.path.isdir(root):
        raise SystemExit(f'нет каталога: {root}')

    apks = []
    for sub in ('app', 'priv-app'):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            p = os.path.join(d, fn)
            if os.path.isfile(p) and fn.endswith('.apk'):
                apks.append((sub, fn, p, os.path.getsize(p)))

    print(f'Всего APK: {len(apks)}')

    # ---- клавиатуры ----
    imes = []
    for sub, fn, p, sz in apks:
        blob = apk_blobs(p)
        if b'InputMethodService' in blob or b'inputmethodservice' in blob:
            imes.append((sub, fn, sz))
    print('\n=== КЛАВИАТУРЫ (InputMethodService) ===')
    if imes:
        for sub, fn, sz in imes:
            print(f'  /{sub}/{fn} ({sz} байт)')
    else:
        print('  НЕ НАЙДЕНО — удалять ничего нельзя, иначе не будет ввода!')

    # ---- лаунчеры ----
    launchers = []
    for sub, fn, p, sz in apks:
        blob = apk_blobs(p)
        if b'android.intent.category.HOME' in blob:
            launchers.append((sub, fn, sz))
    print('\n=== ЛАУНЧЕРЫ (HOME) ===')
    for sub, fn, sz in launchers:
        print(f'  /{sub}/{fn} ({sz} байт)')
    if not launchers:
        print('  не найдено (проверьте вручную!)')

    # ---- локали ----
    fr = os.path.join(root, 'framework', 'framework-res.apk')
    print('\n=== ЛОКАЛИ (framework-res.apk) ===')
    if os.path.exists(fr):
        try:
            with zipfile.ZipFile(fr) as z:
                names = z.namelist()
            locales = sorted({m.group(1) for n in names
                              if (m := re.search(r'res/values-([a-z]{2}(?:-r[A-Z]{2})?)/', n))})
            print(f'  найдено локалей: {len(locales)}')
            has_ru = any(l.startswith('ru') for l in locales)
            print(f'  русская локаль: {"ЕСТЬ" if has_ru else "НЕТ!"}')
            if has_ru:
                print('  ru-варианты: ' + ', '.join(l for l in locales if l.startswith('ru')))
            print('  первые 25: ' + ', '.join(locales[:25]))
        except Exception as e:
            print(f'  ошибка чтения: {e}')
    else:
        print('  framework-res.apk не найден')

    # ---- установщик и root ----
    print('\n=== УСТАНОВКА APK И ROOT ===')
    for sub, fn, p, sz in apks:
        if fn.startswith(('PackageInstaller', 'DocumentsUI', 'DownloadProvider')):
            print(f'  /{sub}/{fn} — на месте')
    for cand in ('bin/bin/su', 'xbin/su', 'bin/su'):
        if os.path.exists(os.path.join(root, cand)):
            print(f'  root: /{cand} — есть')

    # ---- объём ----
    total = 0
    biggest = []
    for r, _, fs in os.walk(root):
        for fn in fs:
            p = os.path.join(r, fn)
            try:
                sz = os.path.getsize(p)
            except OSError:
                continue
            total += sz
            biggest.append((sz, os.path.relpath(p, root)))
    biggest.sort(reverse=True)
    print(f'\n=== ОБЪЁМ ===\n  занято: {total / 1024 / 1024:.1f} МиБ')
    print('  топ-12:')
    for sz, rel in biggest[:12]:
        print(f'    {sz / 1024 / 1024:8.1f} МиБ  /{rel}')

    # ---- что можно удалить безопасно ----
    safe = {
        'Navitel-9.13.73-large.apk': 'старый навигатор, заменяем новым',
        'BSEDemo.apk': 'демо-приложение',
        'EL830TAM1_GPIO_TEST_2015.01.01.01.apk': 'инженерный тест GPIO',
        'CubeLiveWallpapers.apk': 'живые обои (бесполезно в авто)',
        'VisualizationWallpapers.apk': 'обои-визуализации',
        'BasicDreams.apk': 'скринсейвер',
        'WfdSink.apk': 'Miracast-приёмник (не используется)',
        'FSLOta.apk': 'OTA от Freescale (не используется)',
        'HTMLViewer.apk': 'просмотрщик HTML',
    }
    print('\n=== РЕКОМЕНДУЕТСЯ УДАЛИТЬ ===')
    saved = 0
    for sub, fn, p, sz in apks:
        if fn in safe and not any(fn in i[1] for i in imes):
            print(f'  /{sub}/{fn} — {safe[fn]} ({sz/1024/1024:.1f} МиБ)')
            saved += sz
        elif fn in safe:
            print(f'  /{sub}/{fn} — ПРОПУСК: это клавиатура!')
    print(f'  экономия: {saved / 1024 / 1024:.1f} МиБ')

    print('\n=== НЕ УДАЛЯТЬ ===')
    print('  IQQIService — единственная клавиатура')
    print('  EL830LF01_Home, ElSettings — оболочка')
    print('  EL831CLF01_* — радио, Bluetooth, камера, плеер')
    print('  SystemUI, Keyguard, SettingsProvider, MediaProvider — системные')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])

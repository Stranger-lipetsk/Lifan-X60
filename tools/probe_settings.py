#!/usr/bin/env python3
"""
Проба лаунчеров и настроек в system.img.

Отвечает на вопросы:
  * какие приложения объявляют себя лаунчером (HOME);
  * какой пакет у ElSettings и что он умеет (какие android.settings.* действия);
  * есть ли штатный Settings.apk (com.android.settings) и DocumentsUI;
  * какие активности обрабатывают WIFI_SETTINGS, SETTINGS, MANAGE_APPLICATIONS и т.п.;
  * что за /priv-app/Launcher2 — каталог или APK.

Использование: python3 tools/probe_settings.py <system.img> [<каталог_отчётов>]
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

INTERESTING_ACTIONS = [
    'android.settings.SETTINGS',
    'android.settings.WIFI_SETTINGS',
    'android.settings.WIRELESS_SETTINGS',
    'android.settings.MANAGE_APPLICATIONS_SETTINGS',
    'android.settings.APPLICATION_SETTINGS',
    'android.settings.DISPLAY_SETTINGS',
    'android.settings.SOUND_SETTINGS',
    'android.settings.LOCATION_SOURCE_SETTINGS',
    'android.settings.BLUETOOTH_SETTINGS',
    'android.settings.DEVICE_INFO_SETTINGS',
    'android.settings.INPUT_METHOD_SETTINGS',
    'android.settings.ACCESSIBILITY_SETTINGS',
    'android.settings.DATE_SETTINGS',
    'android.settings.PRIVACY_SETTINGS',
    'android.settings.SECURITY_SETTINGS',
    'android.settings.APPLICATION_DEVELOPMENT_SETTINGS',
]


def sh(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return (p.stdout or '') + (p.stderr or '')


def dump_file(img, inner, outdir):
    dst = os.path.join(outdir, os.path.basename(inner))
    if os.path.exists(dst):
        return dst
    sh(f'debugfs -R "dump {inner} {dst}" "{img}"')
    return dst if os.path.exists(dst) and os.path.getsize(dst) > 0 else None


def dump_dir_listing(img):
    """Полный листинг /app и /priv-app."""
    out = {}
    for d in ('/app', '/priv-app'):
        out[d] = sh(f'debugfs -R "ls -l {d}" "{img}"')
    return out


def axml_strings(apk, member='AndroidManifest.xml'):
    try:
        with zipfile.ZipFile(apk) as z:
            data = z.read(member)
    except Exception:
        return ''
    return b'\x00'.join(re.findall(rb'[\x20-\x7e]{3,}', data)).decode('latin-1')


def analyze_apk(path):
    """Пакет, HOME-активности, действия настроек — через androguard."""
    res = {'path': path, 'size': os.path.getsize(path)}
    try:
        from androguard.core.apk import APK
        a = APK(path)
        res['package'] = a.get_package()
        res['app_name'] = a.get_app_name()
        res['version'] = a.get_androidversion_name()
        res['min_sdk'] = a.get_min_sdk_version()
        res['target_sdk'] = a.get_target_sdk_version()

        homes = []
        settings_acts = []
        try:
            axml = a.get_android_manifest_xml()
            for tag in axml.iter():
                if not isinstance(tag.tag, str):
                    continue
                if tag.tag == 'activity' or tag.tag == 'activity-alias':
                    name = tag.get('{http://schemas.android.com/apk/res/android}name') or ''
                    for child in tag.iter():
                        if not isinstance(child.tag, str):
                            continue
                        if child.tag == 'category':
                            cn = child.get('{http://schemas.android.com/apk/res/android}name') or ''
                            if cn.endswith('.HOME') or cn.endswith('.LAUNCHER'):
                                if cn.endswith('.HOME'):
                                    homes.append(name)
                        if child.tag == 'action':
                            an = child.get('{http://schemas.android.com/apk/res/android}name') or ''
                            if an.startswith('android.settings.') or an.startswith('android.intent.action.'):
                                settings_acts.append(an)
        except Exception as e:
            res['manifest_err'] = str(e)
        res['home_activities'] = sorted(set(homes))
        res['intent_actions'] = sorted(set(settings_acts))
    except Exception as e:
        res['error'] = f'{type(e).__name__}: {e}'
        # резервный путь: строки манифеста
        txt = axml_strings(path)
        res['home_activities'] = []
        if 'android.intent.category.HOME' in txt:
            res['home_activities'] = ['(из строк манифеста — точное имя не извлечено)']
        res['raw_packages'] = sorted(set(re.findall(
            r'(?:[a-z][a-z0-9_]*\.){2,}[A-Za-z][A-Za-z0-9_]*', txt)))[:8]
    return res


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    img = sys.argv[1]
    rep = sys.argv[2] if len(sys.argv) > 2 else 'reports'
    os.makedirs(rep, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='probe_settings_')
    out = []

    def w(s=''):
        print(s, flush=True)
        out.append(str(s))

    w(f'образ: {img} ({os.path.getsize(img)} байт)')

    # ---- 1. Листинг каталогов ----
    w('\n=== 1. /app и /priv-app ===')
    listings = dump_dir_listing(img)
    for d, text in listings.items():
        w(f'--- {d} ---')
        for ln in text.splitlines():
            w('  ' + ln)

    # ---- 2. Что такое Launcher2 ----
    w('\n=== 2. /priv-app/Launcher2 — файл или каталог? ===')
    st = sh(f'debugfs -R "stat /priv-app/Launcher2" "{img}"')
    w(st.strip()[:1500])

    # ---- 3. Анализ APK ----
    w('\n=== 3. Анализ APK (лаунчеры, настройки) ===')
    apks = []
    for sub in ('/app', '/priv-app'):
        text = listings.get(sub, '')
        for m in re.finditer(r'^\s*\d+\s+\d+\s+\([\d, ]+\)\s+\d+\s+\d+\s+(\d+)\s+\S+\s+\S+\s+(\S.*)$',
                             text, re.M):
            name = m.group(2).strip()
            if not name or name in ('.', '..'):
                continue
            path = f'{sub}/{name}'
            full = os.path.join(tmp, name)
            got = dump_file(img, path, tmp)
            if got:
                apks.append(got)

    w(f'извлечено APK: {len(apks)}')
    results = []
    for p in sorted(apks):
        if os.path.getsize(p) > 30_000_000:
            w(f'  пропуск большого файла {os.path.basename(p)}')
            continue
        r = analyze_apk(p)
        results.append(r)

    w('\n--- ЛАУНЧЕРЫ (категория HOME) ---')
    for r in results:
        if r.get('home_activities'):
            w(f"  {r.get('package', '?')} ({os.path.basename(r['path'])})")
            w(f"    активности: {', '.join(r['home_activities'])}")

    w('\n--- ПРИЛОЖЕНИЯ С ДЕЙСТВИЯМИ НАСТРОЕК ---')
    for r in results:
        acts = [a for a in r.get('intent_actions', []) if a.startswith('android.settings.')]
        if acts:
            w(f"  {r.get('package', '?')} ({os.path.basename(r['path'])})")
            for a in acts:
                w(f'    {a}')

    w('\n--- ПОИСК com.android.settings / Settings.apk ---')
    found = False
    for r in results:
        pkg = r.get('package', '')
        if pkg in ('com.android.settings', 'com.android.settings2'):
            found = True
            w(f"  НАЙДЕН: {pkg} в {os.path.basename(r['path'])}")
    if not found:
        w('  com.android.settings НЕ НАЙДЕН (штатного приложения настроек нет)')

    w('\n--- ЕСТЬ ЛИ DocumentsUI / файловый менеджер ---')
    for r in results:
        pkg = r.get('package', '')
        if 'documentsui' in pkg.lower() or 'filemanager' in pkg.lower() or 'explorer' in pkg.lower():
            w(f"  {pkg} ({os.path.basename(r['path'])})")

    # ---- 4. Какие действия настроек реально кем-то обрабатываются ----
    w('\n=== 4. Сводка: кто обрабатывает какие android.settings.* ===')
    mapping = {}
    for r in results:
        for a in r.get('intent_actions', []):
            if a.startswith('android.settings.'):
                mapping.setdefault(a, []).append(r.get('package', '?'))
    for a in INTERESTING_ACTIONS:
        who = mapping.get(a, [])
        w(f'  {a}: {who if who else "НИКЕМ не обрабатывается"}')

    # ---- 5. Полный список пакетов ----
    w('\n=== 5. Все пакеты в системе ===')
    for r in sorted(results, key=lambda x: str(x.get('package'))):
        w(f"  {r.get('package', '?'):45s} {os.path.basename(r['path'])}")

    path = os.path.join(rep, 'проба-лаунчеры-настройки.txt')
    open(path, 'w').write('\n'.join(out))
    print(f'\nотчёт: {path}')
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()

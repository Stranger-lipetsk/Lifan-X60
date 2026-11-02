#!/usr/bin/env python3
"""
Патч родного лаунчера Elead (EL830LF01_Home.apk): кнопки новых приложений.

Что делает:
  1. добавляет пакеты в список главного экрана (initDefault_EL830CLF01);
  2. снимает проверку ApplicationInfo.enable в gotoEleadApplication —
     без этого нажатие новой кнопки молча ничего не делает;
  3. добавляет вызов setActivity в ветку «незнакомый пакет» —
     без этого у нового приложения нет интента и запускать нечего.

Работает по распакованному apktool дереву (папка со smali/).

Использование:
    java -jar apktool.jar d Home.apk -o HomeDec
    python3 tools/patch_launcher.py --dir HomeDec \
        --add ru.yandex.yandexnavi --add org.prowl.torque --add com.navitel
    java -jar apktool.jar b HomeDec -o Home-patched.apk
"""
import argparse
import os
import re
import sys

HOMEAPP = 'smali/tw/com/elead/el830/home/HomeApp.smali'


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def add_to_list(text, packages):
    """Вставляет add() в initDefault_EL830CLF01 перед клонированием списка."""
    m = re.search(r'\.method private initDefault_EL830CLF01\(\)V.*?\n\.end method',
                  text, re.S)
    if not m:
        raise SystemExit('не найден метод initDefault_EL830CLF01')
    method = m.group(0)

    # точка вставки — iget-object перед clone(): так пакеты попадут и в
    # mEleadApps, и в mEleadApps_default
    clone = method.find('->clone()Ljava/lang/Object;')
    if clone < 0:
        raise SystemExit('не найден clone() в initDefault_EL830CLF01')
    insert_at = method.rfind('iget-object v0', 0, clone)
    if insert_at < 0:
        raise SystemExit('не найдена точка вставки')

    block = ''
    for pkg in packages:
        if ('const-string v1, "%s"' % pkg) in method:
            print('  уже есть: %s' % pkg)
            continue
        block += (
            '    iget-object v0, p0, Ltw/com/elead/el830/home/HomeApp;->'
            'mEleadApps:Ljava/util/ArrayList;\n\n'
            '    const-string v1, "%s"\n\n'
            '    invoke-virtual {v0, v1}, Ljava/util/ArrayList;->add('
            'Ljava/lang/Object;)Z\n\n' % pkg)
        print('  добавлен в список экрана: %s' % pkg)

    new_method = method[:insert_at] + block + method[insert_at:]
    return text[:m.start()] + new_method + text[m.end():]


def drop_enable_check(text):
    """Убирает ранний выход из gotoEleadApplication при enable == false."""
    m = re.search(
        r'\.method public gotoEleadApplication\(Ljava/lang/String;\)Z.*?\n\.end method',
        text, re.S)
    if not m:
        raise SystemExit('не найден gotoEleadApplication')
    method = m.group(0)

    pat = re.compile(
        r'(iget-boolean\s+v\d+,\s*v\d+,\s*Ltw/com/elead/el830/home/'
        r'ApplicationInfo;->enable:Z\s*\n)(\s*if-nez\s+v\d+,\s*(:\w+))')
    new_method, n = pat.subn(lambda mm: mm.group(1) + '    goto %s' % mm.group(2).split(',')[-1].strip(), method)
    if n == 0:
        if re.search(r'^\s*goto :\w+$', method, re.M):
            print('  проверка enable уже снята')
        else:
            raise SystemExit('не удалось снять проверку enable')
    else:
        print('  проверка enable снята (%d место)' % n)

    return text[:m.start()] + new_method + text[m.end():]


SET_ACTIVITY = (
    '    new-instance v9, Landroid/content/ComponentName;\n\n'
    '    iget-object v10, v4, Landroid/content/pm/ResolveInfo;->activityInfo:'
    'Landroid/content/pm/ActivityInfo;\n\n'
    '    iget-object v10, v10, Landroid/content/pm/ActivityInfo;->applicationInfo:'
    'Landroid/content/pm/ApplicationInfo;\n\n'
    '    iget-object v10, v10, Landroid/content/pm/ApplicationInfo;->packageName:'
    'Ljava/lang/String;\n\n'
    '    iget-object v11, v4, Landroid/content/pm/ResolveInfo;->activityInfo:'
    'Landroid/content/pm/ActivityInfo;\n\n'
    '    iget-object v11, v11, Landroid/content/pm/ActivityInfo;->name:'
    'Ljava/lang/String;\n\n'
    '    invoke-direct {v9, v10, v11}, Landroid/content/ComponentName;-><init>('
    'Ljava/lang/String;Ljava/lang/String;)V\n\n'
    '    const/high16 v10, 0x10200000\n\n'
    '    invoke-virtual {v0, v9, v10}, Ltw/com/elead/el830/home/ApplicationInfo;'
    '->setActivity(Landroid/content/ComponentName;I)V\n\n'
)


def add_set_activity(text):
    """В ветке «незнакомый пакет» задаёт интент для запуска."""
    m = re.search(r'\.method private loadEleadApplications\(\)V.*?\n\.end method',
                  text, re.S)
    if not m:
        raise SystemExit('не найден loadEleadApplications')
    method = m.group(0)

    # метка может быть склеена с :goto_23e
    m_label = re.search(r'^\s*:cond_23e\s*$', method, re.M)
    if not m_label:
        m_label = re.search(r'^\s*:cond_23e', method, re.M)
    if not m_label:
        raise SystemExit('не найдена ветка cond_23e')
    at = method.index(m_label.group(0)) + len(m_label.group(0))
    tail = method[at:]
    if 'ApplicationInfo;->setActivity' in tail[:2500]:
        print('  setActivity в ветке по умолчанию уже есть')
        return text

    # вставляем в самом начале ветки, до заполнения полей
    new_method = method[:at] + '\n' + SET_ACTIVITY + tail
    print('  в ветку «незнакомый пакет» добавлен setActivity')
    return text[:m.start()] + new_method + text[m.end():]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='распакованное apktool дерево')
    ap.add_argument('--add', action='append', default=[],
                    help='имя пакета, которое добавить на главный экран')
    args = ap.parse_args()

    path = os.path.join(args.dir, HOMEAPP)
    if not os.path.exists(path):
        sys.exit('нет файла %s' % path)

    text = read(path)
    print('патч %s' % path)

    if args.add:
        text = add_to_list(text, args.add)
    text = drop_enable_check(text)
    text = add_set_activity(text)

    write(path, text)
    print('готово')


if __name__ == '__main__':
    main()

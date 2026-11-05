#!/usr/bin/env python3
"""Experimental, offline-only patch for the exact stock EL830CLF01 Home smali.

This is NOT an installation tool. The resulting code has not been tested on
hardware. It never patches the firmware image or bypasses package signatures.
The caller must verify the original Home APK hash before decoding it.
"""
import argparse
import re
from pathlib import Path

PACKAGES = ('com.amaze.filemanager', 'ru.lifanx60.panel')
APP_CLASS = 'Ltw/com/elead/el830/home/HomeApp;'
INFO_CLASS = 'Ltw/com/elead/el830/home/ApplicationInfo;'
UI_INFO = 'Ltw/com/elead/el830/home/AppInfo;'


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Expected one occurrence of anchor, found {text.count(old)}: {old[:80]!r}')
    return text.replace(old, new, 1)


def method_patch(text, name, transform):
    pattern = re.compile(r'(?ms)^\.method [^\n]*\b' + re.escape(name) + r'\([^\n]*\n.*?^\.end method')
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError(f'Expected one method {name}, got {len(matches)}')
    match = matches[0]
    return text[:match.start()] + transform(match.group()) + text[match.end():]


def list_patch(method):
    if any(pkg in method for pkg in PACKAGES):
        raise ValueError('Already patched or unexpected original package')
    anchor = ('    iget-object v0, p0, ' + APP_CLASS + '->mEleadApps:Ljava/util/ArrayList;\n\n'
              '    invoke-virtual {v0}, Ljava/util/ArrayList;->clone()Ljava/lang/Object;')
    additions = ''
    for pkg in PACKAGES:
        additions += ('    iget-object v0, p0, ' + APP_CLASS + '->mEleadApps:Ljava/util/ArrayList;\n\n'
                      f'    const-string v1, "{pkg}"\n\n'
                      '    invoke-virtual {v0, v1}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z\n\n')
    return replace_once(method, anchor, additions + anchor)


def custom_app_method(method):
    if ':lifan_custom_app' in method or any(pkg in method for pkg in PACKAGES):
        raise ValueError('Already patched or unexpected original package')
    anchor = ('    const-string v9, "com.fpt.mirrorlink.android"\n\n'
              '    invoke-virtual {v7, v9}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z\n\n'
              '    move-result v9\n\n'
              '    if-eqz v9, :cond_6')
    method = replace_once(method, anchor, anchor.replace('if-eqz v9, :cond_6', 'if-eqz v9, :lifan_custom_app'))
    block = '''
    # Only the two new packages are handled here. Other original paths are unchanged.
    :lifan_custom_app
    const-string v9, "com.amaze.filemanager"
    invoke-virtual {v7, v9}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z
    move-result v9
    if-nez v9, :lifan_setup_app
    const-string v9, "ru.lifanx60.panel"
    invoke-virtual {v7, v9}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z
    move-result v9
    if-nez v9, :lifan_setup_app
    goto/16 :cond_6

    :lifan_setup_app
    iget-object v9, v4, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    invoke-virtual {v9, v5}, Landroid/content/pm/ActivityInfo;->loadLabel(Landroid/content/pm/PackageManager;)Ljava/lang/CharSequence;
    move-result-object v9
    iput-object v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->title:Ljava/lang/CharSequence;
    new-instance v9, Landroid/content/ComponentName;
    iget-object v10, v4, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    iget-object v10, v10, Landroid/content/pm/ActivityInfo;->packageName:Ljava/lang/String;
    iget-object v11, v4, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    iget-object v11, v11, Landroid/content/pm/ActivityInfo;->name:Ljava/lang/String;
    invoke-direct {v9, v10, v11}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V
    const/high16 v10, 0x10200000
    invoke-virtual {v0, v9, v10}, Ltw/com/elead/el830/home/ApplicationInfo;->setActivity(Landroid/content/ComponentName;I)V
    const-string v9, "tw.com.elead.el830.home"
    iput-object v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->menu:Ljava/lang/String;
    const/4 v9, 0x1
    iput-boolean v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->bMenuItem:Z
    iput-boolean v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->enable:Z
    const/4 v9, -0x1
    iput v9, v0, Ltw/com/elead/el830/home/ApplicationInfo;->volumeTable:I
    # beforeAccOff remains false: do not restore either shortcut automatically.
    goto/16 :goto_3
'''
    return replace_once(method, '\n.end method', block + '\n.end method')


def custom_ui_method(method):
    if ':lifan_custom_ui' in method or any(pkg in method for pkg in PACKAGES):
        raise ValueError('Already patched or unexpected original package')
    anchor = ('    const-string v11, "com.fpt.mirrorlink.android"\n\n'
              '    invoke-virtual {v9, v11}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z\n\n'
              '    move-result v11\n\n'
              '    if-eqz v11, :cond_4')
    method = replace_once(method, anchor, anchor.replace('if-eqz v11, :cond_4', 'if-eqz v11, :lifan_custom_ui'))
    block = '''
    :lifan_custom_ui
    const-string v11, "com.amaze.filemanager"
    invoke-virtual {v9, v11}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z
    move-result v11
    if-nez v11, :lifan_setup_ui
    const-string v11, "ru.lifanx60.panel"
    invoke-virtual {v9, v11}, Ljava/lang/String;->equalsIgnoreCase(Ljava/lang/String;)Z
    move-result v11
    if-nez v11, :lifan_setup_ui
    goto/16 :cond_4

    :lifan_setup_ui
    iput-object v9, v0, Ltw/com/elead/el830/home/AppInfo;->Package:Ljava/lang/String;
    iget-object v11, v4, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    invoke-virtual {v11, v7}, Landroid/content/pm/ActivityInfo;->loadLabel(Landroid/content/pm/PackageManager;)Ljava/lang/CharSequence;
    move-result-object v11
    iput-object v11, v0, Ltw/com/elead/el830/home/AppInfo;->title:Ljava/lang/CharSequence;
    iget-object v11, v4, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    invoke-virtual {v11, v7}, Landroid/content/pm/ActivityInfo;->loadIcon(Landroid/content/pm/PackageManager;)Landroid/graphics/drawable/Drawable;
    move-result-object v13
    iput-object v13, v0, Ltw/com/elead/el830/home/AppInfo;->icon:Landroid/graphics/drawable/Drawable;
    iget-boolean v11, v5, Ltw/com/elead/el830/home/ApplicationInfo;->enable:Z
    iput-boolean v11, v0, Ltw/com/elead/el830/home/AppInfo;->enable:Z
    iget-boolean v11, v5, Ltw/com/elead/el830/home/ApplicationInfo;->selected:Z
    iput-boolean v11, v0, Ltw/com/elead/el830/home/AppInfo;->selected:Z
    iput-object v10, v0, Ltw/com/elead/el830/home/AppInfo;->subFunc:Ljava/lang/String;
    iget-object v11, v0, Ltw/com/elead/el830/home/AppInfo;->big_image:[Landroid/graphics/drawable/Drawable;
    const/4 v12, 0x0
    aput-object v13, v11, v12
    const/4 v12, 0x1
    aput-object v13, v11, v12
    const/4 v12, 0x2
    aput-object v13, v11, v12
    sget-object v11, Ltw/com/elead/el830/home/Home;->mApplications:Ljava/util/ArrayList;
    invoke-virtual {v11, v0}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z
    goto/16 :goto_2
'''
    return replace_once(method, '\n.end method', block + '\n.end method')


def patch_app(text):
    text = method_patch(text, 'initDefault_EL830CLF01', list_patch)
    return method_patch(text, 'loadEleadApplications', custom_app_method)


def patch_ui(text):
    return method_patch(text, 'loadApplications', custom_ui_method)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('decoded_dir', type=Path)
    args = parser.parse_args()
    base = args.decoded_dir / 'smali/tw/com/elead/el830/home'
    paths = (base / 'HomeApp.smali', base / 'Home.smali')
    original = [path.read_text(encoding='utf8') for path in paths]
    # Compute both modifications before writing either file; fail closed on mismatch.
    patched = [patch_app(original[0]), patch_ui(original[1])]
    for path, content in zip(paths, patched):
        path.write_text(content, encoding='utf8')
    print('Patched only experimental HomeApp and Home smali. NOT DEVICE TESTED.')


if __name__ == '__main__':
    main()

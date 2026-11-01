#!/usr/bin/env bash
set -u
SRC="${1:-reports/unpacked}"; OUT="${2:-reports/pass5}"
mkdir -p "$OUT"
echo "=== содержимое архива ==="
find "$SRC" -maxdepth 2 | head -30
echo
echo "=== config.ini (backup) ==="
find "$SRC" -name 'config.ini' -print -exec cat {} \; 2>/dev/null
echo
SYS=$(find "$SRC" -name 'system.img' | head -1)
echo "system=$SYS"; file "$SYS"
# ПОЛНЫЙ дамп system в /tmp (как в fw_analyze.py — этот способ работает)
ROOT=/tmp/sysroot
rm -rf "$ROOT"; mkdir -p "$ROOT"
debugfs -R "rdump / \"$ROOT\"" "$SYS" >/dev/null 2>&1 || true
du -sh "$ROOT" 2>/dev/null
echo "=== каталоги ==="
ls "$ROOT"
echo
echo "=== APK-манифесты ==="
python3 - "$ROOT" "$OUT" <<'PY'
import os, re, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
lines = []
for sub in ('app', 'priv-app'):
    d = os.path.join(root, sub)
    for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        fp = os.path.join(d, fn)
        if not os.path.isfile(fp):
            continue
        sz = os.path.getsize(fp)
        line = [f'### /{sub}/{fn} ({sz} байт)']
        if fn.endswith('.apk'):
            try:
                with zipfile.ZipFile(fp) as z:
                    man = z.read('AndroidManifest.xml')
                txt = b'\x00'.join(re.findall(rb'[\x20-\x7e]{3,}', man)).decode('latin-1')
                pkgs = sorted(set(re.findall(r'(?:[a-z][a-z0-9_]*\.){2,}[A-Za-z][A-Za-z0-9_]*', txt)))
                perms = sorted(set(re.findall(r'android\.permission\.[A-Z_]+', txt)))
                acts = sorted(set(re.findall(r'android\.intent\.action\.[A-Z_]+', txt)))
                cats = sorted(set(re.findall(r'android\.intent\.category\.[A-Z_]+', txt)))
                line.append(f'  пакет: {pkgs[:4]}')
                line.append(f'  права: {perms[:18]}')
                line.append(f'  actions: {acts[:10]}')
                if 'android.intent.category.HOME' in txt:
                    line.append('  >>> ЛОНЧЕР (HOME)')
                if 'BOOT_COMPLETED' in txt:
                    line.append('  >>> автозапуск при загрузке')
                if re.search(r'MASTER_CLEAR|factory', txt, re.I):
                    line.append('  >>> упоминает factory/reset')
            except Exception as e:
                line.append(f'  ошибка разбора: {e}')
        lines.append('\n'.join(line))
open(os.path.join(out, 'apk-манифесты.txt'), 'w').write('\n\n'.join(lines))
print('\n\n'.join(lines))
PY
echo
echo "=== Ключевые файлы /etc ==="
for f in ota.conf hosts core_register component_register contentpipe_register display_mode_fb0.conf; do
  p="$ROOT/etc/$f"
  [ -f "$p" ] && { echo "--- /etc/$f ---"; head -40 "$p"; echo; }
done
echo "=== /etc полностью ==="
ls "$ROOT/etc" > "$OUT/etc-список.txt" 2>/dev/null; head -60 "$OUT/etc-список.txt"
echo
echo "=== init.*.rc сервисы (Elead) ==="
grep -hE "^\s*(service|on )" "$ROOT"/init.*.rc 2>/dev/null | head -60 > "$OUT/init-сервисы.txt"; cat "$OUT/init-сервисы.txt"
echo
echo "=== ищем упоминания RAM в u-boot и ядре ==="
for f in $(find "$SRC" -name 'u-boot.bin' -o -name 'boot.img' | head -3); do
  echo "--- $f"; strings -n 5 "$f" | grep -iE "ddr|dram|512M|1024M|memsize|mem=|el_data|para" | sort -u | head -25
done
echo "=== размеры разделов из build_emmc.sh ==="
grep -E "SIZE=|RESERVE=" /tmp/sysroot/etc/build_emmc.sh "$SRC"/*build_emmc.sh 2>/dev/null | head

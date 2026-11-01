#!/usr/bin/env bash
set -u
SRC="${1:-reports/unpacked}"; OUT="${2:-reports/pass4}"
mkdir -p "$OUT"
SYS=$(find "$SRC" -name 'system.img' | head -1)
echo "system=$SYS"
file "$SYS"
# 1) вытащить /etc целиком (небольшой)
debugfs -R "rdump /etc \"$OUT/etc\"" "$SYS" >/dev/null 2>&1 || true
# 2) вытащить /app и /priv-app
debugfs -R "rdump /app \"$OUT/app\"" "$SYS" >/dev/null 2>&1 || true
debugfs -R "rdump /priv-app \"$OUT/privapp\"" "$SYS" >/dev/null 2>&1 || true
# 3) список /etc
echo "=== /etc ===" > "$OUT/список-etc.txt"
debugfs -R 'ls -l /etc' "$SYS" >> "$OUT/список-etc.txt" 2>/dev/null
find "$OUT/etc" -type f 2>/dev/null | head -100
# 4) все мелкие текстовые конфиги
mkdir -p "$OUT/конфиги"
find "$OUT/etc" -type f -size -200k 2>/dev/null | while read -r f; do
  cp "$f" "$OUT/конфиги/$(basename "$f")" 2>/dev/null || true
done
ls "$OUT/конфиги" | head -80
# 5) манифесты APK (строки из AndroidManifest.xml)
python3 - "$OUT" <<'PY'
import os, re, sys, zipfile
out = sys.argv[1]
lines = []
for d in ('app', 'privapp'):
    p = os.path.join(out, d)
    for root, _, files in os.walk(p):
        for fn in sorted(files):
            if not fn.endswith('.apk'):
                continue
            fp = os.path.join(root, fn)
            try:
                with zipfile.ZipFile(fp) as z:
                    man = z.read('AndroidManifest.xml')
            except Exception as e:
                lines.append(f'{fn}: ошибка {e}')
                continue
            txt = b'\x00'.join(re.findall(rb'[\x20-\x7e]{3,}', man)).decode('latin-1')
            pkgs = sorted(set(re.findall(r'(?:[a-z][a-z0-9_]*\.){2,}[A-Za-z][A-Za-z0-9_]*', txt)))
            perms = sorted(set(re.findall(r'android\.permission\.[A-Z_]+', txt)))
            acts = sorted(set(re.findall(r'android\.intent\.action\.[A-Z_]+', txt)))
            lines.append(f'### {fn}  ({os.path.getsize(fp)} байт)')
            lines.append(f'  пакеты: {pkgs[:6]}')
            lines.append(f'  права: {permissions if False else perms[:20]}')
            lines.append(f'  actions: {acts[:12]}')
            if 'android.intent.category.HOME' in txt:
                lines.append('  >>> ЭТО ЛОНЧЕР (HOME)')
open(os.path.join(out, 'apk-манифесты.txt'), 'w').write('\n'.join(lines))
print('\n'.join(lines[:80]))
PY
# 6) RAM: ищем в system конфиги с объёмом
grep -riE "512|1024|ram|mem" "$OUT/конфиги" 2>/dev/null | grep -viE "framework|param|program|ramdisk" | head -20 > "$OUT/ram-догадки.txt" || true
cat "$OUT/ram-догадки.txt" 2>/dev/null
du -sh "$OUT"

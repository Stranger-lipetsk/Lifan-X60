#!/usr/bin/env bash
# Второй проход разбора: ядро, /system/etc, механизм обновления, RAM
set -u
SRC="${1:-reports/unpacked}"
OUT="${2:-reports/deep2}"
mkdir -p "$OUT"/{kernel,etc,etc_permissions,keylayout,initscripts,update}

IMGS=$(find "$SRC" -type f -name '*.img' | sort)
BOOT=$(echo "$IMGS" | grep -m1 'boot.img$')
SD=$(echo "$IMGS" | grep -m1 'sd_boot.img')
SYS=$(echo "$IMGS" | grep -m1 'system.img$' | grep -v sd_boot)
echo "boot=$BOOT"; echo "sd_boot=$SD"; echo "system=$SYS"

########################################
# 1. ЯДРО
########################################
if [ -n "${BOOT:-}" ]; then
  python3 - "$BOOT" "$OUT/kernel" <<'PY'
import sys, struct, os, re
p, out = sys.argv[1], sys.argv[2]
d = open(p,'rb').read()
magic = d[:8]
ks, ka, rs, ra, ss, sa, ta, page = struct.unpack('<IIIIIIII', d[8:40])
print('page', page, 'kernel', ks, 'ramdisk', rs)
kern = d[page:page+ks]
open(os.path.join(out,'zImage'),'wb').write(kern)
# версия ядра может быть в сжатом виде -> ищем в несжатых участках и в строках
txt = kern.decode('latin-1')
for pat in [r'Linux version [^\x00\n]{0,200}', r'3\.0\.\d+[^\x00\n]{0,120}', r'gcc version [^\x00\n]{0,80}']:
    m = re.findall(pat, txt)
    if m:
        open(os.path.join(out,'kernel-marks.txt'),'a').write('\n'.join(sorted(set(m))[:50])+'\n')
PY
  # несжатые строки ядра
  strings -n 6 "$OUT/kernel/zImage" > "$OUT/kernel/strings.txt" 2>/dev/null
  grep -m5 -E 'Linux version' "$OUT/kernel/strings.txt" > "$OUT/kernel/версия.txt"
  grep -iE 'ELEAD|LIFAN|EL830|EL831|solo|imx6|dram|ddr3|512MB|1024MB|1GB|2GB|totalram|mem=' "$OUT/kernel/strings.txt" | sort -u | head -200 >> "$OUT/kernel/версия.txt"
  # ищем сжатый образ (gzip/xz внутри zImage)
  python3 - "$OUT/kernel/zImage" "$OUT/kernel" <<'PY'
import sys, os, zlib, gzip, lzma, io
src, out = sys.argv[1], sys.argv[2]
d = open(src,'rb').read()
# gzip
i = d.find(b'\x1f\x8b\x08')
found = []
while i != -1 and len(found) < 3:
    try:
        raw = zlib.decompressobj(16+zlib.MAX_WBITS).decompress(d[i:i+30_000_000])
        open(os.path.join(out, f'kernel-gz{len(found)}.bin'),'wb').write(raw)
        found.append(len(raw))
        print('gz segment at', i, '->', len(raw))
    except Exception as e:
        pass
    i = d.find(b'\x1f\x8b\x08', i+1)
open(os.path.join(out,'compress-marks.txt'),'w').write(str(found))
PY
  for f in "$OUT"/kernel/kernel-gz*.bin; do
    [ -f "$f" ] || continue
    strings -n 6 "$f" > "$f.strings" 2>/dev/null
    grep -m3 -E 'Linux version' "$f.strings" >> "$OUT/kernel/версия.txt"
    grep -iE 'ELEAD|LIFAN|EL830|EL831|Memory:|MemTotal|DDR|i\.MX6|SOLO|sgtl5000|wm8960|tda77|gt9|ft5x|tw99|adv7180|can' "$f.strings" | sort -u | head -150 >> "$OUT/kernel/ядро-драйверы.txt"
  done
fi

########################################
# 2. SYSTEM: /etc, /permissions, keylayout, bin
########################################
if [ -n "${SYS:-}" ]; then
  RAW="$SYS"
  # sparse?
  python3 - "$SYS" "$OUT" <<'PY'
import sys, struct, os
p, out = sys.argv[1], sys.argv[2]
with open(p,'rb') as f: h=f.read(4)
if struct.unpack('<I', h)[0] != 0xED26FF3A:
    open(os.path.join(out,'.rawpath'),'w').write(p); print('ext4 raw'); sys.exit()
with open(p,'rb') as f:
    magic, major, minor, fhsz, chsz, blksz, tblk, tch, crc = struct.unpack('<IHHHHIIII', f.read(28))
    dst = os.path.join(out,'system.raw.img')
    with open(dst,'wb') as o:
        for _ in range(tch):
            ctype, _, csize, total = struct.unpack('<HHII', f.read(12))
            if ctype == 0xCAC1: o.write(f.read(csize*blksz))
            elif ctype == 0xCAC2:
                v=f.read(4); o.write(v*(csize*blksz//4))
            elif ctype == 0xCAC3: o.write(b'\0'*(csize*blksz))
            elif ctype == 0xCAC4: f.read(4)
    open(os.path.join(out,'.rawpath'),'w').write(dst)
    print('sparse -> raw')
PY
  RAW=$(cat "$OUT/.rawpath" 2>/dev/null || echo "$SYS")
  echo "RAW=$RAW"
  file "$RAW"

  # выборочный дамп каталогов через debugfs (текстовые мелкие файлы)
  for d in /etc /etc/permissions /usr/keylayout /usr/idc /app /priv-app /framework /bin /xbin /vendor; do
    n=$(echo "$d" | tr '/' '_')
    debugfs -R "rdump $d \"$OUT/dump$n\"" "$RAW" >/dev/null 2>&1 || true
  done
  # листинг полный
  debugfs -R 'ls -l -p -R /' "$RAW" > "$OUT/листинг-полный.txt" 2>/dev/null || true

  # собираем текстовые конфиги
  mkdir -p "$OUT/etc"
  find "$OUT"/dump*/ -type f \( -name '*.conf' -o -name '*.xml' -o -name '*.rc' -o -name '*.prop' \
       -o -name '*.kl' -o -name '*.idc' -o -name '*.sh' -o -name '*.txt' -o -name '*.cfg' -o -name '*.ini' \) \
       -size -400k 2>/dev/null | while read -r f; do
    rel=$(echo "$f" | sed "s|$OUT/dump_||; s|/|_|g")
    cp "$f" "$OUT/etc/$rel" 2>/dev/null || true
  done
  du -sh "$OUT/etc" 2>/dev/null
  ls "$OUT/etc" | head -100

  # каталоги приложений и фреймворка
  (debugfs -R 'ls -l /app' "$RAW"; debugfs -R 'ls -l /priv-app'; debugfs -R 'ls -l /bin'; debugfs -R 'ls -l /xbin'; debugfs -R 'ls -l /lib' ) > "$OUT/каталоги.txt" 2>/dev/null || true

  # поиск GMS/Play
  if grep -qE 'GoogleServices|com\.android\.vending|PlayStore' "$OUT/листинг-полный.txt" 2>/dev/null; then
    echo "GMS: есть" > "$OUT/gms.txt"
  else
    echo "GMS: НЕ найдено (чистый AOSP, Play Market отсутствует)" > "$OUT/gms.txt"
  fi
  grep -icE 'magisk|supersu|superuser' "$OUT/листинг-полный.txt" | sed 's/^/root-следы: /' >> "$OUT/gms.txt"

  # свойства пакетов из build.prop внутри system
  find "$OUT"/dump* -name build.prop -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; > "$OUT/system-build.prop" 2>/dev/null || true
  find "$OUT"/dump* -name '*.prop' -size -100k -exec sh -c 'echo "=== $1"; grep -vE "^\s*#|^\s*$" "$1"' _ {} \; >> "$OUT/system-props-все.txt" 2>/dev/null || true
fi

########################################
# 3. МЕХАНИЗМ ОБНОВЛЕНИЯ (sd_boot)
########################################
if [ -n "${SD:-}" ]; then
  python3 - "$SD" "$OUT/update" <<'PY'
import sys, struct, os, gzip, zlib
p, out = sys.argv[1], sys.argv[2]
d = open(p,'rb').read()
ks, ka, rs, ra, ss, sa, ta, page = struct.unpack('<IIIIIIII', d[8:40])
print('sd_boot: kernel', ks, 'ramdisk', rs, 'page', page)
rd = d[page+((ks+page-1)//page)*page:][:rs]
open(os.path.join(out,'ramdisk.bin'),'wb').write(rd)
try:
    raw = gzip.decompress(rd)
except Exception:
    try:
        raw = zlib.decompressobj(16+zlib.MAX_WBITS).decompress(rd)
    except Exception:
        raw = None
if raw:
    open(os.path.join(out,'ramdisk.cpio'),'wb').write(raw)
    print('ramdisk распакован', len(raw))
PY
  if [ -f "$OUT/update/ramdisk.cpio" ]; then
    cd "$OUT/update" && cpio -idmv --no-absolute-filenames < ramdisk.cpio > cpio.log 2>&1 || true; cd - >/dev/null
    du -sh "$OUT/update"
    find "$OUT/update" -maxdepth 2 -type d | head -40
    # ключевые скрипты обновления
    find "$OUT/update" -type f \( -name '*.sh' -o -name '*.rc' -o -name '*.prop' -o -name 'fstab*' \
      -o -name '*.cfg' -o -name '*.ini' -o -name '*.txt' \) -size -300k | head -200 > "$OUT/update/список-скриптов.txt"
    cat "$OUT/update/список-скриптов.txt"
    # собираем содержимое скриптов
    : > "$OUT/update/скрипты-содержимое.txt"
    while read -r f; do
      echo "===== $f =====" >> "$OUT/update/скрипты-содержимое.txt"
      head -c 20000 "$f" >> "$OUT/update/скрипты-содержимое.txt" 2>/dev/null
      echo >> "$OUT/update/скрипты-содержимое.txt"
    done < "$OUT/update/список-скриптов.txt"
    # сжатые образы внутри ramdisk (например update.zip)
    find "$OUT/update" -type f -size +1M -printf '%s\t%p\n' | sort -rn | head -20 > "$OUT/update/крупные-файлы.txt"
    cat "$OUT/update/крупные-файлы.txt"
  fi
fi

########################################
# 4. config.ini из backup
########################################
find "$SRC" -name 'config.ini' -exec sh -c 'echo "=== $1"; cat "$1"; echo' _ {} \; > "$OUT/config-ini.txt" 2>/dev/null || true
cat "$OUT/config-ini.txt" 2>/dev/null

echo "=== ГОТОВО ==="
du -sh "$OUT"

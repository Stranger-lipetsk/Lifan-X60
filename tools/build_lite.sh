#!/usr/bin/env bash
# Сборка "лайт" system.img для ГУ Lifan X60 FL (Elead EL-830C-LF01)
#
# Что делает:
#   1. Скачивает официальную прошивку с Яндекс.Диска (или берёт локальный архив)
#   2. Аудитит состав: клавиатуры, локали, лаунчеры
#   3. Собирает образ с безопасной чисткой и русской локалью
#   4. Проверяет результат (размер 512 МиБ, монтируемость, целостность)
#
# Использование:
#   ./tools/build_lite.sh                          # скачать прошивку и собрать
#   ./tools/build_lite.sh firmware.rar             # из локального архива
#
set -euo pipefail

FW="${1:-}"
OUT="${OUT:-out/system.img}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null || true' EXIT

echo "===================== ЭТАП 1: прошивка ====================="
if [ -z "$FW" ]; then
  echo "качаю официальную прошивку с Яндекс.Диска..."
  mkdir -p "$WORK/fw"
  python3 - <<'PY'
import json, os, subprocess, urllib.parse, urllib.request
pk = 'https://disk.yandex.ru/d/qJdjjeB8Aiq3Lg'
url = ('https://cloud-api.yandex.net/v1/disk/public/resources'
       '?public_key=' + urllib.parse.quote(pk, safe='') + '&limit=100')
items = json.load(urllib.request.urlopen(url, timeout=60))['_embedded']['items']
it = [i for i in items if i['type'] == 'file' and '2016' in i['name']][0]
dest = os.environ['WORK'] + '/fw/firmware.rar'
subprocess.run(['curl', '-L', '--fail', '--retry', '3', '--connect-timeout', '30',
                '--max-time', '2500', '-o', dest, it['file']], check=True)
print('скачано:', os.path.getsize(dest), 'байт')
PY
  FW="$WORK/fw/firmware.rar"
else
  echo "использую локальный архив: $FW"
fi

if [ ! -f "$FW" ]; then
  echo "ОШИБКА: архив не найден: $FW" >&2
  exit 1
fi

echo
echo "===================== ЭТАП 2: аудит состава ====================="
mkdir -p out reports
if [ ! -f out/system-original.img ]; then
  echo "распаковываю system.img из архива..."
  mkdir -p "$WORK/rar"
  7z x -y -aos -o"$WORK/rar" "$FW" >/dev/null 2>&1 || unrar x -o+ "$FW" "$WORK/rar/" >/dev/null 2>&1
  SRC=$(find "$WORK/rar" -name 'system.img' | head -1)
  [ -n "$SRC" ] || { echo "system.img не найден в архиве" >&2; exit 1; }
  cp "$SRC" out/system-original.img
fi
echo "оригинал: out/system-original.img ($(stat -c%s out/system-original.img) байт)"
echo "sha256: $(sha256sum out/system-original.img | cut -d' ' -f1)"

# распаковка для аудита
rm -rf "$WORK/root"
mkdir -p "$WORK/root"
debugfs -R "rdump / \"$WORK/root\"" out/system-original.img >/dev/null 2>&1 || true
rm -rf "$WORK/root/lost+found"
echo "распаковано файлов: $(find "$WORK/root" -type f | wc -l)"
echo
python3 tools/audit_system.py "$WORK/root" 2>&1 | tee reports/аудит-состава.txt

echo
echo "===================== ЭТАП 3: сборка ====================="
# Безопасный набор: НЕ трогаем клавиатуру, оболочку, радио/BT/камеру.
REMOVE_ARGS=(
  --remove /priv-app/Navitel-9.13.73-large.apk
  --remove /app/BSEDemo.apk
  --remove /app/EL830TAM1_GPIO_TEST_2015.01.01.01.apk
  --remove /app/CubeLiveWallpapers.apk
  --remove /app/VisualizationWallpapers.apk
  --remove /app/BasicDreams.apk
  --remove /app/WfdSink.apk
  --remove /app/FSLOta.apk
  --remove /app/HTMLViewer.apk
)

# Скрипт автоподключения карт Navitel и второго USB-порта
EXTRA_ARGS=()

# Приложение-переключатель (лаунчер / настройки / Wi-Fi / файлы)
if [ -f switcher/switcher.apk ]; then
  EXTRA_ARGS+=(--add-apk "switcher/switcher.apk:/app")
  echo "встраиваю Переключатель: switcher/switcher.apk ($(stat -c%s switcher/switcher.apk) байт)"
else
  echo "ВНИМАНИЕ: switcher/switcher.apk не найден — образ будет без переключателя"
fi
if [ -f tools/system-files/install-recovery.sh ]; then
  chmod 0755 tools/system-files/install-recovery.sh
  EXTRA_ARGS+=(--add-file "tools/system-files/install-recovery.sh:/etc/install-recovery.sh")
fi

python3 tools/build_system.py \
  --system out/system-original.img \
  --out "$OUT" \
  --size-mb 512 \
  "${REMOVE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  --set-prop ro.product.locale.language=ru \
  --set-prop ro.product.locale.region=RU \
  --set-prop persist.sys.timezone=Europe/Moscow \
  2>&1 | tee reports/сборка-лайт.txt

echo
echo "===================== ЭТАП 4: проверка ====================="
{
  echo "=== файл ==="
  ls -l "$OUT"
  SZ=$(stat -c%s "$OUT")
  echo "байт: $SZ (эталон раздела p3: 536870912)"
  [ "$SZ" -eq 536870912 ] && echo "РАЗМЕР: OK" || echo "РАЗМЕР: НЕ СОВПАДАЕТ"

  echo "=== ФС ==="
  dumpe2fs -h "$OUT" 2>/dev/null | grep -E "features|Block (size|count)|Inode size|volume name"
  if dumpe2fs -h "$OUT" 2>/dev/null | grep -qE "64bit|metadata_csum"; then
    echo "СОВМЕСТИМОСТЬ ЯДРА: ПРОБЛЕМА (64bit/metadata_csum)"
  else
    echo "СОВМЕСТИМОСТЬ ЯДРА 3.0.35: OK"
  fi

  echo "=== целостность ==="
  e2fsck -fn "$OUT" 2>&1 | tail -4

  echo "=== клавиатура на месте? ==="
  debugfs -R 'ls -l /app' "$OUT" 2>/dev/null | grep -i IQQI || echo "ОШИБКА: клавиатура удалена!"

  echo "=== удалённое ==="
  debugfs -R 'ls -l /priv-app' "$OUT" 2>/dev/null | grep -i navitel && echo "ПРОБЛЕМА: Navitel не удалён" || echo "Navitel удалён — OK"

  echo "=== автоподключение карт (install-recovery.sh) ==="
  IR=$(debugfs -R 'ls -l /etc' "$OUT" 2>/dev/null | grep install-recovery)
  if [ -z "$IR" ]; then
    echo "ПРОБЛЕМА: скрипт отсутствует"
  else
    echo "  $IR"
    echo "$IR" | grep -q '^.*755' && echo "права на исполнение: OK" \
      || echo "ПРОБЛЕМА: скрипт НЕ исполняемый (нужен 755)"
  fi

  echo "=== build.prop ==="
  debugfs -R 'cat /build.prop' "$OUT" 2>/dev/null | grep -E "locale|timezone|version.release"

  echo "=== свободное место ==="
  dumpe2fs -h "$OUT" 2>/dev/null | grep -E "Block count|Free blocks"
  echo "=== sha256 ==="
  sha256sum "$OUT"
} 2>&1 | tee reports/проверка-лайт.txt

echo
echo "ГОТОВО: $OUT"
echo "Отчёты: reports/аудит-состава.txt, reports/сборка-лайт.txt, reports/проверка-лайт.txt"

#!/system/bin/sh
# DISABLED: historical, unvalidated device-backup script. Do not run on a head unit.
# It assumes block mapping, SD location, sizes and privileges, mounts p6 read-write,
# may report success after a partial read, and cannot ensure a consistent snapshot.
# The code below is retained for historical inspection only.
printf '%s\n' 'DISABLED: unsafe, unverified legacy backup; see docs/42-резервное-копирование-ограничения.md' >&2
exit 1
# ============================================================================
#  Резервная копия разделов ГУ Lifan X60 FL (Elead EL-830C-LF01)
#
#  Запускать НА УСТРОЙСТВЕ, нужен root:
#      adb push tools/backup-device.sh /data/local/tmp/backup.sh
#      adb shell su -c "sh /data/local/tmp/backup.sh"
#
#  Параметры:
#      --small       только критичное: p1 (boot) + p6 (para_fw)  ~400 МБ
#      --with-navi   добавить p7 (карты Navitel)                 ~1.8 ГБ
#      (без флагов)  p1, p2, p3, p5, p6                          ~1.7 ГБ
#
#  Результат: /storage/extsd/lifan-backup/  (SD-карта, FAT32)
# ============================================================================

set -e

DEV=/dev/block/mmcblk0
OUT=/storage/extsd/lifan-backup
LOG=$OUT/backup.log

WITH_NAVI=0
SMALL=0
for arg in "$@"; do
  case "$arg" in
    --with-navi) WITH_NAVI=1 ;;
    --small)     SMALL=1 ;;
    -h|--help)
      echo "использование: sh backup.sh [--small] [--with-navi]"
      exit 0 ;;
  esac
done

say() {
  echo "$@"
  [ -f "$LOG" ] && echo "$@" >> "$LOG" || true
}

# ---------------------------------------------------------------- проверки

say "=========================================================="
say " Резервная копия Lifan X60 FL"
say "=========================================================="

# 1. root
if [ "$(id -u)" != "0" ]; then
  say "ОШИБКА: нужны права root."
  say "Запусти так:  adb shell su -c \"sh /data/local/tmp/backup.sh\""
  exit 1
fi
say "[1/6] root: да"

# 2. устройство на месте
if [ ! -b "$DEV" ]; then
  say "ОШИБКА: не найден $DEV"
  exit 1
fi
say "[2/6] eMMC: $DEV"

# 3. SD-карта смонтирована
if [ ! -d /storage/extsd ] || ! mount | grep -q " /storage/extsd "; then
  say "ОШИБКА: SD-карта не смонтирована в /storage/extsd"
  say "Вставь SD-карту (FAT32) и повтори."
  exit 1
fi

mkdir -p "$OUT"
: > "$LOG"

# 4. свободное место
NEED_MB=1800
[ "$SMALL" = "1" ] && NEED_MB=450
[ "$WITH_NAVI" = "1" ] && NEED_MB=3700

FREE_KB=$(df "$OUT" | tail -1 | awk '{print $4}')
FREE_MB=$((FREE_KB / 1024))
say "[3/6] свободно на SD: ${FREE_MB} МБ, нужно ~${NEED_MB} МБ"
if [ "$FREE_MB" -lt "$NEED_MB" ]; then
  say "ОШИБКА: на SD-карте недостаточно места."
  say "Нужно ~${NEED_MB} МБ, есть ${FREE_MB} МБ."
  exit 1
fi

# 5. метаданные
say "[4/6] сохраняю сведения о системе"
{
  echo "дата: $(date)"
  echo
  echo "=== getprop ==="
  getprop
  echo
  echo "=== /proc/cmdline ==="
  cat /proc/cmdline 2>/dev/null
  echo
  echo "=== /proc/partitions ==="
  cat /proc/partitions 2>/dev/null
  echo
  echo "=== mount ==="
  mount
  echo
  echo "=== df ==="
  df
} > "$OUT/система.txt" 2>&1

cat /proc/el_boot_mode > "$OUT/el_boot_mode.txt" 2>/dev/null || true
dmesg > "$OUT/dmesg.txt" 2>/dev/null || true

# 6. разметка
say "[5/6] таблица разделов"
{
  echo "=== sfdisk -l $DEV ==="
  sfdisk -l "$DEV" 2>&1
  echo
  echo "=== fdisk -l $DEV ==="
  fdisk -l "$DEV" 2>&1
} > "$OUT/разделы.txt"

# eMMC boot0 — там U-Boot
if [ -b ${DEV}boot0 ]; then
  say "      U-Boot (boot0) ..."
  dd if=${DEV}boot0 of="$OUT/boot0-uboot.img" 2>>"$LOG" || say "  предупреждение: boot0 не прочитан"
fi

# ---------------------------------------------------------------- разделы

# список: раздел:размер_МБ:описание
backup_part() {
  P=$1
  SIZE=$2
  DESC=$3
  if [ ! -b "${DEV}p$P" ]; then
    say "      p$P: нет такого раздела — пропуск"
    return
  fi
  say "      p$P ($DESC, ~${SIZE} МБ) ..."
  dd if="${DEV}p$P" of="$OUT/p$P-$DESC.img" bs=4M 2>>"$LOG" || {
    say "  ОШИБКА при чтении p$P"
    return
  }
  sync
}

say "[6/6] копирую разделы"

backup_part 1 8   boot

if [ "$SMALL" = "0" ]; then
  backup_part 2 256 swap
  backup_part 3 512 system
  backup_part 5 512 data
fi

backup_part 6 384 el_data

if [ "$WITH_NAVI" = "1" ]; then
  backup_part 7 1800 navi_maps
fi

# ---------------------------------------------------------------- содержимое p6

say ""
say "копирую файлы из p6 (para_fw) в читаемом виде"
P6MNT=/data/local/tmp/p6mnt
mkdir -p "$P6MNT"
if mount -t ext4 "${DEV}p6" "$P6MNT" 2>>"$LOG"; then
  mkdir -p "$OUT/para_fw"
  cp -a "$P6MNT"/. "$OUT/para_fw/" 2>>"$LOG" || say "  предупреждение: часть файлов p6 не скопирована"
  umount "$P6MNT" 2>>"$LOG" || true
  say "   содержимое p6:"
  ls -l "$OUT/para_fw" 2>/dev/null | sed 's/^/     /'
else
  say "  предупреждение: p6 не смонтировался, но образ p6-el_data.img уже сохранён"
fi
rmdir "$P6MNT" 2>/dev/null || true

# ---------------------------------------------------------------- контрольные суммы

say ""
say "считаю контрольные суммы"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$OUT" && sha256sum *.img *.txt 2>/dev/null > checksums-sha256.txt )
  say "  sha256: checksums-sha256.txt"
elif command -v md5sum >/dev/null 2>&1; then
  ( cd "$OUT" && md5sum *.img *.txt 2>/dev/null > checksums-md5.txt )
  say "  md5: checksums-md5.txt"
else
  say "  утилит контрольных сумм нет — сверишь на компьютере"
fi

sync

# ---------------------------------------------------------------- итог

say ""
say "=========================================================="
say " ГОТОВО"
say "=========================================================="
ls -l "$OUT" | sed 's/^/  /'
say ""
say "Дальше:"
say "  1) вынь SD-карту и скопируй папку lifan-backup на компьютер"
say "  2) проверь контрольные суммы"
say "  3) положи копию в надёжное место (НЕ только на SD!)"

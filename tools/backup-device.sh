#!/system/bin/sh
# Запускать НА УСТРОЙСТВЕ через adb shell (нужен root).
# Сохраняет все разделы eMMC на SD-карту в /storage/extsd/lifan-backup/
set -e
OUT=/storage/extsd/lifan-backup
DEV=/dev/block/mmcblk0
mkdir -p "$OUT"

echo "== таблица разделов =="
fdisk -l "$DEV" > "$OUT/разделы.txt" 2>&1 || sfdisk -l "$DEV" >> "$OUT/разделы.txt" 2>&1
cat /proc/cmdline > "$OUT/cmdline.txt"
getprop > "$OUT/getprop.txt"
dmesg > "$OUT/dmesg.txt" 2>/dev/null || true
cat /proc/el_boot_mode > "$OUT/el_boot_mode.txt" 2>/dev/null || true

echo "== U-Boot (boot0) =="
dd if=/dev/block/mmcblk0boot0 of="$OUT/uboot-boot0.img"

echo "== разделы =="
for p in 1 2 3 5 6 7; do
  [ -b "${DEV}p$p" ] || continue
  echo "  p$p ..."
  dd if="${DEV}p$p" of="$OUT/p$p.img" bs=4M
  sync
done

echo "== para_fw (p6) содержимое =="
mkdir -p /mnt/p6
mount -t ext4 "${DEV}p6" /mnt/p6 && cp -a /mnt/p6/. "$OUT/para_fw/" ; umount /mnt/p6

echo "== готово =="
ls -l "$OUT"
echo "Скопируй папку lifan-backup с SD-карты на компьютер и положи в репозиторий"
echo "(большие .img — в firmware/backup/, конфиги — в firmware/backup/para_fw/)"

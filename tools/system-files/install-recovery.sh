#!/system/bin/sh
# ============================================================================
#  Автоподключение накопителей для ГУ Lifan X60 FL (Elead EL-830C-LF01)
#
#  Зачем: раздел с картами Navitel (p7, FAT32 "Navngo") помечен в fstab как
#  закомментированный (voldmanaged=emmc_data:7), поэтому Android его сам
#  не монтирует. Из-за этого Navitel видит карты только с SD-карты.
#  Второй USB-порт (usb2) в рабочем fstab вообще отсутствует.
#
#  Этот скрипт запускается сервисом flash_recovery из init.rc
#  (service flash_recovery /system/etc/install-recovery.sh) от root
#  на каждой загрузке — штатный хук Android, boot.img менять не нужно.
#
#  Откат: удалить файл /system/etc/install-recovery.sh.
# ============================================================================

LOG=/data/local/tmp/mount_storage.log
mkdir -p /data/local/tmp 2>/dev/null
echo "=== $(date) загрузка ===" > $LOG

# --- 1. Ждём готовности vold и появления раздела p7 (карты Navitel) ---------
i=0
while [ $i -lt 40 ]; do
    [ -b /dev/block/mmcblk0p7 ] && break
    i=$((i + 1))
    sleep 1
done
echo "ожидание p7: $i с" >> $LOG

# --- 2. Монтируем раздел с картами в /storage/emmc_data --------------------
#  Именно этот путь Navitel ищет по умолчанию (симлинк создаётся в init.rc).
TARGET=/storage/emmc_data
mkdir -p $TARGET 2>/dev/null

if mount | grep -q " $TARGET "; then
    echo "emmc_data уже смонтирован" >> $LOG
else
    if [ -b /dev/block/mmcblk0p7 ]; then
        mount -t vfat -o rw,uid=1000,gid=1000,fmask=0000,dmask=0000,shortname=mixed \
              /dev/block/mmcblk0p7 $TARGET >> $LOG 2>&1
        if [ $? -eq 0 ]; then
            echo "OK: p7 -> $TARGET" >> $LOG
            # права на запись для медиа-службы
            chown -R media_rw:media_rw $TARGET 2>/dev/null
            chmod -R 0777 $TARGET 2>/dev/null
        else
            # иногда помогает вариант без опций (autodetect)
            mount -t vfat -o rw /dev/block/mmcblk0p7 $TARGET >> $LOG 2>&1
            echo "повтор без опций: $?" >> $LOG
        fi
    else
        echo "p7 не найден — карты недоступны" >> $LOG
    fi
fi

# --- 3. Проверяем структуру каталогов Navitel ------------------------------
#  Navitel 9.x/11.x ищет карты в NavitelContent/Maps, старые — в Navngo.
if mount | grep -q " $TARGET "; then
    for d in NavitelContent NavitelContent/Maps Navngo; do
        mkdir -p "$TARGET/$d" 2>/dev/null
    done
    ls -l $TARGET >> $LOG 2>&1
fi

# --- 4. Второй USB-порт как обычное хранилище ------------------------------
#  В рабочем fstab есть только usb1 (fsl-ehci.0), а usb2 (fsl-ehci.1)
#  отсутствует — поэтому флешка во втором порту не видна.
USBDIR=/storage/usb2
mkdir -p $USBDIR 2>/dev/null
j=0
while [ $j -lt 15 ]; do
    DEV=""
    for c in /dev/block/sda1 /dev/block/sdb1 /dev/block/sda /dev/block/sdb; do
        [ -b "$c" ] && DEV=$c && break
    done
    [ -n "$DEV" ] && break
    j=$((j + 1))
    sleep 1
done
echo "USB-устройство: ${DEV:-нет}" >> $LOG
if [ -n "$DEV" ]; then
    if mount | grep -q " $USBDIR "; then
        echo "usb2 уже смонтирован" >> $LOG
    else
        mount -t vfat -o rw,utf8,uid=1000,gid=1000,fmask=0000,dmask=0000 \
              $DEV $USBDIR >> $LOG 2>&1
        echo "mount $DEV -> $USBDIR: $?" >> $LOG
    fi
fi

echo "=== готово ===" >> $LOG
exit 0

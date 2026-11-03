#!/system/bin/sh
# ============================================================================
#  Накопители и карты Navitel для ГУ Lifan X60 FL (Elead EL-830C-LF01)
#
#  Запускается сервисом из init.rc:
#      service flash_recovery /system/etc/install-recovery.sh
#  то есть от root на каждой загрузке. Штатного файла в прошивке не было,
#  поэтому вызов ничего не делал.
#
#  Что решает:
#   1. Внутренний раздел с картами (p7, FAT32) помечен в fstab как
#      закомментированный (voldmanaged=emmc_data:7) — Android его не монтирует,
#      поэтому карты видны только с SD-карты. Монтируем сами.
#   2. Кнопка MirrorLink на главном экране активна только пока оболочка
#      считает интерфейс доступным: она ждёт broadcast
#      "vn.com.fsoft.UsbIfaceReady" (HomeService$24 в EL830LF01_Home.apk)
#      и по нему включает иконку. Шлём сигнал после загрузки, чтобы кнопка
#      не была серой.
#   3. Navitel ищет NavitelContent на «основном» хранилище (/sdcard).
#      Делаем bind-mount найденного тома с картами в /data/media/NavitelContent,
#      чтобы карты подхватывались с любого носителя (SD, p7, USB).
#
#  USB-порты (музыка/видео) НЕ трогаем: они уже обслуживаются системой
#  (/storage/usb1, /storage/usb2 создаются в init.rc). Используем их только
#  как кандидатов на источник карт.
#
#  Скрипт ничего не форматирует и не удаляет. Откат — удалить этот файл.
#  Ручной запуск для диагностики:  sh /system/etc/install-recovery.sh
#  Лог: /data/local/tmp/mount_storage.log
# ============================================================================

LOG=/data/local/tmp/mount_storage.log
TARGET=/storage/emmc_data
P7=/dev/block/mmcblk0p7
INTERNAL=/data/media
NAV_DIR=NavitelContent
MAP_DIR=NavitelContent/Maps

# --------------------------------------------------------------------------
#  Сигнал штатной оболочке «MirrorLink готов».
#
#  Кнопка MirrorLink на главном экране магнитолы СЕРАЯ, пока оболочка не
#  получит broadcast "vn.com.fsoft.UsbIfaceReady" (HomeService$24 в
#  EL830LF01_Home.apk вызывает по нему enableMirrorLinkIcon(true)).
#  Нажать серую кнопку нельзя, запустить панель вручную тоже — поэтому
#  сигнал обязан прийти сам при загрузке. Отправляем его отсюда.
#
#  Оболочка стартует позже этого скрипта, поэтому сначала ждём её процесс,
#  затем шлём сигнал несколько раз: лишний сигнал безвреден.
# --------------------------------------------------------------------------
announce_ready() {
    # 1. ждём, пока поднимется оболочка (максимум ~2 минуты)
    i=0
    while [ $i -lt 60 ]; do
        if ps 2>/dev/null | grep -q "tw.com.elead.el830.home"; then
            echo "оболочка запущена (жду ${i} циклов)" >> $LOG
            break
        fi
        i=$((i + 1))
        sleep 2
    done

    # 2. ещё немного ждём: оболочке нужно время, чтобы зарегистрировать приёмник
    sleep 10

    # 3. шлём сигнал несколько раз
    sent=0
    n=0
    while [ $n -lt 10 ]; do
        if [ -x /system/bin/am ]; then
            /system/bin/am broadcast -a vn.com.fsoft.UsbIfaceReady \
                >> $LOG 2>&1 && sent=$((sent + 1))
        fi
        n=$((n + 1))
        sleep 6
    done
    echo "сигнал MirrorLink отправлен: $sent из $n" >> $LOG
}

# --------------------------------------------------------------------------
# 0. Установка/обновление панели из образа
#    Оболочка ищет пакет при загрузке; если он уже установлен — обновляем,
#    чтобы новая версия применилась без сброса данных.
# --------------------------------------------------------------------------
#  Панель УЖЕ лежит в /system/app/switcher.apk, система видит её при
#  загрузке. Ставить её через pm при каждой загрузке не нужно и вредно:
#  - работа pm конкурирует с основной оптимизацией приложений;
#  - на первом старте она может зависнуть на «Please wait for system
#    optimization».
#  Ставим ТОЛЬКО если пакета ещё нет в системе (первая загрузка после
#  прошивки со старой раскладкой), и один раз — по метке.
MARK=/data/local/tmp/.panel_installed
if [ ! -f "$MARK" ]; then
    pm path android >/dev/null 2>&1 || sleep 15
    APK=/system/app/switcher.apk
    if [ -f "$APK" ]; then
        pm install -r "$APK" >> $LOG 2>&1
        echo "панель установлена: $?" >> $LOG
    fi
    NAVI=/system/app/navi.apk
    if [ -f "$NAVI" ]; then
        pm install -r "$NAVI" >> $LOG 2>&1
        echo "панель навигатора установлена: $?" >> $LOG
    fi
    touch "$MARK"
fi

mkdir -p /data/local/tmp 2>/dev/null
{
  echo "=============== $(date) ==============="
  echo "--- блочные устройства ---"
  ls -l /dev/block/mmcblk0p* 2>/dev/null
  ls -l /dev/block/sd* 2>/dev/null
  echo "--- смонтировано ---"
  mount | grep -E "mmcblk|sd[a-z]|storage|media_rw"
} >> $LOG 2>&1

# --------------------------------------------------------------------------
# 1. Внутренний раздел с картами (p7)
# --------------------------------------------------------------------------
i=0
while [ $i -lt 30 ]; do
    [ -b $P7 ] && break
    i=$((i + 1))
    sleep 1
done
echo "ожидание $P7: ${i} с" >> $LOG

mkdir -p $TARGET 2>/dev/null
if mount | grep -q " $TARGET "; then
    echo "emmc_data уже смонтирован" >> $LOG
elif [ -b $P7 ]; then
    mount -t vfat -o rw,utf8,uid=1000,gid=1000,fmask=0000,dmask=0000,shortname=mixed \
          $P7 $TARGET >> $LOG 2>&1
    if [ $? -eq 0 ]; then
        echo "OK: p7 -> $TARGET" >> $LOG
        chown -R media_rw:media_rw $TARGET 2>/dev/null
        chmod -R 0777 $TARGET 2>/dev/null
    else
        echo "НЕ УДАЛОСЬ смонтировать p7 (возможно, не FAT32)" >> $LOG
    fi
else
    echo "p7 отсутствует" >> $LOG
fi

# --------------------------------------------------------------------------
# 2. Готовим каталоги Navitel на всех доступных носителях
# --------------------------------------------------------------------------
for v in $TARGET /storage/extsd /storage/usb1 /storage/usb2; do
    [ -d "$v" ] || continue
    mkdir -p "$v/$NAV_DIR" "$v/$MAP_DIR" 2>/dev/null
    echo "каталоги Navitel: $v — $?" >> $LOG
done

# --------------------------------------------------------------------------
# 3. Ищем том, где реально лежат карты (*.nm7)
# --------------------------------------------------------------------------
FOUND=""
for v in $TARGET /storage/extsd /storage/usb1 /storage/usb2; do
    [ -d "$v" ] || continue
    HIT=$(find "$v" -maxdepth 3 -name '*.nm7' -print 2>/dev/null | head -1)
    if [ -n "$HIT" ]; then
        FOUND=$v
        echo "карты найдены: $HIT" >> $LOG
        break
    fi
done

if [ -z "$FOUND" ]; then
    echo "карты *.nm7 не найдены ни на одном носителе" >> $LOG
    announce_ready
    echo "=== готово (без карт) ===" >> $LOG
    exit 0
fi

# --------------------------------------------------------------------------
# 4. Делаем карты видимыми для Navitel через основное хранилище
#    /data/media -> /sdcard (emulated), ровно там Navitel ищет NavitelContent
# --------------------------------------------------------------------------
SRC="$FOUND/$NAV_DIR"
[ -d "$SRC" ] || SRC="$FOUND"

mkdir -p "$INTERNAL" 2>/dev/null

# если внутри уже есть свои карты — ничего не перекрываем
INTERNAL_HAS=$(find "$INTERNAL" -maxdepth 3 -name '*.nm7' -print 2>/dev/null | head -1)

if mount | grep -q " $INTERNAL/$NAV_DIR "; then
    echo "bind-mount для NavitelContent уже активен" >> $LOG
elif [ -n "$INTERNAL_HAS" ]; then
    echo "в $INTERNAL уже есть карты ($INTERNAL_HAS) — перекрытие не нужно" >> $LOG
else
    mkdir -p "$INTERNAL/$NAV_DIR" 2>/dev/null
    mount --bind "$SRC" "$INTERNAL/$NAV_DIR" >> $LOG 2>&1
    if [ $? -eq 0 ]; then
        echo "OK: bind $SRC -> $INTERNAL/$NAV_DIR" >> $LOG
    else
        echo "bind-mount не удался — карты останутся доступны по прямому пути $SRC" >> $LOG
    fi
fi

# --------------------------------------------------------------------------
# 5. Итоговая картина — по логу видно, что получилось
# --------------------------------------------------------------------------
{
  echo "--- итог ---"
  mount | grep -E "emmc_data|NavitelContent|extsd|usb"
  echo "--- содержимое томов ---"
  for v in $TARGET /storage/extsd /storage/usb1 /storage/usb2; do
      [ -d "$v" ] || continue
      echo "[$v]"
      ls "$v" 2>/dev/null | head -10
  done
  echo "=== готово ==="
} >> $LOG 2>&1

announce_ready
exit 0

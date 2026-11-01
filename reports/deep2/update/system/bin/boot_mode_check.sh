#!/system/bin/sh

SWAPIMAGE=/mnt/para_fw/backup_image/swap.img
DATAIMAGE=/mnt/para_fw/backup_image/data.tar
EMMC_NODE=/dev/block/mmcblk0

check_boot_mode()
{
        echo "check_boot_mode"
        if [ -f /proc/el_boot_mode ]; then
                BOOT_MODE=`cat /proc/el_boot_mode`
                if [ $BOOT_MODE == "0" ]; then
                        echo "Lost SWAP image!!"
                        return 1
                fi
        fi
        return 0
}

recovery_swap()
{
    if [ -e $SWAPIMAGE ] && [ -e $DATAIMAGE ]
    then
        /system/bin/mke2fs -t ext4 ${EMMC_NODE}p5 
        mount -t ext4 ${EMMC_NODE}p5 /mnt/media_rw/usb2/
        cd /mnt/media_rw/usb2
        tar -xvf $DATAIMAGE
        dd if=$SWAPIMAGE   of=${EMMC_NODE}p2
        reboot
    fi
    return 0
}

# STEP_1 check boot mode
check_boot_mode
if [ $? == "0" ]; then
    echo "QuickBoot mode or normal boot!!"
    exit
fi

#SETP_2 recovery swap image
recovery_swap

exit 0

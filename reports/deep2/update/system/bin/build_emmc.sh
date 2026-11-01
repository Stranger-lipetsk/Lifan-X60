#!/system/bin/sh

EMMC_MOUNT_PATH=/mnt/inand
EMMC_NODE=/dev/block/mmcblk0
BUILD_OUT_PATH=/fw_data
FILE_BACKUP_PATH=$BUILD_OUT_PATH/backup
BOOTIMG_PATH=$BUILD_OUT_PATH/boot.img
UBOOT_BIN=$BUILD_OUT_PATH/u-boot.bin
SYSTEMIMG=$BUILD_OUT_PATH/system.img
SWAPIMAGE=$BUILD_OUT_PATH/swap.img
DATAIMAGE=$BUILD_OUT_PATH/data.tar


# Upgrade statement
FW_UPGRADE_STATUS="/dev/temp/fw_status.cfg"
PROCESS_START="proc_start"
PROCESS_UNZIP_ROOTFS="unzip_rootfs"
PROCESS_UNZIP_ROOTFS_DONE="unzip_rootfs_done"
PROCESS_UNZIP_MAPS="unzip_maps"
PROCESS_UNZIP_MAPS_DONE="unzip_maps_done"
PROCESS_END="proc_finished"
PROCESS_ERROR="proc_error"
PROCESS_FOMAT="format_partition"

# Total size of files
TOTAL_FILES_SIZE=0
COPIED_FILES_SIZE=0
VARMAP_SIZE=0

# partition size in MB
BOOTLOAD_RESERVE=8
BOOT_ROM_SIZE=8
SYSTEM_ROM_SIZE=512
SWAP_SIZE=256
DATA_SIZE=512
EL_DATA=384
SYSTEM_RESERVE=128

# Files needs to backup
UUID_CONFIG=config.ini

# Files relate  Navi
NAVI_MAP_ARCHIVE=$BUILD_OUT_PATH/Navngo.tgz

function err_exit()
{
    ERRNO=$1
    echo "ERROR CODE : $ERRNO, TERMINATE PROCESS!!"
    echo "$PROCESS_ERROR $ERRNO" > $FW_UPGRADE_STATUS
    exit
}


# Function continue check tar process running in backround
# Pass partition keyword for grep.
check_bg_process()
{
    PARTITION=$1
    FLOW=$2

    EMPTY_DISK_USED=$(df $MOUNT_PATH | grep $PARTITION | awk '{ print $3 }')
    tmp=$COPIED_FILES_SIZE

    ### echo "debug : EMPTY_DISK_USED = $EMPTY_DISK_USED"
    ### echo "debug : BG_PID = $BG_PID"

    while kill -0 $BG_PID
    do
        CUR_DISK_USED=$(df $MOUNT_PATH | grep $PARTITION | awk '{ print $3 }')

        ### echo "debug : CUR_DISK_USED = $CUR_DISK_USED"

        let "COPIED_FILES_SIZE = tmp + (CUR_DISK_USED - EMPTY_DISK_USED)"
        echo "$FLOW $COPIED_FILES_SIZE/$TOTAL_FILES_SIZE" > $FW_UPGRADE_STATUS
        sleep 1
    done
    
    wait $BG_PID
    BG_STATUS=$?

    ### echo "debug : BG_STATUS = $BG_STATUS"
}

function fool_proofing_operation
{
    # check whether had root role
    USERID=`id -u`
    if [ "$USERID" -ne "0" ]; then
        echo "need root permission !!"
        err_exit 1001
    fi
    # check whether device node is exist
    if [ ! -e "$EMMC_NODE" ]; then
        echo "$EMMC_NODE not exist !!"
        err_exit 1002
    fi
    # check invalid node
    if [ "$EMMC_NODE" == /dev/ ]; then
        echo "Not specify the emmc device node !"
        err_exit 1003
    fi

}

function check_essential_files
{
#    if [ ! -e "$UBOOT_BIN" ]; then
#        echo "incorrect u-boot.bin location !"
#        err_exit 1004
#    fi

    if [ ! -e "$BOOTIMG_PATH" ]; then
        echo "incorrect boot.img location !"
        err_exit 1005
    fi

    if [ ! -e "$SYSTEMIMG" ]; then
        echo "incorrect system.img location !"
        err_exit 1006
    fi
        
}


total_size=`sfdisk -s ${EMMC_NODE}`
total_size=`expr ${total_size} / 1024`
boot_rom_sizeb=`expr ${BOOT_ROM_SIZE} + ${BOOTLOAD_RESERVE}`
extend_size=`expr ${total_size} - ${boot_rom_sizeb} - ${SWAP_SIZE} - ${SYSTEM_ROM_SIZE} - ${SYSTEM_RESERVE}`
navi_size=`expr ${extend_size} - ${DATA_SIZE} - ${EL_DATA}`

function partition_operation
{

    # unmount all emmc's partitions
    umount ${EMMC_NODE}*

sfdisk --force -uM ${EMMC_NODE} << EOF
,${boot_rom_sizeb},83
,${SWAP_SIZE},83
,${SYSTEM_ROM_SIZE},83
,${extend_size},5
,${DATA_SIZE},83
,${EL_DATA},83
,${navi_size},0C
EOF
if [ ! $? -eq 0 ]; then err_exit 3001; fi

sfdisk --force -uM ${EMMC_NODE} -N1 << EOF
$BOOTLOAD_RESERVE,$BOOT_ROM_SIZE,83
EOF
if [ ! $? -eq 0 ]; then err_exit 3002; fi
}

function format_operation
{
    if ! /system/bin/mke2fs -t ext4 ${EMMC_NODE}p2; then err_exit 3003; fi
    if ! /system/bin/mke2fs -t ext4 ${EMMC_NODE}p3; then err_exit 3004; fi
    if ! /system/bin/mke2fs -t ext4 ${EMMC_NODE}p5; then err_exit 3005; fi
    if ! /system/bin/mke2fs -t ext4 ${EMMC_NODE}p6; then err_exit 3006; fi
    if ! /system/bin/newfs_msdos -F 32 ${EMMC_NODE}p7; then err_exit 3007; fi
}

function install_operation
{
    # enable inand boot partition 1
    echo 8 > /sys/devices/platform/sdhci-esdhc-imx.2/mmc_host/mmc0/mmc0:0001/boot_config

    # install u-boot.bin
    if [ -e "$UBOOT_BIN" ]
    then
        echo 0 > /sys/block/mmcblk0boot0/force_ro
        if ! dd if=$UBOOT_BIN of=/dev/block/mmcblk0boot0; then
            echo "ERROR! write uboot fail!"
            echo 1 > /sys/block/mmcblk0boot0/force_ro
            err_exit 5001
        fi
        echo 1 > /sys/block/mmcblk0boot0/force_ro
    fi

    # install boot.img in partition 1
    if ! dd if=$BOOTIMG_PATH of=${EMMC_NODE}p1; then
        echo "ERROR! write boot.img fail!"
        err_exit 5002
    fi
    sync

    # install system.img in partition 3
    if ! dd if=$SYSTEMIMG of=${EMMC_NODE}p3; then
        echo "ERROR! write system.img fail!"
        err_exit 5003
    fi
    sync
	
    if [ -e "$SWAPIMAGE" ] && [ -e "$DATAIMAGE" ] 
    then
		dd if=$SWAPIMAGE   of=${EMMC_NODE}p2
		mount -t ext4 ${EMMC_NODE}p5 /mnt/media_rw/usb2/
		tar -xvf $DATAIMAGE -C /mnt/media_rw/usb2
		sync
		umount  /mnt/media_rw/usb2
		# Backup swap image to el_data partition
		mount -t ext4 ${EMMC_NODE}p6 /mnt/media_rw/usb2/
        mkdir /mnt/media_rw/usb2/backup_image
		cp $SWAPIMAGE /mnt/media_rw/usb2/backup_image/
		cp $DATAIMAGE /mnt/media_rw/usb2/backup_image/
		sync
		umount  /mnt/media_rw/usb2
    fi
	sync
}

function backup_operation
{
    rm -rf $FILE_BACKUP_PATH
    mkdir -p $FILE_BACKUP_PATH
    mkdir -p $EMMC_MOUNT_PATH

    if mount -t ext4 ${EMMC_NODE}p6 $EMMC_MOUNT_PATH; then

        if [ -e "$EMMC_MOUNT_PATH"/"$UUID_CONFIG" ]; then

            if ! cp -f $EMMC_MOUNT_PATH/$UUID_CONFIG $FILE_BACKUP_PATH/; then
                umount $EMMC_MOUNT_PATH
                err_exit 2001
            fi
        else
            echo "WARNING!! uuid config file not exist."
        fi
        umount $EMMC_MOUNT_PATH
    else
        echo "ERROR!! unable mount partition 6 ."
        err_exit 2002
    fi
}

function restore_operation
{
    if mount -t ext4 ${EMMC_NODE}p6 $EMMC_MOUNT_PATH; then

        if [ -e "$FILE_BACKUP_PATH"/"$UUID_CONFIG" ]; then

            if ! cp -f $FILE_BACKUP_PATH/$UUID_CONFIG $EMMC_MOUNT_PATH/; then
                umount $EMMC_MOUNT_PATH
                err_exit 4001
            fi
        fi
        umount $EMMC_MOUNT_PATH
    else
        echo "ERROR!! unable mount partition 6 ."
        err_exit 4002
    fi
}

function install_navi_operation
{
    if [ -f "$NAVI_MAP_ARCHIVE"_aa ]; then
        # start to extract navi map archive
        if ! mount ${EMMC_NODE}p7 ${EMMC_MOUNT_PATH}; then err_exit 6001; fi
            
        mkdir -p $EMMC_MOUNT_PATH/Navngo
        for file in "$NAVI_MAP_ARCHIVE"_*
        do
            VARMAP_SIZE=$(du -s $file | awk '{print $1}')
            VARMAP_SIZE=`expr "$VARMAP_SIZE" + "$VARMAP_SIZE" / 2`
            TOTAL_FILES_SIZE=`expr "$TOTAL_FILES_SIZE" + "$VARMAP_SIZE"`
        done

        cat "$NAVI_MAP_ARCHIVE"_* | tar -xzf - -C $EMMC_MOUNT_PATH/ &

        BG_PID=$!
        check_bg_process p7 $PROCESS_UNZIP_MAPS
        if [ ! "$BG_STATUS" -eq 0 ]; then err_exit 6002; fi

        echo "untar map files complete"
        sync
        echo "$PROCESS_UNZIP_MAPS_DONE $COPIED_FILES_SIZE/$TOTAL_FILES_SIZE" > $FW_UPGRADE_STATUS
        
        umount $EMMC_MOUNT_PATH
    fi
}

rm -f $FW_UPGRADE_STATUS
touch $FW_UPGRADE_STATUS
chmod 666 $FW_UPGRADE_STATUS

# main entry point
fool_proofing_operation
check_essential_files
backup_operation
touch $FW_UPGRADE_STATUS
chmod 666 $FW_UPGRADE_STATUS
echo "$PROCESS_FOMAT 5/0" > $FW_UPGRADE_STATUS
partition_operation
format_operation
restore_operation
install_operation
install_navi_operation

sync
echo "$PROCESS_END $COPIED_FILES_SIZE/$TOTAL_FILES_SIZE" > $FW_UPGRADE_STATUS
exit



#/system/bin/sh

echo 0 > /sys/block/mmcblk0boot0/force_ro
dd if=/dev/zero of=/dev/block/mmcblk0boot0 count=10
echo 1 > /sys/block/mmcblk0boot0/force_ro
sync


#!/system/bin/sh
echo ***Save to extsd***
cp /data/data.tar /mnt/media_rw/extsd/
dd if=/dev/block/mmcblk0p2 of=/mnt/media_rw/extsd/swap.img
sync
#echo ***Save to /mnt/para_fw***
#mkdir -p /mnt/para_fw/backup_image/
#cp /data/data.tar /mnt/para_fw/backup_image/
#dd if=/dev/block/mmcblk0p2 of=/mnt/para_fw/backup_image/swap.img
#sync
echo ***End***

#!/system/bin/sh

WAIT_COUNT=3

echo "***START resume system***"

DRIVER_LIST="gt9xx.ko
scsi_mod.ko
scsi_wait_scan.ko
sd_mod.ko
usb-storage.ko
compat.ko
cfg80211.ko
mac80211.ko
wlcore.ko
wlcore_sdio.ko
"


function start_delayed_device
{
	COUNT=0
	while true
	do
		COUNT=$(($COUNT+1))
		BUSY_MODE=`cat /proc/el_ctr`
		if [ "$BUSY_MODE" == "0" ] || [ $COUNT -gt $WAIT_COUNT ]
		then
			echo r > /proc/el_ctr
			return
		fi
		echo "wait !!!"
		sleep 1
	done
}

function insmod_driver
{
	COUNT=0
	while true
	do
		COUNT=$(($COUNT+1))
		BUSY_MODE=`cat /proc/el_ctr`	
		if [ "$BUSY_MODE" == "0" ] || [ $COUNT -gt $WAIT_COUNT ]
		then
			echo $1
			insmod /system/lib/modules/$1
			return
		fi
		echo "wait !!!"
		sleep 1
	done
}

function load_drivers
{
	for DRIVER in $DRIVER_LIST
	do
		insmod_driver $DRIVER
	done
}

# 50M
KEEP_DATA_SIZE=50

function check_data_partition
{
	FREE_DATA_SIZE=$(df -m | grep mmcblk0p5 | tr -s ' ' | cut -d ' ' -f4)

	if [ $FREE_DATA_SIZE -lt $KEEP_DATA_SIZE ]; then
		rm -rf /data/data/com.android.browser/app_webview/*
		sync
	fi
}

# main entry point
echo 1 > /proc/elead_gpio/enabled_det
start_delayed_device
load_drivers

# enable adb
setprop sys.usb.config mtp,adb

# enable console message
echo 7 > /proc/sys/kernel/printk

# Setup wfd parameter 
setprop sys.wifisink.latency 800
setprop media.wfd.sink.max.width 1280
setprop media.wfd.sink.max.height 720

# Change file mode
chmod 666 /mnt/para_fw/config.ini

sleep 15

# check data partition free space
check_data_partition

# disable system swap
busybox swapoff /dev/block/mmcblk0p2

echo "***exit restore_system.sh***"

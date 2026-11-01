#!/system/bin/sh

USB_FAIL_COUNT=20
REBOOT_COUNT=2

function check_module
{
	if [ $PRODUCT_MODEL == "EL-831C-RAV1" ]; then
		CHECK_STR="Vendor=10c4"
		echo "EL-831C-RAV1"
	else
		echo "Not Support~"
		exit 0
	fi
}

function wait_boot
{
	#
	# Wait Boot_mode == 1
	#
	while true
	do
		BOOT_MODE=`cat /proc/el_boot_mode`
		if [ -f /proc/el_boot_mode ]; then
			if [ $BOOT_MODE == "0" ]; then
				sleep 10
			else
				break;
			fi
		else
			echo "Not Support~"
			exit 0
		fi
	done
}

function reset_hub
{
	echo "Reset HUB"
	echo 0 > /proc/elead_gpio/usb_hub_rst
	sleep 1
	echo 1 > /proc/elead_gpio/usb_hub_rst
}

# 
#  main entry point
#
sleep 15
check_module
wait_boot

while true
do
	sleep 10
	grep $CHECK_STR /sys/kernel/debug/usb/devices >> /dev/null
	
	if [ "$?" != "0" ]; then
		if [ $COUNT -ge $REBOOT_COUNT ]; then
			/system/bin/reboot
		fi
			reset_hub
			COUNT=$(($COUNT+1))
			sleep 5
	else
			##echo "Check OK"
			COUNT=0
	fi
	
	##### Check CP210X err count
	if [ -f /proc/cp210x_err_count ]; then
		CP210X_ERR_COUNT=`cat /proc/cp210x_err_count`
		if [ $CP210X_ERR_COUNT -ge $USB_FAIL_COUNT ]; then
			reset_hub
			sleep 5
		fi
	fi
done



#/system/bin/sh
setprop sys.usb.config none
sleep 1
echo r > /proc/el_ctr
sleep 2
setprop sys.usb.config mtp,adb

#!/system/bin/sh

USB_HID_KO=/system/lib/modules/usbhid.ko

if [ ! -z "$1" ]; then

    if [ $1 = "insert" ]; then
        insmod $USB_HID_KO
    elif [ $1 = "remove" ]; then
        rmmod $USB_HID_KO
    fi
else
    insmod $USB_HID_KO
fi

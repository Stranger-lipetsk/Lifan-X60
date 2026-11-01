#!/system/bin/sh

# This script periodically check for the existence of a USB network interface.
# If the interface exists, this script will bring it up and try to assign it an
# IP address using dhcpcd. This script assumes that the name of the network
# interface is "usb0".
#
# Notifications will be broadcast when the USB network interface has been
# assigned an IP address, or the interface has been taken down. The broadcast
# is done using the "am" (Activity Manager) command.

TRUE=1
FALSE=0
IFACE_IS_DOWN=$TRUE
NOTIFICATION_USB_IFACE_READY=vn.com.fsoft.UsbIfaceReady
NOTIFICATION_USB_IFACE_DOWN=vn.com.fsoft.UsbIfaceDown

while true
do
    sleep 1
    if [ -e /sys/class/net/usbH0 ];
    then
        if [ "$IFACE_IS_DOWN" -eq "$TRUE" ];
        then
            netcfg usbH0 up
            if [ "$?" -eq 0 ];
            then
                IFACE_IS_DOWN=$FALSE
                
                # call the dhcpcd twice to avoid the "flock: Try again" error
                dhcpcd usbH0
                dhcpcd usbH0

                # notify the registered applications that the USB network
                # interface is ready
                am broadcast -a $NOTIFICATION_USB_IFACE_READY
            fi
        fi
    else
        if [ "$IFACE_IS_DOWN" -eq "$FALSE" ];
        then
            # The USB network interface has just been taken down, notify the
            # registered applications.
            am broadcast -a $NOTIFICATION_USB_IFACE_DOWN
            IFACE_IS_DOWN=$TRUE
        fi
    fi
done

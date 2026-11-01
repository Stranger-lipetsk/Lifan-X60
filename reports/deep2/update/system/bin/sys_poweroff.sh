#!/system/bin/sh
stop zygote
sync
sync
busybox poweroff -f

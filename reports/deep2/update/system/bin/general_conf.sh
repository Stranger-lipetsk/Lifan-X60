#!/system/bin/sh
# set date-time after 2015-07-30 00:01
/system/bin/date -s 20150730.000000

gt9xx_ver_path=/proc/gt9xx_ver
base_path=/mnt/para_fw
verinfo_file=tp_verinfo
# main entry point
echo "start check touch version"
if [ -e $base_path/$verinfo_file ]; then
	echo "found old $verinfo_file"
	rm $base_path/$verinfo_file
fi

if [ -e $gt9xx_ver_path ]; then
	echo "found $gt9xx_ver_path"
	$(cat $gt9xx_ver_path > $base_path/$verinfo_file)
fi
chmod 444 $base_path/$verinfo_file
sync
echo "end check touch version"


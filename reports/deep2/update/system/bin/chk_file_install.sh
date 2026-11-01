#!/system/bin/bin/sh
SRC_FILE=/system/etc/eGTouchA_v2.5.2112.A-a.ini
DST_FILE=/data/eGTouchA.ini
if [ -s $DST_FILE ];
then
	echo "$DST_FILE had installed ... ^_^"
else
	if [ -s $SRC_FILE ];
	then
		echo "prepare install eGTouchA.ini ... :)"
		cp -f $SRC_FILE $DST_FILE
	else
		echo "No $SRC_FILE ... :("
	fi
fi


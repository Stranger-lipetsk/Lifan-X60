#!/usr/bin/env bash
# GitHub Actions disposable emulator only. Never run on a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
arch=${LAB_ARCH:-x86}
case "$arch" in x86|arm) ;; *) echo 'Unsupported lab architecture'; exit 1;; esac
exec > >(tee "$RUNNER_TEMP/storage-readonly-${arch}-lab.log") 2>&1
work=$(mktemp -d /tmp/storage-readonly-lab.XXXXXX); chmod 0755 "$work"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME" reports
sudo apt-get update -qq
sudo apt-get install -y -qq iptables zip unzip
if [ "$arch" = arm ]; then image='system-images;android-19;default;armeabi-v7a'; else image='system-images;android-19;default;x86'; fi
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' "$image"
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n storage_lab -k "$image" -c 512M >/dev/null
if [ "$arch" = arm ]; then
  curl -fLsS --retry 3 --max-time 120 https://dl.google.com/android/repository/tools_r25.2.5-linux.zip -o "$work/legacy.zip"
  echo "577516819c8b5fae680f049d39014ff1ba4af870b687cab10595783e6f22d33e  $work/legacy.zip" | sha256sum -c -
  mkdir -p "$work/legacy"; unzip -q "$work/legacy.zip" -d "$work/legacy"
  chmod -R a+rX "$work/legacy"
fi
sudo useradd --system --create-home --user-group storagelab
emu_uid=$(id -u storagelab)
sudo chown -R storagelab:storagelab "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status):"; tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'storagelab|AndroidRuntime|FATAL EXCEPTION' | tail -60 || true
    cat "$work/ui.xml" 2>/dev/null || true
    cat "$work/df.txt" 2>/dev/null || true
  fi
  # Classic ARM emulator may not terminate on SIGTERM; this user belongs only
  # to this CI runner and its throwaway emulator.
  sudo pkill -KILL -u storagelab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
if [ "$arch" = arm ]; then
  sudo -u storagelab env HOME=/home/storagelab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
    "$work/legacy/tools/emulator" -avd storage_lab -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -partition-size 1024 > "$work/emulator.log" 2>&1 &
else
  sudo -u storagelab env HOME=/home/storagelab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
    "$sdk/emulator/emulator" -avd storage_lab -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -no-metrics > "$work/emulator.log" 2>&1 &
fi
timeout -k 5 180 "$adb" wait-for-device
booted=no
for i in $(seq 1 100); do
  if [ "$(timeout -k 5 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  sleep 3
done
[ "$booted" = yes ] || { echo 'Emulator boot timeout'; exit 1; }
fingerprint=$(timeout -k 5 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r')
hardware=$(timeout -k 5 30 "$adb" shell getprop ro.hardware | tr -d '\r')
qemu=$(timeout -k 5 30 "$adb" shell getprop ro.kernel.qemu | tr -d '\r')
case "$fingerprint" in generic*:4.4.2/*) ;; *) echo "Unexpected fingerprint: $fingerprint"; exit 1;; esac
case "$hardware" in *goldfish*|*ranchu*) ;; *) echo "Unexpected hardware: $hardware"; exit 1;; esac
[ "$qemu" = 1 ] || exit 1
# UIAutomator writes its dump to a private directory on emulator /dev tmpfs,
# not /sdcard (which can itself be backed by the deliberately full /data).
timeout -k 5 30 "$adb" shell 'mkdir /dev/x60-storage-lab-ui && chmod 0777 /dev/x60-storage-lab-ui'
src=tests/fixtures/storage-readonly-lab
mkdir -p "$work/classes" "$work/dex" "$work/mount-test"
javac -d "$work/mount-test" "$src/src/ru/lifanx60/storagelab/MountFilter.java" "$src/src/ru/lifanx60/storagelab/SectorParser.java" "$src/test/MountFilterTest.java" "$src/test/SectorParserTest.java"
java -cp "$work/mount-test" MountFilterTest
java -cp "$work/mount-test" SectorParserTest
"$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/unsigned.apk"
find "$src/src" -name '*.java' | sort > "$work/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/classes" @"$work/sources.txt"
find "$work/classes" -name '*.class' > "$work/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/dex" @"$work/classes.txt"
cp "$work/dex/classes.dex" "$work/classes.dex"
(cd "$work" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
keytool -genkeypair -keystore "$work/lab.keystore" -storepass test-only -keypass test-only -alias lab -keyalg RSA -keysize 2048 -validity 10 -dname 'CN=Disposable storage lab' >/dev/null 2>&1
"$bt/apksigner" sign --ks "$work/lab.keystore" --ks-pass pass:test-only --key-pass pass:test-only --min-sdk-version 19 --v1-signing-enabled true --out "$work/lab.apk" "$work/aligned.apk"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 "$work/lab.apk"
"$bt/aapt" dump permissions "$work/lab.apk" | tee "$work/permissions.txt"
! grep -q 'uses-permission' "$work/permissions.txt"
timeout -k 10 120 "$adb" install "$work/lab.apk" | tee "$work/install.txt"
grep -F Success "$work/install.txt"
timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.storagelab | tr -d '\r' > "$work/package.txt"
uid=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package.txt" | head -1)
case "$uid" in ''|*[!0-9]*) exit 1;; esac
[ "$uid" -ge 10000 ] || { echo 'Not an ordinary app UID'; exit 1; }
timeout -k 5 20 "$adb" shell input keyevent 82 || true
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.storagelab/.MainActivity | tee "$work/start.txt"
ready=no
for i in $(seq 1 30); do
  if timeout -k 5 50 "$adb" shell uiautomator dump /dev/x60-storage-lab-ui/ui.xml >/dev/null 2>&1 &&
     timeout -k 5 20 "$adb" shell cat /dev/x60-storage-lab-ui/ui.xml > "$work/ui.xml" &&
     grep -q TOTAL_KIB "$work/ui.xml"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Probe UI not displayed'; exit 1; }
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /data ' > "$work/mount.txt"
timeout -k 5 30 "$adb" shell df /data | tr -d '\r' > "$work/df.txt"
python3 tools/validate_storage_probe_ui.py "$work/ui.xml" "$work/mount.txt" "$work/df.txt" | tee "$work/validation.txt"
# Compare the ordinary app's fixed virtual SD sysfs reading with shell and
# /proc/partitions. This is not a test of the physical head unit's p5.
timeout -k 5 30 "$adb" shell cat /sys/class/block/mmcblk0/size | tr -d '\r' > "$work/sd-sectors.txt" || true
timeout -k 5 30 "$adb" shell cat /proc/partitions | tr -d '\r' > "$work/partitions.txt"
python3 tools/validate_storage_sysfs_lab.py "$work/ui.xml" "$work/sd-sectors.txt" "$work/partitions.txt" | tee "$work/sysfs-validation.txt"
# Fill only a fixed synthetic file on this verified disposable emulator, as
# Android shell UID 2000. No real partition or user files are involved.
# A non-root writer must stop at ext4's reserve, not consume root's blocks.
echo 'LAB ONLY: fill a synthetic file as non-root shell until ENOSPC'
timeout -k 5 30 "$adb" shell 'su 2000 id' | tr -d '\r' | tee "$work/fill-id.txt"
grep -Fq 'uid=2000' "$work/fill-id.txt"
timeout -k 10 240 "$adb" shell 'su 2000 sh -c "dd if=/dev/zero of=/data/local/tmp/x60-storage-fill-lab bs=1048576 count=2048"' > "$work/fill.txt" 2>&1 || true
cat "$work/fill.txt"
grep -iEq 'No space left on device|ENOSPC' "$work/fill.txt" || { echo 'Synthetic fill did not reach expected ENOSPC'; exit 1; }
# A 1 MiB dd write can fail with some smaller blocks still available. Fill
# that tail with smaller writes, using the same fixed synthetic file.
timeout -k 10 120 "$adb" shell 'su 2000 sh -c "dd if=/dev/zero bs=4096 count=512 >> /data/local/tmp/x60-storage-fill-lab"' > "$work/fill-tail.txt" 2>&1 || true
cat "$work/fill-tail.txt"
grep -iEq 'No space left on device|ENOSPC' "$work/fill-tail.txt" || { echo 'Synthetic tail did not reach ENOSPC'; exit 1; }
capture_probe() {
  local phase=$1 ready=no
  timeout -k 5 30 "$adb" shell am force-stop ru.lifanx60.storagelab
  timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.storagelab/.MainActivity > "$work/start-$phase.txt" 2>&1
  for i in $(seq 1 30); do
    if timeout -k 5 50 "$adb" shell uiautomator dump /dev/x60-storage-lab-ui/ui.xml >/dev/null 2>&1 &&
       timeout -k 5 20 "$adb" shell cat /dev/x60-storage-lab-ui/ui.xml > "$work/ui-$phase.xml" &&
       grep -q TOTAL_KIB "$work/ui-$phase.xml"; then ready=yes; break; fi
    sleep 2
  done
  [ "$ready" = yes ] || { echo "Probe UI missing at $phase"; return 1; }
  timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /data ' > "$work/mount-$phase.txt"
  timeout -k 5 30 "$adb" shell df /data | tr -d '\r' > "$work/df-$phase.txt"
  python3 tools/validate_storage_probe_ui.py "$work/ui-$phase.xml" "$work/mount-$phase.txt" "$work/df-$phase.txt" > "$work/validation-$phase.txt"
  cat "$work/validation-$phase.txt"
}
capture_probe full
# x86 image has a nonzero reserve; generic ARM image can use zero reserve.
# The tail and background services can change counts between measurements.
python3 - "$arch" "$work/ui-full.xml" "$work/mount-full.txt" "$work/df-full.txt" <<'PY2'
from pathlib import Path
import sys
from tools.validate_storage_probe_ui import validate
arch = sys.argv[1]
values, _ = validate(*(Path(p).read_text(encoding='utf-8') for p in sys.argv[2:]))
assert values['AVAILABLE_KIB'] < 4096, values
if arch == 'x86':
    assert values['AVAILABLE_KIB'] == 0 and values['FREE_KIB'] > 0, values
print('Probe at ENOSPC:', arch, values)
PY2
# Separate positive recovery control: remove only the fixed synthetic file in
# the disposable emulator. This is never an instruction to delete real data.
timeout -k 5 30 "$adb" shell 'test -f /data/local/tmp/x60-storage-fill-lab && test ! -L /data/local/tmp/x60-storage-fill-lab && rm /data/local/tmp/x60-storage-fill-lab && echo SYNTHETIC_FILL_REMOVED' | tr -d '\r' | grep -Fx SYNTHETIC_FILL_REMOVED
capture_probe freed
python3 - "$work/ui-freed.xml" "$work/mount-freed.txt" "$work/df-freed.txt" <<'PY2'
from pathlib import Path
import sys
from tools.validate_storage_probe_ui import validate
values, _ = validate(*(Path(p).read_text(encoding='utf-8') for p in sys.argv[1:]))
assert values['AVAILABLE_KIB'] > 100000, values
print('Confirmed positive app-available space after synthetic-only removal:', values)
PY2
{
  echo "# Storage probe fixture, disposable Android 4.4.2 $arch emulator"
  echo 'Emulator only; no physical device. Host network blocked for emulator process. APK and signing key remain ephemeral.'
  echo 'Fixture refuses non-generic hardware, requests no permissions, uses ordinary app UID and does not write app files or enumerate user data.'
  echo "Fingerprint: $fingerprint; hardware: $hardware; UID: $uid"
  echo 'Mount and sector parser unit cases passed; package permissions from aapt:'; cat "$work/permissions.txt"
  echo 'Fixed virtual SD sysfs capacity validation:'; cat "$work/sysfs-validation.txt"
  echo 'UI numeric fields and selected /data mount checked against emulator shell df and /proc/mounts:'; cat "$work/validation.txt"
  echo 'Shell mount and df:'; cat "$work/mount.txt" "$work/df.txt"
  echo 'Synthetic non-root filler ended in ENOSPC:'; cat "$work/fill-id.txt" "$work/fill.txt" "$work/fill-tail.txt"
  echo 'Probe with the synthetic volume full:'; cat "$work/validation-full.txt" "$work/df-full.txt"
  echo 'Probe after removing ONLY the synthetic filler on the disposable emulator:'; cat "$work/validation-freed.txt" "$work/df-freed.txt"
  echo 'Read-only app logic still involves Android installation, activity/runtime and emulator UI automation writes; this is not a proof of zero OS-level writes.'
  echo 'The app view represents its own mount namespace. A missing literal mmcblk0p5 mount is not evidence that partition is absent or empty.'
  echo 'An optional fixed sysfs attribute gives capacity only, not free space; actual head-unit size, access, device naming and Hibernate are unknown. No deployable APK published.'
} > "reports/storage-readonly-${arch}-lab.txt"

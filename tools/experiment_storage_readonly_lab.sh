#!/usr/bin/env bash
# GitHub Actions disposable emulator only. Never run on a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/storage-readonly-lab.log") 2>&1
work=$(mktemp -d /tmp/storage-readonly-lab.XXXXXX); chmod 0755 "$work"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME" reports
sudo apt-get update -qq
sudo apt-get install -y -qq iptables zip unzip
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;x86'
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n storage_lab -k 'system-images;android-19;default;x86' -c 512M >/dev/null
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
  sudo pkill -TERM -u storagelab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
sudo -u storagelab env HOME=/home/storagelab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
  "$sdk/emulator/emulator" -avd storage_lab -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -no-metrics > "$work/emulator.log" 2>&1 &
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
src=tests/fixtures/storage-readonly-lab
mkdir -p "$work/classes" "$work/dex" "$work/mount-test"
javac -d "$work/mount-test" "$src/src/ru/lifanx60/storagelab/MountFilter.java" "$src/test/MountFilterTest.java"
java -cp "$work/mount-test" MountFilterTest
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
  if timeout -k 5 50 "$adb" shell uiautomator dump /sdcard/storage-lab-ui.xml >/dev/null 2>&1 &&
     timeout -k 5 20 "$adb" shell cat /sdcard/storage-lab-ui.xml > "$work/ui.xml" &&
     grep -q TOTAL_KIB "$work/ui.xml"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Probe UI not displayed'; exit 1; }
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /data ' > "$work/mount.txt"
timeout -k 5 30 "$adb" shell df /data | tr -d '\r' > "$work/df.txt"
python3 tools/validate_storage_probe_ui.py "$work/ui.xml" "$work/mount.txt" "$work/df.txt" | tee "$work/validation.txt"
{
  echo '# Storage probe fixture, disposable Android 4.4.2 x86 emulator'
  echo 'Emulator only; no physical device. Host network blocked for emulator process. APK and signing key remain ephemeral.'
  echo 'Fixture refuses non-generic hardware, requests no permissions, uses ordinary app UID and does not write app files or enumerate user data.'
  echo "Fingerprint: $fingerprint; hardware: $hardware; UID: $uid"
  echo 'Mount parser unit cases passed; package permissions from aapt:'; cat "$work/permissions.txt"
  echo 'UI numeric fields and selected /data mount checked against emulator shell df and /proc/mounts:'; cat "$work/validation.txt"
  echo 'Shell mount and df:'; cat "$work/mount.txt" "$work/df.txt"
  echo 'Read-only app logic still involves Android installation, activity/runtime and emulator UI automation writes; this is not a proof of zero OS-level writes.'
  echo 'The app view represents its own mount namespace. A missing literal mmcblk0p5 mount is not evidence that partition is absent or empty.'
  echo 'Does not query unmounted partitions, actual head-unit size, free space, runtime access or Hibernate. No deployable APK published.'
} > reports/storage-readonly-lab.txt

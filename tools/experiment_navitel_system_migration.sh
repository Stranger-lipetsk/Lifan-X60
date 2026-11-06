#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never use this on a head unit.
set -euo pipefail
exec > >(tee "$RUNNER_TEMP/navitel-migration.log") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-migration.XXXXXX); chmod 0755 "$work"; mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip

echo 'Phase 1: obtain two real Navitel APKs; no user files or license'
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" system.img > "$work/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $work/system.img" | sha256sum -c -
debugfs -R "dump /priv-app/Navitel-large.apk $work/old.apk" "$work/system.img" >/dev/null 2>&1
echo "6e216ab39aacaafacda1ebb09f6edc8726e4d1eb6b4985256ccd18aeb5046c44  $work/old.apk" | sha256sum -c -
new="$GITHUB_WORKSPACE/firmware/apks/com.navitel.apk"
echo "96876415d8b4342952558fd30d6e11b0ca9355c802060c0a9740b6cc84fc4e1b  $new" | sha256sum -c -
for spec in "$work/old.apk:old:a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc" "$new:new:5358662d39856446c7391c699878e0509f7ed0657d7634c0083e07b08ad2f035"; do
  IFS=: read -r apk name cert <<< "$spec"
  "$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$apk" > "$work/$name-cert.txt"
  grep -F "certificate SHA-256 digest: $cert" "$work/$name-cert.txt"
  "$bt/aapt" dump badging "$apk" > "$work/$name-badging.txt"
  grep -F "package: name='com.navitel'" "$work/$name-badging.txt"
done

echo 'Phase 2: boot isolated Android 4.4.2 ARMv7'
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'system-images;android-19;default;armeabi-v7a'
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n migration_arm -k 'system-images;android-19;default;armeabi-v7a' -c 1024M >/dev/null
curl -fLsS --retry 3 --max-time 120 https://dl.google.com/android/repository/tools_r25.2.5-linux.zip -o "$work/legacy.zip"
echo "577516819c8b5fae680f049d39014ff1ba4af870b687cab10595783e6f22d33e  $work/legacy.zip" | sha256sum -c -
mkdir -p "$work/legacy"; unzip -q "$work/legacy.zip" -d "$work/legacy"
chmod -R a+rX "$work/legacy"
# The original system app could have BOOT_COMPLETED receivers. Block ALL
# emulator-owned external network traffic before its first boot, including IPv6.
# Local loopback remains available for adb. This is a disposable hosted runner.
sudo useradd --system --create-home --user-group emulatorlab
emu_uid=$(id -u emulatorlab)
sudo chown -R emulatorlab:emulatorlab "$ANDROID_AVD_HOME"
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Failure ($status): emulator log"; tail -50 "$work/emulator.txt" 2>/dev/null || true
    timeout 10 "$adb" devices -l || true
  fi
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  sudo pkill -TERM -u emulatorlab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4 and IPv6 blocked"
start_emulator() {
  sudo -u emulatorlab env HOME=/home/emulatorlab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
    "$work/legacy/tools/emulator" -avd migration_arm -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic >> "$work/emulator.txt" 2>&1 &
  pid=$!
}
restart_emulator() {
  # Use a process restart rather than the legacy emulator's hanging adb reboot.
  timeout 30 "$adb" shell sync || true
  sudo pkill -TERM -u emulatorlab 2>/dev/null || true
  for i in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then sudo pkill -KILL -u emulatorlab 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
  start_emulator
  boot
}
start_emulator
boot() {
  "$adb" wait-for-device &
  local waitpid=$! connected=no
  for i in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null; then echo 'Emulator exited before adb'; break; fi
    if ! kill -0 "$waitpid" 2>/dev/null; then wait "$waitpid" && connected=yes; break; fi
    sleep 5
  done
  kill "$waitpid" 2>/dev/null || true
  [ "$connected" = yes ] || { echo 'ADB connection timeout'; return 1; }
  local booted=no
  for i in $(seq 1 100); do
    if [ "$(timeout 3 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
    kill -0 "$pid" 2>/dev/null || { echo 'Emulator exited'; exit 1; }
    sleep 3
  done
  [ "$booted" = yes ] || { echo 'Emulator boot timeout'; exit 1; }
}
boot
id=$(timeout 60 "$adb" shell id | tr -d '\r')
echo "Shell identity: $id"
grep -q 'uid=0' <<< "$id" || { echo 'Root shell unavailable; abort'; exit 1; }
timeout 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r' > "$work/fingerprint.txt"
timeout 30 "$adb" shell getprop ro.product.cpu.abi | tr -d '\r' > "$work/abi.txt"
echo 'Trying remount of emulator system only'
timeout 60 "$adb" remount | tee "$work/remount.txt"
grep -iq 'remount succeeded' "$work/remount.txt" || { echo 'Cannot remount emulator system'; exit 1; }
timeout 30 "$adb" shell df /system | tr -d '\r'

echo 'Phase 3: push old system APK on disposable emulator'
timeout 300 "$adb" push "$work/old.apk" /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell chmod 0644 /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell restorecon /system/priv-app/Navitel-large.apk || true
echo "Phase 3a: restart emulator with old package"
restart_emulator
echo "Phase 3b: verify old system APK persisted and query package"
timeout 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/old-after-restart.apk" >/dev/null
cmp "$work/old.apk" "$work/old-after-restart.apk" || { echo 'Old system file did not persist'; exit 1; }
path=$(timeout 60 "$adb" shell pm path com.navitel | tr -d '\r')
echo "Initial package path: $path"
grep -F 'package:/system/priv-app/Navitel-large.apk' <<< "$path" || { echo 'Old system app not registered'; exit 1; }
timeout 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/old-package.txt"
uid_before=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/old-package.txt" | head -1)
case "$uid_before" in ''|*[!0-9]*) echo 'Initial app UID missing'; exit 1;; esac
timeout 30 "$adb" shell 'mkdir -p /data/data/com.navitel/files && echo X60_DISPOSABLE_MIGRATION_TEST > /data/data/com.navitel/files/lab-marker.txt'
timeout 30 "$adb" shell chown "$uid_before:$uid_before" /data/data/com.navitel/files/lab-marker.txt
before_marker=$(timeout 30 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt | tr -d '\r')
test "$before_marker" = X60_DISPOSABLE_MIGRATION_TEST

echo 'Phase 4: replace system APK in disposable emulator'
timeout 60 "$adb" remount | tee "$work/remount2.txt"
grep -iq 'remount succeeded' "$work/remount2.txt"
timeout 30 "$adb" shell rm /system/priv-app/Navitel-large.apk
timeout 300 "$adb" push "$new" /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell chmod 0644 /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell restorecon /system/priv-app/Navitel-large.apk || true
timeout 30 "$adb" logcat -c
echo "Phase 4a: restart emulator with new package"
restart_emulator
echo "Phase 4b: verify new system APK persisted and query marker"
timeout 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/new-after-restart.apk" >/dev/null
cmp "$new" "$work/new-after-restart.apk" || { echo 'New system file did not persist'; exit 1; }
set +e
timeout 60 "$adb" shell pm path com.navitel > "$work/new-path.txt" 2>&1; path_status=$?
timeout 60 "$adb" shell dumpsys package com.navitel > "$work/new-package.txt" 2>&1; dump_status=$?
timeout 60 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt > "$work/marker.txt" 2>&1; marker_status=$?
timeout 60 "$adb" logcat -d -v brief > "$work/logcat.txt" 2>&1
set -e
uid_after=$(tr -d '\r' < "$work/new-package.txt" | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -1 || true)
{
  echo '# Navitel system package migration in a disposable Android 4.4.2 ARM emulator'
  echo 'Generic AOSP PackageManager, NOT the vendor framework or head unit. Never use these operations on a physical unit.'
  echo 'Two real Navitel APKs were placed as system APKs. No interactive launch, real user account, license, maps or SD were used.'
  echo 'Host firewall blocks non-loopback IPv4 and IPv6 for the emulator process, including during boot; receiver or service activity was not separately traced.'
  echo "Fingerprint: $(cat "$work/fingerprint.txt"), ABI: $(cat "$work/abi.txt")"
  echo 'Initial certificate SHA-256: a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc'
  echo 'Replacement certificate SHA-256: 5358662d39856446c7391c699878e0509f7ed0657d7634c0083e07b08ad2f035'
  echo "Old UID: $uid_before; new UID: ${uid_after:-unavailable}"
  echo '## Package before'; grep -E 'versionCode=|versionName=|userId=|codePath=|dataDir=' "$work/old-package.txt" | head -20 || true
  echo '## Package after'; echo "pm path status: $path_status; dumpsys status: $dump_status"; tr -d '\r' < "$work/new-path.txt"; tr -d '\r' < "$work/new-package.txt" | grep -E 'versionCode=|versionName=|userId=|codePath=|dataDir=' | head -20 || true
  echo '## Synthetic marker'; echo "read status: $marker_status"; tr -d '\r' < "$work/marker.txt"
  echo '## Selected PackageManager logs, if still present'
  grep -iE 'com\.navitel|signature changed|retaining data' "$work/logcat.txt" | tail -30 | tr -d '\r' || true
  echo 'Observation is limited to a fresh, generic emulator data state; no inference of preservation of real Navitel settings or licenses is justified.'
} > reports/navitel-system-migration-emulator.txt

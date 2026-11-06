#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never run against a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/navitel-arm-combined-backup-lab.log") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-arm-combined-backup-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip android-sdk-libsparse-utils file

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

echo 'Verify public AOSP test key matches the stock Navitel certificate'
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
for ext in x509.pem pk8; do
  gh api "repos/aosp-mirror/platform_build/contents/target/product/security/testkey.$ext?ref=$ref" --jq .content | base64 -d > "$work/testkey.$ext"
done
keycert=$(openssl x509 -in "$work/testkey.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
test "$keycert" = a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc
# Candidate is generated only inside the throwaway CI runner; do not publish it.
"$bt/zipalign" -f 4 "$new" "$work/new-aligned.apk"
"$bt/apksigner" sign --key "$work/testkey.pk8" --cert "$work/testkey.x509.pem" --min-sdk-version 19 \
  --v1-signing-enabled true --v2-signing-enabled false --v3-signing-enabled false \
  --out "$work/new-resigned.apk" "$work/new-aligned.apk"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/new-resigned.apk" > "$work/resigned-cert.txt" 2>&1
grep -F "certificate SHA-256 digest: $keycert" "$work/resigned-cert.txt"
python3 tools/compare_resigned_apk.py "$new" "$work/new-resigned.apk" | tee "$work/compare.txt"

echo 'Phase 2: boot isolated Android 4.4.2 ARMv7'
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;armeabi-v7a'
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n migration_arm -k 'system-images;android-19;default;armeabi-v7a' -c 1024M >/dev/null
curl -fLsS --retry 3 --max-time 120 https://dl.google.com/android/repository/tools_r25.2.5-linux.zip -o "$work/legacy.zip"
echo "577516819c8b5fae680f049d39014ff1ba4af870b687cab10595783e6f22d33e  $work/legacy.zip" | sha256sum -c -
mkdir -p "$work/legacy"; unzip -q "$work/legacy.zip" -d "$work/legacy"
chmod -R a+rX "$work/legacy"
# CI-only: build a generic ARM system image offline before the emulator starts.
# This is NOT the device image and is never published or flashed.
echo 'Build disposable generic ARM system image OFFLINE to avoid emulator system writes'
generic="$sdk/system-images/android-19/default/armeabi-v7a/system.img"
test -s "$generic"
file "$generic"
magic=$(od -An -tx1 -N4 "$generic" | tr -d ' \n')
if [ "$magic" = '3aff26ed' ]; then simg2img "$generic" "$work/offline-system.img"; else cp --sparse=always "$generic" "$work/offline-system.img"; fi
file "$work/offline-system.img"
# e2fsck returns 1 when it corrected the disposable SDK image, which is expected.
fsck_rc=0
e2fsck -fy "$work/offline-system.img" || fsck_rc=$?
[ "$fsck_rc" -le 1 ] || { echo "SDK image fsck failed: $fsck_rc"; exit 1; }
resize2fs "$work/offline-system.img" 1024M
fsck_rc=0
e2fsck -fy "$work/offline-system.img" || fsck_rc=$?
[ "$fsck_rc" -le 1 ] || { echo "Resized image fsck failed: $fsck_rc"; exit 1; }
e2fsck -fn "$work/offline-system.img"
for spec in 'app/AmazeFileManager.apk:amaze.apk' 'app/PackageInstaller.apk:installer.apk'; do
  source=${spec%%:*}; dest=${spec#*:}
  debugfs -R "dump /$source $work/$dest" "$work/system.img" >/dev/null 2>&1
  test -s "$work/$dest"
done
echo "2a9bc50c6672b1cb6efdfbd9bd9149bf280274e386305663163cc365abd393f3  $work/amaze.apk" | sha256sum -c -
echo "39abdee3fc202e75bba6b3fc1c8d91081d3ff9bfeaa4c4e1297634f827794f5b  $work/installer.apk" | sha256sum -c -
debugfs -R "dump /framework/services.jar $work/stock-services.jar" "$work/system.img" >/dev/null 2>&1
echo "998f7b8558e55fa4d40ea676414cb4bf35f9c9b6f0eae3c81f037186229c403c  $work/stock-services.jar" | sha256sum -c -
# The source is a checked generic SDK image; mutation below affects only its disposable copy.
debugfs -w -R 'rm /framework/services.jar' "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'rm /framework/services.odex' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R "write $work/stock-services.jar /framework/services.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R "write $work/old.apk /priv-app/Navitel-large.apk" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'rm /app/PackageInstaller.apk' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R 'rm /priv-app/PackageInstaller.apk' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R 'rm /app/PackageInstaller.odex' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R 'rm /priv-app/PackageInstaller.odex' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R "write $work/amaze.apk /app/AmazeFileManager.apk" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R "write $work/installer.apk /priv-app/PackageInstaller.apk" "$work/offline-system.img" >/dev/null 2>&1
printf 'u:object_r:system_file:s0\0' > "$work/system-context"
for target in /framework/services.jar /priv-app/Navitel-large.apk /app/AmazeFileManager.apk /priv-app/PackageInstaller.apk; do
  debugfs -w -R "set_inode_field $target mode 0100644" "$work/offline-system.img" >/dev/null 2>&1
  debugfs -w -R "ea_set -f $work/system-context $target security.selinux" "$work/offline-system.img" >/dev/null 2>&1
done
e2fsck -fn "$work/offline-system.img"
debugfs -R "dump /framework/services.jar $work/services-offline-check.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /priv-app/Navitel-large.apk $work/old-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/stock-services.jar" "$work/services-offline-check.jar"
cmp "$work/old.apk" "$work/old-offline-check.apk"
debugfs -R "dump /app/AmazeFileManager.apk $work/amaze-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /priv-app/PackageInstaller.apk $work/installer-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/amaze.apk" "$work/amaze-offline-check.apk"
cmp "$work/installer.apk" "$work/installer-offline-check.apk"
chmod a+r "$work/offline-system.img"
echo 'Offline generic system image fsck clean; stock services and Navitel byte-for-byte verified'

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
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 30 "$adb" shell dmesg 2>/dev/null | grep -iE 'ext4|read.only|error|avc:|denied' | tail -60 || true
    timeout -k 5 30 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'PackageManager|installd|com.navitel|FATAL EXCEPTION' | tail -80 || true
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
    "$work/legacy/tools/emulator" -avd migration_arm -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -partition-size 1024 -system "$work/offline-system.img" -verbose >> "$work/emulator.txt" 2>&1 &
  pid=$!
}
restart_android_runtime() {
  # Restart Android userspace, not the VM: legacy QEMU hangs on adb reboot and
  # SIGTERM. This reinitializes system_server/PackageManager but is not a reboot.
  timeout -k 5 30 "$adb" shell sync
  timeout -k 5 30 "$adb" shell setprop sys.boot_completed 0
  timeout -k 5 30 "$adb" shell stop
  timeout -k 5 30 "$adb" shell start
  boot
}
start_emulator
# sudo's launcher may be root-owned; kill -0 can fail with EPERM while alive.
launcher_running() {
  ps -o stat= -p "$1" | awk '$1 !~ /^Z/ {alive=1} END {exit !alive}'
}
boot() {
  "$adb" wait-for-device &
  local waitpid=$! connected=no
  for i in $(seq 1 60); do
    if ! launcher_running "$pid"; then
      echo 'Emulator exited before adb'
      local emulator_status=0
      wait "$pid" || emulator_status=$?
      echo "Emulator launcher exit: $emulator_status"
      ps -fu emulatorlab || true
      break
    fi
    if ! kill -0 "$waitpid" 2>/dev/null; then wait "$waitpid" && connected=yes; break; fi
    sleep 5
  done
  kill "$waitpid" 2>/dev/null || true
  [ "$connected" = yes ] || { echo 'ADB connection timeout'; return 1; }
  local booted=no
  for i in $(seq 1 100); do
    if [ "$(timeout -k 5 3 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
    launcher_running "$pid" || { echo 'Emulator exited'; exit 1; }
    sleep 3
  done
  [ "$booted" = yes ] || { echo 'Emulator boot timeout'; exit 1; }
}
boot
id=$(timeout -k 5 60 "$adb" shell id | tr -d '\r')
echo "Shell identity: $id"
grep -q 'uid=0' <<< "$id" || { echo 'Root shell unavailable; abort'; exit 1; }
timeout -k 5 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r' > "$work/fingerprint.txt"
test "$(cat "$work/fingerprint.txt")" = 'generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys' || { echo 'Unexpected emulator; abort'; exit 1; }
timeout -k 5 30 "$adb" shell getprop ro.product.cpu.abi | tr -d '\r' > "$work/abi.txt"
echo 'Verify loaded stock services from the OFFLINE generic system image'
timeout -k 10 120 "$adb" pull /system/framework/services.jar "$work/services-check.jar" >/dev/null
cmp "$work/stock-services.jar" "$work/services-check.jar"
server_pid=$(timeout -k 5 30 "$adb" shell ps | tr -d '\r' | awk '$NF == "system_server" && !seen++ {print $2}')
case "$server_pid" in ''|*[!0-9]*) echo 'System server PID missing'; exit 1;; esac
timeout -k 5 30 "$adb" shell "cat /proc/$server_pid/maps" | tr -d '\r' | grep -F 'system@framework@services.jar@classes.dex' > "$work/services-maps.txt"
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /system ' > "$work/mount-system.txt"
grep -E ' /system [^ ]+ ro[, ]' "$work/mount-system.txt" || { echo 'Generic emulator /system unexpectedly writable'; cat "$work/mount-system.txt"; exit 1; }
timeout -k 5 60 "$adb" shell pm path com.android.packageinstaller | tr -d '\r' > "$work/installer-path.txt"
grep -F 'package:/system/priv-app/PackageInstaller.apk' "$work/installer-path.txt"
timeout -k 5 60 "$adb" shell pm path com.amaze.filemanager | tr -d '\r' > "$work/amaze-path.txt"
grep -F 'package:/system/app/AmazeFileManager.apk' "$work/amaze-path.txt"
timeout -k 10 120 "$adb" pull /system/priv-app/PackageInstaller.apk "$work/installer-check.apk" >/dev/null
cmp "$work/installer.apk" "$work/installer-check.apk"
timeout -k 10 120 "$adb" pull /system/app/AmazeFileManager.apk "$work/amaze-check.apk" >/dev/null
cmp "$work/amaze.apk" "$work/amaze-check.apk"
echo "Phase 3b: verify old system APK is unchanged and query package"
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/old-after-restart.apk" >/dev/null
cmp "$work/old.apk" "$work/old-after-restart.apk" || { echo 'Old system file changed'; exit 1; }
path=$(timeout -k 5 60 "$adb" shell pm path com.navitel | tr -d '\r')
echo "Initial package path: $path"
grep -F 'package:/system/priv-app/Navitel-large.apk' <<< "$path" || { echo 'Old system app not registered'; exit 1; }
timeout -k 5 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/old-package.txt"
uid_before=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/old-package.txt" | head -1)
case "$uid_before" in ''|*[!0-9]*) echo 'Initial app UID missing'; exit 1;; esac
timeout -k 5 30 "$adb" shell 'mkdir -p /data/data/com.navitel/files && echo X60_DISPOSABLE_MIGRATION_TEST > /data/data/com.navitel/files/lab-marker.txt'
timeout -k 5 30 "$adb" shell chown "$uid_before:$uid_before" /data/data/com.navitel/files/lab-marker.txt
before_marker=$(timeout -k 5 30 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt | tr -d '\r')
test "$before_marker" = X60_DISPOSABLE_MIGRATION_TEST
# A synthetic, separate SharedPreferences XML; never a license or real app data.
python3 -c 'from tools.check_synthetic_adb_backup import PREFS; import sys; sys.stdout.buffer.write(PREFS)' > "$work/lab-pref.xml"
timeout -k 5 30 "$adb" shell mkdir -p /data/data/com.navitel/shared_prefs
timeout -k 10 300 "$adb" push "$work/lab-pref.xml" /data/data/com.navitel/shared_prefs/x60_lab_probe.xml
timeout -k 5 30 "$adb" shell chown "$uid_before:$uid_before" /data/data/com.navitel/shared_prefs /data/data/com.navitel/shared_prefs/x60_lab_probe.xml
timeout -k 5 30 "$adb" shell cat /data/data/com.navitel/shared_prefs/x60_lab_probe.xml | tr -d '\r' > "$work/pref-before.txt"
cmp "$work/lab-pref.xml" "$work/pref-before.txt" || { echo 'Synthetic preferences were not created intact'; exit 1; }

echo 'Create unrelated synthetic application in disposable ARM emulator'
src=tests/fixtures/no-adb-backup-target
jar="$sdk/platforms/android-19/android.jar"
mkdir -p "$work/canary/classes" "$work/canary/dex"
"$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/canary/unsigned.apk"
find "$src/src" -name '*.java' | sort > "$work/canary/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/canary/classes" @"$work/canary/sources.txt"
find "$work/canary/classes" -name '*.class' > "$work/canary/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/canary/dex" @"$work/canary/classes.txt"
cp "$work/canary/dex/classes.dex" "$work/canary/classes.dex"
(cd "$work/canary" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/canary/unsigned.apk" "$work/canary/aligned.apk"
"$bt/apksigner" sign --key "$work/testkey.pk8" --cert "$work/testkey.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/canary.apk" "$work/canary/aligned.apk"
timeout -k 10 120 "$adb" install "$work/canary.apk" > "$work/canary-install.txt" 2>&1
grep -F Success "$work/canary-install.txt"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupfixture/.MainActivity > "$work/canary-start.txt" 2>&1
ready=no
for i in $(seq 1 60); do
  timeout -k 5 30 "$adb" logcat -d -v brief > "$work/canary-log.txt" 2>&1 || true
  if grep -Fq FIXTURE_READY "$work/canary-log.txt"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Synthetic unrelated app failed to initialize'; cat "$work/canary-log.txt" | tail -60; exit 1; }
timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.backupfixture | tr -d '\r' > "$work/canary-package-before.txt"
canary_uid=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/canary-package-before.txt" | head -1)
case "$canary_uid" in ''|*[!0-9]*) echo 'Canary UID missing'; exit 1;; esac

check_synthetic() {
  local phase=$1
  timeout -k 5 60 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt | tr -d '\r' > "$work/marker-$phase.txt"
  test "$(cat "$work/marker-$phase.txt")" = X60_DISPOSABLE_MIGRATION_TEST
  timeout -k 5 60 "$adb" pull /data/data/com.navitel/shared_prefs/x60_lab_probe.xml "$work/pref-$phase.xml" >/dev/null
  cmp "$work/lab-pref.xml" "$work/pref-$phase.xml"
  timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupfixture/files/lab-marker.txt "$work/canary-marker-$phase.txt" >/dev/null
  timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml "$work/canary-pref-$phase.xml" >/dev/null
  python3 - "$work/canary-marker-$phase.txt" "$work/canary-pref-$phase.xml" <<'PY2'
from pathlib import Path
from tools.check_no_adb_lab_backup import verify_contents
import sys
verify_contents(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes())
PY2
  timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.backupfixture | tr -d '\r' > "$work/canary-package-$phase.txt"
  observed=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/canary-package-$phase.txt" | head -1)
  [ "$canary_uid" = "$observed" ] || { echo 'Canary UID changed'; return 1; }
}
query_package() {
  local phase=$1
  timeout -k 5 60 "$adb" shell pm path com.navitel | tr -d '\r' > "$work/path-$phase.txt"
  timeout -k 5 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/package-$phase.txt"
}
check_synthetic before
timeout -k 5 60 "$adb" pull /data/data/com.navitel/files/lab-marker.txt "$work/navitel-marker-before-raw.txt" >/dev/null
query_package before
echo 'Install and initialize an additional allowBackup=false synthetic app'
mkdir -p "$work/blocked"
"$bt/aapt" package -f -M tests/fixtures/backup-disallowed-target/AndroidManifest.xml -I "$jar" -F "$work/blocked/unsigned.apk"
cp "$work/canary/classes.dex" "$work/blocked/classes.dex"
(cd "$work/blocked" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/blocked/unsigned.apk" "$work/blocked/aligned.apk"
"$bt/apksigner" sign --key "$work/testkey.pk8" --cert "$work/testkey.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/blocked.apk" "$work/blocked/aligned.apk"
timeout -k 10 120 "$adb" install "$work/blocked.apk" > "$work/blocked-install.txt" 2>&1
grep -F Success "$work/blocked-install.txt"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupblocked/ru.lifanx60.backupfixture.MainActivity > "$work/blocked-start.txt" 2>&1
ready=no
for i in $(seq 1 30); do
  timeout -k 5 30 "$adb" logcat -d -v brief > "$work/blocked-log.txt" 2>&1 || true
  if grep -Fq FIXTURE_READY "$work/blocked-log.txt"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Excluded synthetic target not ready'; cat "$work/blocked-log.txt" | tail -60; exit 1; }
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/files/lab-marker.txt "$work/blocked-before-marker.txt" >/dev/null
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/shared_prefs/lab_probe.xml "$work/blocked-before-pref.xml" >/dev/null
python3 - "$work/blocked-before-marker.txt" "$work/blocked-before-pref.xml" <<'PY2'
from pathlib import Path
from tools.check_no_adb_lab_backup import verify_contents
import sys
verify_contents(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes())
print('Excluded synthetic app data present before backup')
PY2
echo 'Build and install emulator-only caller with the generic emulator platform key'
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
for ext in x509.pem pk8; do
  gh api "repos/aosp-mirror/platform_build/contents/target/product/security/platform.$ext?ref=$ref" --jq .content | base64 -d > "$work/platform.$ext"
done
timeout -k 10 120 "$adb" pull /system/framework/framework-res.apk "$work/framework-res.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/framework-res.apk" > "$work/platform-cert.txt"
platformcert=$(openssl x509 -in "$work/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
grep -F "certificate SHA-256 digest: $platformcert" "$work/platform-cert.txt"
src=tests/fixtures/no-adb-navitel-arm-caller
mkdir -p "$work/caller/classes" "$work/caller/dex"
"$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/caller/unsigned.apk"
find "$src/src" -name '*.java' | sort > "$work/caller/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/caller/classes" @"$work/caller/sources.txt"
find "$work/caller/classes" -name '*.class' > "$work/caller/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/caller/dex" @"$work/caller/classes.txt"
cp "$work/caller/dex/classes.dex" "$work/caller/classes.dex"
(cd "$work/caller" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/caller/unsigned.apk" "$work/caller/aligned.apk"
"$bt/apksigner" sign --key "$work/platform.pk8" --cert "$work/platform.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/caller.apk" "$work/caller/aligned.apk"
timeout -k 10 120 "$adb" install "$work/caller.apk" > "$work/caller-install.txt" 2>&1
grep -F Success "$work/caller-install.txt"
timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.backupcallerfixture | tr -d '\r' > "$work/caller-package.txt"
caller_uid=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/caller-package.txt" | head -1)
case "$caller_uid" in ''|*[!0-9]*) echo 'Caller UID missing'; exit 1;; esac
[ "$caller_uid" -ge 10000 ] || { echo 'Unexpected shared UID'; exit 1; }
wait_caller_log() {
  local pattern=$1
  for i in $(seq 1 90); do
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/caller-log.txt" 2>&1 || true
    if grep -Fq "$pattern" "$work/caller-log.txt"; then grep -F "$pattern" "$work/caller-log.txt" | tail -1; return 0; fi
    sleep 2
  done
  echo "Missing expected caller log: $pattern"; return 1
}
confirm_ui() {
  local label=$1 coords x y
  for i in $(seq 1 15); do
    if timeout -k 5 40 "$adb" shell uiautomator dump /sdcard/backup-combined-lab-ui.xml >/dev/null 2>&1 &&
       timeout -k 5 15 "$adb" shell cat /sdcard/backup-combined-lab-ui.xml > "$work/backup-ui.xml"; then
      coords=$(python3 tools/emulator_backup_confirmation.py "$work/backup-ui.xml" "$label" 2>/dev/null || true)
      if [ -n "$coords" ]; then
        read -r x y <<< "$coords"
        timeout -k 5 20 "$adb" shell input tap "$x" "$y"
        echo "Emulator confirmation '$label' tapped at $x,$y"; return 0
      fi
    fi
    sleep 2
  done
  echo "Missing emulator confirmation: $label"; cat "$work/backup-ui.xml" || true; return 1
}
echo 'App-initiated backup of Navitel, one independent target and one allowBackup=false control'
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 20 "$adb" shell input keyevent 82 || true
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupcallerfixture/.MainActivity > "$work/caller-start.txt" 2>&1
wait_caller_log 'BACKUP_PERMISSION=true'
wait_caller_log STARTING_SYNTHETIC_BACKUP
confirm_ui 'Back up my data'
wait_caller_log BACKUP_CALL_RETURNED
if grep -Fq BACKUP_CALL_FAILED "$work/caller-log.txt"; then echo 'Backup exception'; exit 1; fi
timeout -k 5 60 "$adb" pull /sdcard/Android/data/ru.lifanx60.backupcallerfixture/files/synthetic.ab "$work/synthetic.ab" >/dev/null
python3 -m tools.check_multi_navitel_lab_backup "$work/synthetic.ab" > "$work/archive-check.txt"
cat "$work/archive-check.txt"
echo 'Verify original system APK immediately before the negative control'
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-before-negative.apk" >/dev/null
cmp "$work/old.apk" "$work/stock-before-negative.apk"
hostmd5=$(md5sum "$work/old.apk" | awk '{print $1}')
devmd5=$(timeout -k 5 120 "$adb" shell /system/bin/md5 /system/priv-app/Navitel-large.apk | tr -d '\r' | awk '{print $1}')
test "$hostmd5" = "$devmd5" || { echo 'Pre-control device-side MD5 mismatch'; exit 1; }
echo 'Negative control: unmodified candidate must be rejected as a differently signed update'
timeout -k 10 300 "$adb" install -r "$new" > "$work/negative.txt" 2>&1 || true
cat "$work/negative.txt"
grep -E 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|INSTALL_FAILED_SHARED_USER_INCOMPATIBLE|INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES' "$work/negative.txt" || { echo 'Unexpected control result'; exit 1; }
query_package negative
grep -F 'package:/system/priv-app/Navitel-large.apk' "$work/path-negative.txt"
check_synthetic negative
# Locate any read-back anomaly relative to the failed negative control.
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-negative.apk" >/dev/null
if cmp -s "$work/old.apk" "$work/stock-after-negative.apk"; then
  echo 'System APK read-back still matched after negative control'
else
  echo 'System APK read-back differs after negative control, no safety claim'
  sha256sum "$work/old.apk" "$work/stock-after-negative.apk"
  echo 'Host and emulator md5 checks (md5 used only to diagnose transport versus source):'
  md5sum "$work/old.apk" "$work/stock-after-negative.apk"
  timeout -k 5 120 "$adb" shell /system/bin/md5 /system/priv-app/Navitel-large.apk | tr -d '\r' || true
  exit 1
fi

echo 'Emulate file-manager ACTION_VIEW and Android PackageInstaller in disposable emulator'
timeout -k 5 30 "$adb" shell settings put global install_non_market_apps 1
timeout -k 5 30 "$adb" shell settings get global install_non_market_apps | tr -d '\r' | tee "$work/unknown-sources.txt"
allowed=$(tail -1 "$work/unknown-sources.txt")
[ "$allowed" = 1 ] || { echo 'Unknown sources not enabled on emulator'; exit 1; }
timeout -k 5 30 "$adb" shell mkdir -p /sdcard/Download
timeout -k 10 300 "$adb" push "$work/new-resigned.apk" /sdcard/Download/navitel-lab.apk
# Open the actual stock-derived Amaze APK in a fixed virtual directory. Its
# path extra avoids unrelated navigation; we then click the APK in its UI.
timeout -k 5 30 "$adb" shell input keyevent 82 || true
timeout -k 5 60 "$adb" shell am start -n com.amaze.filemanager/.ui.activities.MainActivity --es path /sdcard/Download > "$work/amaze-start.txt" 2>&1
cat "$work/amaze-start.txt"
clicked=no
entered_download=no
for attempt in $(seq 1 30); do
  timeout -k 5 40 "$adb" shell uiautomator dump /sdcard/amaze-lab-ui.xml >/dev/null 2>&1 || { sleep 2; continue; }
  timeout -k 5 15 "$adb" shell cat /sdcard/amaze-lab-ui.xml > "$work/amaze-ui.xml" 2>/dev/null || continue
  timeout -k 5 20 "$adb" shell dumpsys activity activities > "$work/amaze-activities.txt" 2>/dev/null || true
  grep -E 'mResumedActivity.*com.amaze.filemanager' "$work/amaze-activities.txt" >/dev/null || { sleep 2; continue; }
  coords=$(python3 tools/emulator_ui_clickable.py "$work/amaze-ui.xml" navitel-lab.apk 2>/dev/null || true)
  if [ -n "$coords" ]; then
    read -r x y <<< "$coords"; echo "Tap exact APK filename in virtual Amaze at $x,$y"
    timeout -k 5 20 "$adb" shell input tap "$x" "$y"; clicked=yes; break
  fi
  if [ "$entered_download" = no ]; then
    coords=$(python3 tools/emulator_ui_clickable.py "$work/amaze-ui.xml" Download 2>/dev/null || true)
    if [ -n "$coords" ]; then
      read -r x y <<< "$coords"; echo "Open virtual Download folder at $x,$y"
      timeout -k 5 20 "$adb" shell input tap "$x" "$y"; entered_download=yes; sleep 2; continue
    fi
  fi
  sleep 3
done
[ "$clicked" = yes ] || { echo 'Could not locate exact APK in virtual Amaze'; cat "$work/amaze-ui.xml" || true; cat "$work/amaze-activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' || true; exit 1; }
installed=no
for attempt in $(seq 1 30); do
  timeout -k 5 40 "$adb" shell uiautomator dump /sdcard/navitel-lab-ui.xml > /dev/null 2>&1 || { sleep 2; continue; }
  timeout -k 5 15 "$adb" shell cat /sdcard/navitel-lab-ui.xml > "$work/installer-ui.xml" 2>/dev/null || continue
  timeout -k 5 20 "$adb" shell dumpsys activity activities > "$work/installer-activities.txt" 2>/dev/null || true
  # A broadcast-triggered Navitel crash may obscure the installer's result.
  # Dismiss only the exact crash dialog on this disposable emulator; record it.
  if grep -Fq 'Unfortunately, Navitel has stopped.' "$work/installer-ui.xml"; then
    echo 'Navitel crash dialog observed during installation on the emulator'
    cp "$work/installer-ui.xml" "$work/navitel-crash-dialog.xml"
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/navitel-crash-log.txt" 2>&1 || true
    coords=$(python3 tools/emulator_ui_clickable.py "$work/installer-ui.xml" 'OK' 2>/dev/null || true)
    [ -n "$coords" ] || { echo 'Cannot uniquely dismiss Navitel crash dialog'; exit 1; }
    read -r x y <<< "$coords"; timeout -k 5 20 "$adb" shell input tap "$x" "$y"; sleep 2; continue
  fi
  # Amaze first asks whether to view or install the APK. Only act on its
  # explicit package-installer dialog, never arbitrary Amaze buttons.
  if grep -E 'mResumedActivity.*com.amaze.filemanager' "$work/installer-activities.txt" >/dev/null &&
     grep -Fq 'This is a package installer.' "$work/installer-ui.xml"; then
    coords=$(python3 tools/emulator_backup_confirmation.py "$work/installer-ui.xml" 'Install' 2>/dev/null || true)
    if [ -n "$coords" ]; then
      read -r x y <<< "$coords"; echo "Tap virtual Amaze Install at $x,$y"
      timeout -k 5 20 "$adb" shell input tap "$x" "$y"; sleep 3; continue
    fi
  fi
  # Otherwise only tap buttons when Android PackageInstaller is foreground.
  grep -E 'mResumedActivity.*com.android.packageinstaller' "$work/installer-activities.txt" >/dev/null || { sleep 2; continue; }
  if grep -iq 'App installed' "$work/installer-ui.xml"; then installed=yes; break; fi
  coords=$(python3 tools/emulator_backup_confirmation.py "$work/installer-ui.xml" 'Install' 2>/dev/null || true)
  if [ -n "$coords" ]; then
    read -r x y <<< "$coords"; echo "Tap virtual Install at $x,$y"; timeout -k 5 20 "$adb" shell input tap "$x" "$y"; sleep 4; continue
  fi
  coords=$(python3 tools/emulator_backup_confirmation.py "$work/installer-ui.xml" 'Next' 2>/dev/null || true)
  if [ -n "$coords" ]; then
    read -r x y <<< "$coords"; echo "Tap virtual Next at $x,$y"; timeout -k 5 20 "$adb" shell input tap "$x" "$y"; sleep 2; continue
  fi
  sleep 3
done
[ "$installed" = yes ] || { echo 'Virtual installer did not report App installed'; cat "$work/installer-ui.xml" || true; cat "$work/installer-activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' || true; exit 1; }
echo 'Virtual installer confirmed App installed'
query_package after
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-after.txt"
grep -F 'versionCode=360622024' "$work/package-after.txt"
uid_after=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-after.txt" | head -1)
test "$uid_before" = "$uid_after" || { echo 'Unexpected UID change'; exit 1; }
check_synthetic after
# Verify the existing emulator system APK is unchanged rather than assuming it.
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-update.apk" >/dev/null
if ! cmp "$work/old.apk" "$work/stock-after-update.apk"; then
  python3 - "$work/old.apk" "$work/stock-after-update.apk" <<'PY'
import hashlib, sys
from pathlib import Path
old, new = (Path(p).read_bytes() for p in sys.argv[1:])
print('Initial file bytes/hash:', len(old), hashlib.sha256(old).hexdigest())
print('Read-back file bytes/hash:', len(new), hashlib.sha256(new).hexdigest())
first = next((i for i, (a, b) in enumerate(zip(old, new)) if a != b), None)
print('First differing offset:', first)
if first is not None:
    print('Initial bytes:', old[first:first+32].hex())
    print('Read-back bytes:', new[first:first+32].hex())
PY
  echo 'System read-back mismatch; abandoning this experiment, no safety claim.'
  exit 1
fi

echo 'Restart Android userspace, not the emulator, and repeat checks'
restart_android_runtime
query_package restart
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-restart.txt"
grep -F 'versionCode=360622024' "$work/package-restart.txt"
uid_restart=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-restart.txt" | head -1)
test "$uid_before" = "$uid_restart"
check_synthetic restart
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-restart.apk" >/dev/null
cmp "$work/old.apk" "$work/stock-after-restart.apk"
timeout -k 10 120 "$adb" pull /system/framework/services.jar "$work/services-after-restart.jar" >/dev/null
cmp "$work/stock-services.jar" "$work/services-after-restart.jar"
server_pid=$(timeout -k 5 30 "$adb" shell ps | tr -d '\r' | awk '$NF == "system_server" && !seen++ {print $2}')
case "$server_pid" in ''|*[!0-9]*) echo 'System server PID missing after restart'; exit 1;; esac
timeout -k 5 30 "$adb" shell "cat /proc/$server_pid/maps" | tr -d '\r' | grep -F 'system@framework@services.jar@classes.dex' > "$work/services-maps-restart.txt"

echo 'Launch new activity with empty virtual SD and isolated network; no license or account'
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n com.navitel/com.navitel.app.MainActivity > "$work/start.txt" 2>&1 || true
sleep 12
timeout -k 5 60 "$adb" shell dumpsys activity activities > "$work/activities.txt" 2>&1 || true
timeout -k 5 60 "$adb" logcat -d -v brief > "$work/app-log.txt" 2>&1 || true
check_synthetic launch

echo 'LAB ONLY: sync, terminate the disposable ARM VM and start the SAME AVD again'
# Legacy QEMU adb reboot can hang. This cold start is deliberately a host-side
# stop/start of the *emulator*, not real hibernation or a graceful car shutdown.
timeout -k 5 30 "$adb" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r' > "$work/boot-id-before.txt"
grep -E '^[0-9a-f-]{36}$' "$work/boot-id-before.txt"
timeout -k 5 60 "$adb" shell sync
sudo pkill -KILL -u emulatorlab || true
timeout -k 5 60 "$adb" wait-for-disconnect
wait "$pid" 2>/dev/null || true
start_emulator
boot
newid=$(timeout -k 5 30 "$adb" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
[[ "$newid" =~ ^[0-9a-f-]{36}$ ]] || { echo 'Invalid boot ID after cold start'; exit 1; }
[ "$newid" != "$(cat "$work/boot-id-before.txt")" ] || { echo 'Kernel boot ID did not change'; exit 1; }
echo "New boot ID: $newid"
timeout -k 5 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r' | grep -Fx 'generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys'
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /system ' > "$work/mount-system-coldboot.txt"
grep -E ' /system [^ ]+ ro[, ]' "$work/mount-system-coldboot.txt"
query_package coldboot
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-coldboot.txt"
grep -F 'versionCode=360622024' "$work/package-coldboot.txt"
uid_coldboot=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-coldboot.txt" | head -1)
[ "$uid_before" = "$uid_coldboot" ] || { echo 'Navitel UID changed after cold start'; exit 1; }
check_synthetic coldboot
cmp "$work/canary-marker-before.txt" "$work/canary-marker-coldboot.txt"
cmp "$work/canary-pref-before.xml" "$work/canary-pref-coldboot.xml"
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-coldboot.apk" >/dev/null
cmp "$work/old.apk" "$work/stock-after-coldboot.apk"
timeout -k 10 120 "$adb" pull /system/framework/services.jar "$work/services-after-coldboot.jar" >/dev/null
cmp "$work/stock-services.jar" "$work/services-after-coldboot.jar"
server_pid=$(timeout -k 5 30 "$adb" shell ps | tr -d '\r' | awk '$NF == "system_server" && !seen++ {print $2}')
case "$server_pid" in ''|*[!0-9]*) echo 'System server PID missing after cold boot'; exit 1;; esac
timeout -k 5 30 "$adb" shell "cat /proc/$server_pid/maps" | tr -d '\r' | grep -F 'system@framework@services.jar@classes.dex' > "$work/services-maps-coldboot.txt"
timeout -k 5 60 "$adb" pull /sdcard/Android/data/ru.lifanx60.backupcallerfixture/files/synthetic.ab "$work/synthetic-after-coldboot.ab" >/dev/null
cmp "$work/synthetic.ab" "$work/synthetic-after-coldboot.ab"
echo 'Synthetic archive survived emulator cold start byte-for-byte'
echo 'Destructive restore test in DISPOSABLE EMULATOR only, after update and full reboot'
# Remove only the two synthetic files; do not attempt on a head unit.
timeout -k 5 30 "$adb" shell rm /data/data/com.navitel/files/lab-marker.txt /data/data/com.navitel/shared_prefs/x60_lab_probe.xml /data/data/ru.lifanx60.backupfixture/files/lab-marker.txt /data/data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml
timeout -k 5 30 "$adb" shell 'if [ -e /data/data/com.navitel/files/lab-marker.txt ] || [ -e /data/data/com.navitel/shared_prefs/x60_lab_probe.xml ] || [ -e /data/data/ru.lifanx60.backupfixture/files/lab-marker.txt ] || [ -e /data/data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml ]; then echo SYNTHETIC_PRESENT; else echo SYNTHETIC_ABSENT; fi' | tr -d '\r' > "$work/deleted.txt"
grep -Fx SYNTHETIC_ABSENT "$work/deleted.txt"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 20 "$adb" shell input keyevent 82 || true
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupcallerfixture/.RestoreActivity > "$work/restore-start.txt" 2>&1
wait_caller_log STARTING_SYNTHETIC_RESTORE
confirm_ui 'Restore my data'
wait_caller_log RESTORE_CALL_RETURNED
if grep -Fq RESTORE_CALL_FAILED "$work/caller-log.txt"; then echo 'Restore exception'; exit 1; fi
check_synthetic restored
timeout -k 5 60 "$adb" pull /data/data/com.navitel/files/lab-marker.txt "$work/navitel-marker-restored-raw.txt" >/dev/null
cmp "$work/navitel-marker-before-raw.txt" "$work/navitel-marker-restored-raw.txt"
cmp "$work/canary-marker-coldboot.txt" "$work/canary-marker-restored.txt"
cmp "$work/canary-pref-coldboot.xml" "$work/canary-pref-restored.xml"
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/files/lab-marker.txt "$work/blocked-after-marker.txt" >/dev/null
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/shared_prefs/lab_probe.xml "$work/blocked-after-pref.xml" >/dev/null
cmp "$work/blocked-before-marker.txt" "$work/blocked-after-marker.txt"
cmp "$work/blocked-before-pref.xml" "$work/blocked-after-pref.xml"
query_package restored
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-restored.txt"
grep -F 'versionCode=360622024' "$work/package-restored.txt"
uid_restored=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-restored.txt" | head -1)
test "$uid_before" = "$uid_restored" || { echo 'UID changed after restore'; exit 1; }
{
  echo '# App-initiated multi-package synthetic backup and Navitel update on disposable Android 4.4.2 ARM'
  echo 'Generic ARM emulator with stock-derived services.jar preloaded offline, not the head unit; host emulator network blocked.'
  echo 'Disposable generic ARM system image built and fsck-checked offline. Stock Navitel and services.jar matched byte-for-byte; services dex mapped by system_server.'
  echo 'No real maps, license, accounts, user data or SD; no APKs published. Virtual SD initially empty.'
  echo 'ADB prepared and observed the disposable emulator and tapped UI; update installed by stock-derived Amaze and PackageInstaller. Physical GU and USB were not tested.'
  echo 'Stock-derived Amaze and installer were preloaded offline and matched byte-for-byte.'
  echo 'Initial stock-derived Navitel certificate equals the verified AOSP testkey certificate:'
  echo "$keycert"
  echo 'Candidate re-signed in disposable CI only; not an installation recommendation.'
  cat "$work/compare.txt"
  echo 'Negative control: original differently signed candidate rejected; installer result:'
  grep -E 'Failure \[' "$work/negative.txt" | tr -d '\r'
  echo 'Matching certificate candidate installed through Amaze/PackageInstaller UI as data update; original emulator system APK unchanged: yes.'
  echo 'Emulator system mounted read-only from initial boot through update (no system write or remount during emulator run):'; cat "$work/mount-system.txt"
  echo "UID before/after/userspace restart/cold start: $uid_before/$uid_after/$uid_restart/$uid_coldboot"
  echo '## Package paths and selected version'
  cat "$work/path-before.txt" "$work/path-after.txt" "$work/path-restart.txt"
  grep -E 'versionCode=|versionName=|codePath=' "$work/package-restart.txt" | head -10
  echo 'Synthetic marker and preferences for Navitel and an unrelated test app, including both UIDs, survived install, userspace restart, launch attempt, and host-triggered virtual ARM cold start: yes.'
  echo 'App with generic emulator platform signature and ordinary UID called backup/restore service itself; confirmations were tapped on emulator UI.'
  echo 'Backup archive on emulator virtual external storage survived ARM cold start byte-for-byte.'
  echo '## Multi-package synthetic archive before update'; cat "$work/archive-check.txt"
  echo 'After cold start, four synthetic files in the two included packages were deliberately removed on the emulator and then restored byte-for-byte.'
  echo 'The allowBackup=false synthetic package was absent from archive; its files were not deleted and still matched.'
  echo 'Restore can clear data and this fixture must not be used on a real device.'
  echo '## Emulator crash dialog while installing'
  if [ -e "$work/navitel-crash-log.txt" ]; then echo 'Navitel stopped dialog observed'; grep -A 22 -F 'Process: com.navitel' "$work/navitel-crash-log.txt" | head -46 || true; else echo 'No Navitel crash dialog observed during installer polling; other failures may still occur'; fi
  echo '## Launch attempt (no activation asserted)'
  tr -d '\r' < "$work/start.txt"
  tr -d '\r' < "$work/activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' | head -5 || true
  tr -d '\r' < "$work/app-log.txt" | grep -iE 'FATAL EXCEPTION|Fatal signal|com.navitel.*(crash|died)' | tail -10 || true
  echo 'Kernel boot ID changed after host stopped and restarted the same disposable emulator. This is a virtual cold start after sync, not real-device hibernate or graceful car shutdown.'
  echo 'Real device app behavior, USB, rollback, settings and all data preservation remain unverified.'
} > reports/navitel-arm-combined-backup-lab.txt

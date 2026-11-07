#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never run against a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
strategy=${LAB_COPY_STRATEGY:-archive}
case "$strategy" in archive|stream) ;; *) echo 'Unknown lab copy strategy'; exit 1;; esac
if [ "$strategy" = stream ]; then
  log_name=navitel-arm-stream-lab.log; report_name=navitel-arm-stream-lab.txt
else
  log_name=navitel-arm-tarboot-lab.log; report_name=navitel-arm-tarboot-lab.txt
fi
exec > >(tee "$RUNNER_TEMP/$log_name") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-arm-tarboot-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip android-sdk-libsparse-utils file qemu-user-static

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
debugfs -R "dump /bin/bin/busybox $work/stock-busybox" "$work/system.img" >/dev/null 2>&1
echo "b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613  $work/stock-busybox" | sha256sum -c -
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
# BusyBox selects its applet using argv[0], so use the literal busybox name.
debugfs -R 'stat /bin/busybox' "$work/offline-system.img" 2>&1 | grep -F 'File not found'
debugfs -w -R "write $work/stock-busybox /bin/busybox" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'set_inode_field /bin/busybox mode 0100755' "$work/offline-system.img" >/dev/null 2>&1
printf 'u:object_r:system_file:s0\0' > "$work/system-context"
for target in /framework/services.jar /priv-app/Navitel-large.apk /app/AmazeFileManager.apk /priv-app/PackageInstaller.apk; do
  debugfs -w -R "set_inode_field $target mode 0100644" "$work/offline-system.img" >/dev/null 2>&1
  debugfs -w -R "ea_set -f $work/system-context $target security.selinux" "$work/offline-system.img" >/dev/null 2>&1
done
debugfs -w -R "ea_set -f $work/system-context /bin/busybox security.selinux" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R 'stat /bin/busybox' "$work/offline-system.img" 2>&1 | grep -E 'Mode:[[:space:]]+0755'
e2fsck -fn "$work/offline-system.img"
debugfs -R "dump /framework/services.jar $work/services-offline-check.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /priv-app/Navitel-large.apk $work/old-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/stock-services.jar" "$work/services-offline-check.jar"
cmp "$work/old.apk" "$work/old-offline-check.apk"
debugfs -R "dump /app/AmazeFileManager.apk $work/amaze-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /priv-app/PackageInstaller.apk $work/installer-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/amaze.apk" "$work/amaze-offline-check.apk"
cmp "$work/installer.apk" "$work/installer-offline-check.apk"
debugfs -R "dump /bin/busybox $work/busybox-offline-check" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/stock-busybox" "$work/busybox-offline-check"
chmod a+r "$work/offline-system.img"
echo 'Offline generic system image fsck clean; stock services and Navitel byte-for-byte verified'

# The original system app could have BOOT_COMPLETED receivers. Block ALL
# emulator-owned external network traffic before its first boot, including IPv6.
# Local loopback remains available for adb. This is a disposable hosted runner.
sudo useradd --system --create-home --user-group emulatorlab
emu_uid=$(id -u emulatorlab)
sudo chown -R emulatorlab:emulatorlab "$ANDROID_AVD_HOME"
pid=''; blocked4=no; blocked6=no
if [ "$strategy" = stream ]; then source tools/stock_mke2fs_stream_lab.sh; fi
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
  for m in "$work/copy-stream-small" "$work/copy-stream-plus" "$work/copy-extra-dest" "$work/copy-dest" "$work/copy-source"; do
    if mountpoint -q "$m"; then sudo umount "$m" || echo "Cannot unmount isolated lab path: $m"; fi
  done
  if [ "$strategy" = stream ]; then cleanup_stock_formatter; fi
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
data_args=()
start_emulator() {
  sudo -u emulatorlab env HOME=/home/emulatorlab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
    "$work/legacy/tools/emulator" -avd migration_arm -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -partition-size 1024 -system "$work/offline-system.img" "${data_args[@]}" -verbose >> "$work/emulator.txt" 2>&1 &
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
measure_storage() {
  local phase=$1
  echo "Synthetic emulator /data allocated sizes: $phase"
  timeout -k 10 240 "$adb" shell 'BB=/system/bin/busybox; for p in /data /data/app /data/app-lib /data/dalvik-cache /data/data/com.navitel /data/app/com.navitel-*.apk /data/app-lib/com.navitel-* /data/dalvik-cache/*com.navitel*; do if [ -e "$p" ]; then "$BB" du -sk "$p" || exit 1; fi; done; echo X60_SIZE_DONE' | tr -d '\r' > "$work/du-$phase.txt"
  cat "$work/du-$phase.txt"
  grep -E '^[0-9]+[[:space:]]+/data$' "$work/du-$phase.txt"
  grep -Fx X60_SIZE_DONE "$work/du-$phase.txt"
}
timeout -k 10 120 "$adb" pull /system/bin/busybox "$work/busybox-device-check" >/dev/null
cmp "$work/stock-busybox" "$work/busybox-device-check"
measure_storage before
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
  # A stale Amaze XML can race with the activity transition. Require the dump
  # itself to belong to PackageInstaller as well as the resumed activity.
  grep -E 'mResumedActivity.*com.android.packageinstaller' "$work/installer-activities.txt" >/dev/null || { sleep 2; continue; }
  grep -Fq 'package="com.android.packageinstaller"' "$work/installer-ui.xml" || { sleep 3; continue; }
  if grep -Fq 'text="Your location"' "$work/installer-ui.xml" && grep -Fq 'id/alertTitle' "$work/installer-ui.xml"; then
    echo 'Dismiss emulator permission-detail dialog before continuing install'
    timeout -k 5 20 "$adb" shell input keyevent 4; sleep 2; continue
  fi
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
measure_storage after
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
measure_storage coldboot
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

echo 'LAB ONLY: stop ARM emulator and inspect a copy of its synthetic userdata image'
timeout -k 5 60 "$adb" shell sync
sudo pkill -KILL -u emulatorlab || true
timeout -k 5 60 "$adb" wait-for-disconnect
wait "$pid" 2>/dev/null || true
userdata="$ANDROID_AVD_HOME/migration_arm.avd/userdata-qemu.img"
test -f "$userdata" && [ ! -L "$userdata" ]
sudo file "$userdata" | tee "$work/userdata-file.txt"
# Never repair the running AVD or any device. Copy the disposable regular file,
# repair that copy offline if needed, and mount the copy read-only.
sudo cp --sparse=always "$userdata" "$work/userdata-offline.img"
sudo chown "$(id -u):$(id -g)" "$work/userdata-offline.img"
test -f "$work/userdata-offline.img" && [ ! -L "$work/userdata-offline.img" ]
fsck_rc=0
e2fsck -fy "$work/userdata-offline.img" > "$work/userdata-fsck.txt" 2>&1 || fsck_rc=$?
[ "$fsck_rc" -le 1 ] || { cat "$work/userdata-fsck.txt"; echo "Offline fsck failed: $fsck_rc"; exit 1; }
e2fsck -fn "$work/userdata-offline.img" > "$work/userdata-fsck-check.txt" 2>&1
mkdir "$work/copy-source" "$work/copy-dest" "$work/tar-image"
sudo mount -t ext4 -o loop,ro "$work/userdata-offline.img" "$work/copy-source"
[ "$(findmnt -n -o FSTYPE --target "$work/copy-source")" = ext4 ]
sudo test -f "$work/copy-source/system/packages.xml"
sudo test -f "$work/copy-source/app/com.navitel-1.apk"
# Model the 512 MiB value in the stock updater, not the actual GU p5.
test ! -e "$work/synthetic-p5.img" && test ! -L "$work/synthetic-p5.img"
truncate -s 512M "$work/synthetic-p5.img"
test -f "$work/synthetic-p5.img" && [ ! -L "$work/synthetic-p5.img" ]
if [ "$strategy" = stream ]; then
  prepare_stock_formatter
  format_stock_image "$work/synthetic-p5.img" primary
else
  # Old Android kernels may not support modern host ext4 features.
  sudo mkfs.ext4 -q -F -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$work/synthetic-p5.img"
fi
sudo mount -t ext4 -o loop "$work/synthetic-p5.img" "$work/copy-dest"
[ "$(findmnt -n -o FSTYPE --target "$work/copy-dest")" = ext4 ]
sudo chown "$(id -u):$(id -g)" "$work/copy-dest"
cp /usr/bin/qemu-arm-static "$work/tar-image/qemu-arm-static"
cp "$work/stock-busybox" "$work/tar-image/busybox"
chmod 0755 "$work/tar-image/"{qemu-arm-static,busybox}
printf 'FROM scratch\nCOPY busybox /busybox\nCOPY qemu-arm-static /qemu-arm-static\n' > "$work/tar-image/Dockerfile"
docker build -q -t x60-disposable-arm-copy "$work/tar-image"
lab_source="$work/copy-source"; lab_dest="$work/copy-dest"
run_lab_tar() {
  docker run -i --rm --network none --read-only --cap-drop ALL --cap-add CHOWN \
    --cap-add DAC_OVERRIDE --cap-add FOWNER --security-opt no-new-privileges \
    --memory 256m --pids-limit 32 \
    --mount "type=bind,source=$lab_source,target=/fixture/source,readonly" \
    --mount "type=bind,source=$lab_dest,target=/fixture/dest" \
    --workdir "$1" x60-disposable-arm-copy /qemu-arm-static /busybox tar "${@:2}"
}
create_rc=0; extract_rc=0
if [ "$strategy" = stream ]; then
  # Independent QEMU/BusyBox producer and consumer connected by a pipe; no
  # archive saved on the target. Capture BOTH exits rather than the last only.
  set +e
  run_lab_tar /fixture/source -cf - ./. 2> "$work/copy-create.log" | run_lab_tar /fixture/dest -xvf - > "$work/copy-extract.log" 2>&1
  pipe_rc=("${PIPESTATUS[@]}")
  set -e
  create_rc=${pipe_rc[0]}; extract_rc=${pipe_rc[1]}
  sudo test ! -e "$work/copy-dest/data.tar" || { echo 'Unexpected target archive'; exit 1; }
else
  run_lab_tar /fixture/source -cf /fixture/dest/data.tar ./. > "$work/copy-create.log" 2>&1 || create_rc=$?
  [ "$create_rc" = 0 ] || { echo "Archive failed: $create_rc"; tail -50 "$work/copy-create.log"; exit 1; }
  run_lab_tar /fixture/dest -xvf /fixture/dest/data.tar > "$work/copy-extract.log" 2>&1 || extract_rc=$?
fi
[ "$create_rc" = 0 ] && [ "$extract_rc" = 0 ] || { echo "Copy producer/consumer failed: $create_rc/$extract_rc"; tail -50 "$work/copy-create.log" "$work/copy-extract.log"; exit 1; }
for p in system/packages.xml app/com.navitel-1.apk data/com.navitel/files/lab-marker.txt data/com.navitel/shared_prefs/x60_lab_probe.xml data/ru.lifanx60.backupfixture/files/lab-marker.txt data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml; do
  sudo cmp "$work/copy-source/$p" "$work/copy-dest/$p" || { echo "Selected synthetic file mismatch: $p"; exit 1; }
  source_meta=$(sudo stat -c '%u:%g %a' "$work/copy-source/$p")
  dest_meta=$(sudo stat -c '%u:%g %a' "$work/copy-dest/$p")
  [ "$source_meta" = "$dest_meta" ] || { echo "Selected file metadata mismatch: $p"; exit 1; }
  echo "Synthetic $p content, uid, gid and mode match: $source_meta"
done > "$work/copy-checks.txt"
sudo du -sk "$work/copy-source" "$work/copy-dest" > "$work/copy-sizes.txt"
if [ "$strategy" = archive ]; then sudo du -sk "$work/copy-dest/data.tar" >> "$work/copy-sizes.txt"; fi
df -k "$work/copy-dest" > "$work/copy-df.txt"
python3 - "$work/copy-dest" <<'PY2' > "$work/copy-statvfs.txt"
import os, sys
s = os.statvfs(sys.argv[1])
print('Filesystem blocks free including reserved (KiB):', s.f_bfree * s.f_frsize // 1024)
print('Filesystem blocks available to unprivileged users (KiB):', s.f_bavail * s.f_frsize // 1024)
PY2
# Negative control: rebuild an isolated source from the archived synthetic AVD
# snapshot, add one fixed synthetic 32 MiB file, then repeat on a fresh 512 MiB
# image. This does not change the original emulator image or the first result.
mkdir "$work/copy-plus" "$work/copy-extra-dest"
if [ "$strategy" = stream ]; then
  lab_source="$work/copy-source"; lab_dest="$work/copy-plus"
  set +e
  run_lab_tar /fixture/source -cf - ./. 2> "$work/plus-source-create.log" | run_lab_tar /fixture/dest -xvf - > "$work/plus-source.log" 2>&1
  pipe_rc=("${PIPESTATUS[@]}")
  set -e
  [ "${pipe_rc[0]}" = 0 ] && [ "${pipe_rc[1]}" = 0 ] || { echo 'Plus-source stream failed'; exit 1; }
else
  lab_source="$work/copy-dest"; lab_dest="$work/copy-plus"
  run_lab_tar /fixture/dest -xvf /fixture/source/data.tar > "$work/plus-source.log" 2>&1
fi
sudo mkdir "$work/copy-plus/x60-synthetic-extra"
sudo dd if=/dev/zero of="$work/copy-plus/x60-synthetic-extra/extra.bin" bs=1M count=32 status=none
test ! -e "$work/synthetic-p5-plus.img" && test ! -L "$work/synthetic-p5-plus.img"
truncate -s 512M "$work/synthetic-p5-plus.img"
test -f "$work/synthetic-p5-plus.img" && [ ! -L "$work/synthetic-p5-plus.img" ]
if [ "$strategy" = stream ]; then
  format_stock_image "$work/synthetic-p5-plus.img" plus
else
  sudo mkfs.ext4 -q -F "$work/synthetic-p5-plus.img"
fi
sudo mount -t ext4 -o loop "$work/synthetic-p5-plus.img" "$work/copy-extra-dest"
[ "$(findmnt -n -o FSTYPE --target "$work/copy-extra-dest")" = ext4 ]
sudo chown "$(id -u):$(id -g)" "$work/copy-extra-dest"
lab_source="$work/copy-plus"; lab_dest="$work/copy-extra-dest"
plus_create_rc=0
run_lab_tar /fixture/source -cf /fixture/dest/data.tar ./. > "$work/plus-create.log" 2>&1 || plus_create_rc=$?
[ "$plus_create_rc" = 0 ] || { echo "Unexpected extra-fixture create failure: $plus_create_rc"; tail -15 "$work/plus-create.log"; exit 1; }
plus_extract_rc=0
run_lab_tar /fixture/dest -xvf /fixture/dest/data.tar > "$work/plus-extract.log" 2>&1 || plus_extract_rc=$?
[ "$plus_extract_rc" -ne 0 ] || { echo 'Expected insufficient space with added fixture not observed'; exit 1; }
grep -F 'No space left on device' "$work/plus-extract.log" > "$work/plus-error.txt"

if [ "$strategy" = stream ]; then
  # Positive contrast: stream the exact same +32 MiB source to a fresh 512 MiB
  # target. Both targets use the same stock-derived formatter; no archive is
  # saved on the target. This does not change the baseline image to be booted.
  mkdir "$work/copy-stream-plus" "$work/copy-stream-small"
  test ! -e "$work/synthetic-p5-stream-plus.img" && test ! -L "$work/synthetic-p5-stream-plus.img"
  truncate -s 512M "$work/synthetic-p5-stream-plus.img"
  format_stock_image "$work/synthetic-p5-stream-plus.img" stream-plus
  sudo mount -t ext4 -o loop "$work/synthetic-p5-stream-plus.img" "$work/copy-stream-plus"
  [ "$(findmnt -n -o FSTYPE --target "$work/copy-stream-plus")" = ext4 ]
  sudo chown "$(id -u):$(id -g)" "$work/copy-stream-plus"
  lab_source="$work/copy-plus"; lab_dest="$work/copy-stream-plus"
  set +e
  run_lab_tar /fixture/source -cf - ./. 2> "$work/stream-plus-create.log" | run_lab_tar /fixture/dest -xvf - > "$work/stream-plus-extract.log" 2>&1
  plus_stream_rc=("${PIPESTATUS[@]}")
  set -e
  [ "${plus_stream_rc[0]}" = 0 ] && [ "${plus_stream_rc[1]}" = 0 ] || { echo 'Stream +32 MiB copy failed'; tail -30 "$work/stream-plus-create.log" "$work/stream-plus-extract.log"; exit 1; }
  sudo test ! -e "$work/copy-stream-plus/data.tar"
  for p in system/packages.xml app/com.navitel-1.apk data/com.navitel/files/lab-marker.txt data/com.navitel/shared_prefs/x60_lab_probe.xml data/ru.lifanx60.backupfixture/files/lab-marker.txt data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml x60-synthetic-extra/extra.bin; do
    sudo cmp "$work/copy-plus/$p" "$work/copy-stream-plus/$p" || { echo "Stream +32 MiB mismatch: $p"; exit 1; }
    [ "$(sudo stat -c '%u:%g %a' "$work/copy-plus/$p")" = "$(sudo stat -c '%u:%g %a' "$work/copy-stream-plus/$p")" ] || { echo "Stream +32 MiB metadata mismatch: $p"; exit 1; }
    echo "MATCH $p content uid gid mode"
  done > "$work/stream-plus-checks.txt"
  python3 - "$work/copy-stream-plus" <<'PY2' > "$work/stream-plus-statvfs.txt"
import os, sys
s = os.statvfs(sys.argv[1])
print('Blocks free including reserved (KiB):', s.f_bfree * s.f_frsize // 1024)
print('Blocks available to unprivileged users (KiB):', s.f_bavail * s.f_frsize // 1024)
PY2
  sudo umount "$work/copy-stream-plus"
  e2fsck -fn "$work/synthetic-p5-stream-plus.img" > "$work/stream-plus-fsck.txt" 2>&1

  # Explicit failure control: a fresh, stock-formatted 64 MiB target is too
  # small. Capture both pipeline exits, and require a real write-space error.
  test ! -e "$work/synthetic-p5-stream-small.img" && test ! -L "$work/synthetic-p5-stream-small.img"
  truncate -s 64M "$work/synthetic-p5-stream-small.img"
  format_stock_image "$work/synthetic-p5-stream-small.img" stream-small
  sudo mount -t ext4 -o loop "$work/synthetic-p5-stream-small.img" "$work/copy-stream-small"
  [ "$(findmnt -n -o FSTYPE --target "$work/copy-stream-small")" = ext4 ]
  sudo chown "$(id -u):$(id -g)" "$work/copy-stream-small"
  lab_dest="$work/copy-stream-small"
  set +e
  run_lab_tar /fixture/source -cf - ./. 2> "$work/stream-small-create.log" | run_lab_tar /fixture/dest -xvf - > "$work/stream-small-extract.log" 2>&1
  small_stream_rc=("${PIPESTATUS[@]}")
  set -e
  [ "${small_stream_rc[1]}" != 0 ] || { echo 'Small-target stream was not rejected'; exit 1; }
  grep -Fq 'No space left on device' "$work/stream-small-extract.log" || { echo 'Small-target failure is not ENOSPC'; exit 1; }
  sudo umount "$work/copy-stream-small"
  e2fsck -fn "$work/synthetic-p5-stream-small.img" > "$work/stream-small-fsck.txt" 2>&1
fi

echo 'LAB ONLY: start same disposable ARM AVD from the extracted synthetic image'
# A fixed synthetic witness exists only on the extracted image. It proves
# the emulator did not silently fall back to the original AVD userdata.
if [ "$strategy" = archive ]; then sudo sha256sum "$work/copy-dest/data.tar" | awk '{print $1}' > "$work/tarboot-archive-sha256.txt"; fi
witness_rel='data/ru.lifanx60.backupfixture/files/x60-copied-image-witness'
sudo test ! -e "$work/copy-source/$witness_rel"
printf 'X60_COPIED_IMAGE_ONLY\n' > "$work/tarboot-witness.txt"
sudo install -m 0600 "$work/tarboot-witness.txt" "$work/copy-dest/$witness_rel"
witness_owner=$(sudo stat -c '%u:%g' "$work/copy-dest/data/ru.lifanx60.backupfixture/files/lab-marker.txt")
sudo chown "$witness_owner" "$work/copy-dest/$witness_rel"
sudo umount "$work/copy-dest"
e2fsck -fn "$work/synthetic-p5.img" > "$work/tarboot-fsck.txt" 2>&1
dumpe2fs -h "$work/synthetic-p5.img" 2>/dev/null | grep -E '^Filesystem UUID:|^Filesystem features:|^Block count:|^Block size:' > "$work/tarboot-super-before.txt"
# The legacy emulator expanded the shorter backing file in an earlier run.
# Pad it to the configured 1 GiB without resizing ext4; the pre-boot
# filesystem remains 512 MiB. This is a workaround, not proof of the cause
# of that earlier run's missing temporary-directory witness.
image_fs_bytes_before=$(stat -c %s "$work/synthetic-p5.img")
[ "$image_fs_bytes_before" = 536870912 ]
truncate -s 1073741824 "$work/synthetic-p5.img"
e2fsck -fn "$work/synthetic-p5.img" > "$work/tarboot-padded-fsck.txt" 2>&1
dumpe2fs -h "$work/synthetic-p5.img" 2>/dev/null | grep -E '^Filesystem UUID:|^Filesystem features:|^Block count:|^Block size:' > "$work/tarboot-super-padded.txt"
cmp "$work/tarboot-super-before.txt" "$work/tarboot-super-padded.txt"
# The emulator creates a sibling lock file, so owning the image alone is not
# enough: its parent directory must be writable by the emulator account too.
# Otherwise the legacy emulator may fall back to an empty temporary partition.
mkdir "$work/emulator-data"
sudo chown emulatorlab:emulatorlab "$work/emulator-data"
sudo -u emulatorlab cp --sparse=always "$work/synthetic-p5.img" "$work/emulator-data/synthetic-p5.img"
data_image="$work/emulator-data/synthetic-p5.img"
cmp "$work/synthetic-p5.img" "$data_image"
sudo -u emulatorlab touch "$work/emulator-data/lock-permission-test"
sudo -u emulatorlab rm "$work/emulator-data/lock-permission-test"
image_size_before=$(stat -c %s "$data_image")
data_args=(-data "$data_image")
start_emulator
boot
image_size_after=$(stat -c %s "$data_image")
echo "Extracted virtual image file bytes before/after emulator start: $image_size_before/$image_size_after"
bootid_tarboot=$(timeout -k 5 30 "$adb" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
[[ "$bootid_tarboot" =~ ^[0-9a-f-]{36}$ ]] && [ "$bootid_tarboot" != "$newid" ] || { echo 'New kernel boot ID not confirmed'; exit 1; }
timeout -k 5 60 "$adb" shell id | tr -d '\r' | grep -q 'uid=0'
timeout -k 5 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r' | grep -Fx 'generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys'
timeout -k 5 30 "$adb" shell cat /data/data/ru.lifanx60.backupfixture/files/x60-copied-image-witness | tr -d '\r' | tee "$work/tarboot-witness-readback.txt"
grep -Fx X60_COPIED_IMAGE_ONLY "$work/tarboot-witness-readback.txt" || {
  echo 'Copied-image witness missing; do not claim boot from copy'
  echo 'Host image superblock before and after boot (diagnostic only):'
  cat "$work/tarboot-super-padded.txt"
  dumpe2fs -h "$data_image" 2>/dev/null | grep -E '^Filesystem UUID:|^Filesystem features:|^Block count:|^Block size:' || true
  grep -iE 'image already in use|changes will not persist|userdata.*partition' "$work/emulator.txt" | tail -30 || true
  echo 'Android mounts:'
  timeout -k 5 30 "$adb" shell cat /proc/mounts || true
  echo 'Android block devices:'
  timeout -k 5 30 "$adb" shell cat /proc/partitions || true
  echo 'Android boot and mount diagnostics:'
  timeout -k 5 30 "$adb" shell dmesg 2>/dev/null | grep -iE 'mtdblock|ext4|mount|fs_mgr|format|userdata|data' | tail -100 || true
  timeout -k 5 30 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'fs_mgr|mount|format|userdata|installd' | tail -80 || true
  timeout -k 5 30 "$adb" shell pm path com.navitel || true
  timeout -k 5 30 "$adb" shell pm path ru.lifanx60.backupfixture || true
  timeout -k 5 30 "$adb" shell ls -l /data/app /data/system/packages.xml /data/data/ru.lifanx60.backupfixture/files || true
  exit 1
}
timeout -k 5 30 "$adb" shell df /data | tr -d '\r' > "$work/tarboot-df.txt"
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep -E ' /data | /system ' > "$work/mounts-tarboot.txt"
grep -E ' /system [^ ]+ ro[, ]' "$work/mounts-tarboot.txt"
grep -E ' /data ext4 rw[, ]' "$work/mounts-tarboot.txt"
query_package tarboot
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-tarboot.txt"
grep -F 'versionCode=360622024' "$work/package-tarboot.txt"
uid_tarboot=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-tarboot.txt" | head -1)
[ "$uid_before" = "$uid_tarboot" ] || { echo 'Navitel UID changed after copied image boot'; exit 1; }
check_synthetic tarboot
timeout -k 5 60 "$adb" pull /data/data/com.navitel/files/lab-marker.txt "$work/navitel-marker-tarboot-raw.txt" >/dev/null
cmp "$work/navitel-marker-before-raw.txt" "$work/navitel-marker-tarboot-raw.txt"
cmp "$work/canary-marker-before.txt" "$work/canary-marker-tarboot.txt"
cmp "$work/canary-pref-before.xml" "$work/canary-pref-tarboot.xml"
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/files/lab-marker.txt "$work/blocked-tarboot-marker.txt" >/dev/null
timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupblocked/shared_prefs/lab_probe.xml "$work/blocked-tarboot-pref.xml" >/dev/null
cmp "$work/blocked-before-marker.txt" "$work/blocked-tarboot-marker.txt"
cmp "$work/blocked-before-pref.xml" "$work/blocked-tarboot-pref.xml"
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-tarboot.apk" >/dev/null
cmp "$work/old.apk" "$work/stock-after-tarboot.apk"
timeout -k 10 120 "$adb" pull /system/framework/services.jar "$work/services-after-tarboot.jar" >/dev/null
cmp "$work/stock-services.jar" "$work/services-after-tarboot.jar"
server_pid=$(timeout -k 5 30 "$adb" shell ps | tr -d '\r' | awk '$NF == "system_server" && !seen++ {print $2}')
case "$server_pid" in ''|*[!0-9]*) echo 'System server PID missing after copied-image boot'; exit 1;; esac
timeout -k 5 30 "$adb" shell "cat /proc/$server_pid/maps" | tr -d '\r' | grep -F 'system@framework@services.jar@classes.dex' > "$work/services-maps-tarboot.txt"
measure_storage tarboot
# Launch independent synthetic app after proving data already survived.
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupfixture/.MainActivity > "$work/canary-tarboot-start.txt" 2>&1
ready=no
for i in $(seq 1 60); do
  timeout -k 5 30 "$adb" logcat -d -v brief > "$work/canary-tarboot-log.txt" 2>&1 || true
  if grep -Fq FIXTURE_READY "$work/canary-tarboot-log.txt"; then ready=yes; break; fi
  if grep -Fq FIXTURE_FAILURE "$work/canary-tarboot-log.txt"; then break; fi
  sleep 2
done
initial_fixture_result=ready
archive_removed=no
if [ "$ready" != yes ]; then
  echo 'Synthetic independent app did not emit FIXTURE_READY after copied-image boot'
  echo 'am start result:'; cat "$work/canary-tarboot-start.txt"
  echo 'Relevant activity and error log lines:'
  grep -iE 'backupfixture|FIXTURE_READY|FIXTURE_FAILURE|FATAL EXCEPTION|AndroidRuntime|No space|ENOSPC|permission denied|dexopt|Error:' "$work/canary-tarboot-log.txt" | tail -100 || true
  echo 'Filesystem space:'; timeout -k 5 30 "$adb" shell df /data || true
  grep -Fq FIXTURE_FAILURE "$work/canary-tarboot-log.txt" || { echo 'Unexpected launch failure'; exit 1; }
  grep -Fq 'ENOSPC (No space left on device)' "$work/canary-tarboot-log.txt" || { echo 'Unexpected launch failure: ENOSPC not observed'; exit 1; }
  initial_fixture_result=ENOSPC
  if [ "$strategy" = stream ]; then
    echo 'Streamed model still ran out of space; do not remove anything or call it successful'
    exit 1
  fi
  # A failing write may truncate the fixture's existing file. Record its exact
  # post-failure bytes before any retry, rather than calling them preserved.
  timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupfixture/files/lab-marker.txt "$work/canary-marker-after-failure.txt" >/dev/null
  wc -c "$work/canary-marker-before.txt" "$work/canary-marker-after-failure.txt" > "$work/canary-failure-sizes.txt"
  cat "$work/canary-failure-sizes.txt"
  # Separate diagnostic intervention, ONLY in this throwaway emulator: verify
  # the redundant synthetic tar's exact bytes, remove it, and retry. This is
  # not stock Hibernate behavior or an instruction for a physical device.
  timeout -k 10 300 "$adb" pull /data/data.tar "$work/tarboot-archive-readback.tar" >/dev/null
  sha256sum "$work/tarboot-archive-readback.tar" | awk '{print $1}' > "$work/tarboot-archive-readback-sha256.txt"
  cmp "$work/tarboot-archive-sha256.txt" "$work/tarboot-archive-readback-sha256.txt"
  timeout -k 5 30 "$adb" shell rm /data/data.tar
  timeout -k 5 30 "$adb" shell 'test ! -e /data/data.tar && echo SYNTHETIC_ARCHIVE_REMOVED' | tr -d '\r' | grep -Fx SYNTHETIC_ARCHIVE_REMOVED
  archive_removed=yes
  timeout -k 5 30 "$adb" shell df /data | tr -d '\r' > "$work/tarboot-df-after-intervention.txt"
  timeout -k 5 30 "$adb" shell am force-stop ru.lifanx60.backupfixture
  timeout -k 5 30 "$adb" logcat -c
  timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupfixture/.MainActivity > "$work/canary-retry-start.txt" 2>&1
  for i in $(seq 1 60); do
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/canary-retry-log.txt" 2>&1 || true
    if grep -Fq FIXTURE_READY "$work/canary-retry-log.txt"; then ready=yes; break; fi
    if grep -Fq FIXTURE_FAILURE "$work/canary-retry-log.txt"; then break; fi
    sleep 2
  done
  [ "$ready" = yes ] || { echo 'Synthetic fixture retry failed'; cat "$work/canary-retry-start.txt"; grep -iE 'FIXTURE_|ENOSPC|FATAL EXCEPTION' "$work/canary-retry-log.txt" | tail -30 || true; exit 1; }
fi
check_synthetic tarbootlaunch
# Observe activity launch, without asserting real activation or navigation.
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n com.navitel/com.navitel.app.MainActivity > "$work/navitel-tarboot-start.txt" 2>&1 || true
sleep 12
timeout -k 5 60 "$adb" shell dumpsys activity activities > "$work/navitel-tarboot-activities.txt" 2>&1 || true
timeout -k 5 60 "$adb" logcat -d -v brief > "$work/navitel-tarboot-log.txt" 2>&1 || true
check_synthetic tarbootnav
{
  echo '# App-initiated multi-package synthetic backup and Navitel update on disposable Android 4.4.2 ARM'
  echo 'Generic ARM emulator with stock-derived services.jar preloaded offline, not the head unit; host emulator network blocked.'
  echo 'Disposable generic ARM system image built and fsck-checked offline. Stock Navitel, services.jar and measurement-only BusyBox matched byte-for-byte; services dex mapped by system_server.'
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
  echo '## Allocated emulator storage (KiB, BusyBox du -sk)'
  echo 'Generic ARM image, emulator data/apps/cache and synthetic fixtures, not physical GU sizes; emulator usage changes and overlapping categories must not be added.'
  echo 'Before update:'; cat "$work/du-before.txt"
  echo 'After update:'; cat "$work/du-after.txt"
  echo 'After host-triggered cold start:'; cat "$work/du-coldboot.txt"
  echo 'The update is a CI-only re-signed version of the 99176587-byte original APK; the actual GU install footprint and free space remain unknown.'
  echo '## Offline copy model based on synthetic ARM userdata'
  echo 'The emulator was synced and stopped; a copy of its 1 GiB userdata image was fsck-checked offline and mounted read-only. No physical device or user data.'
  echo "Offline fsck correction status: $fsck_rc (0 clean, 1 corrected); a subsequent read-only fsck passed."
  echo 'Stock-derived ARM BusyBox tar was run through QEMU in a restricted container against the copy. Destination was a new empty 512 MiB ext4 regular-file image, not the real GU partition.'
  if [ "$strategy" = stream ]; then
    echo 'Primary image formatted with exact stock-derived ARM mke2fs against a dedicated unmounted synthetic 512 MiB loop under QEMU; not the stock kernel or script.'
    cat "$work/formatter-config.txt" "$work/formatter-primary-geometry.txt"
    echo "Streaming copy: tar producer exit $create_rc; tar consumer exit $extract_rc; no data.tar on destination."
  else
    echo "Archive exit: $create_rc; extraction exit: $extract_rc; archive remains on destination."
  fi
  echo 'Selected synthetic files checked after extraction:'; cat "$work/copy-checks.txt"
  echo "Allocated KiB on the CI host (strategy=$strategy; source ext4, not GU tmpfs):"; cat "$work/copy-sizes.txt"
  echo 'Destination filesystem usage:'; cat "$work/copy-df.txt"
  cat "$work/copy-statvfs.txt"
  echo "Negative control on fresh 512 MiB image: copied baseline snapshot plus one synthetic 32 MiB file, tar create exit $plus_create_rc, extraction exit $plus_extract_rc with No space left on device."
  echo 'This artificial addition is not a claim about installed apps or capacity on the head unit.'
  if [ "$strategy" = stream ]; then
    echo "Contrast: the identical +32 MiB synthetic source streamed to a stock-formatted 512 MiB image; producer/consumer exits ${plus_stream_rc[0]}/${plus_stream_rc[1]}, no target archive."
    cat "$work/stream-plus-checks.txt" "$work/stream-plus-statvfs.txt"
    echo "Negative control: streaming that source to a fresh stock-formatted 64 MiB image failed with ENOSPC; producer/consumer exits ${small_stream_rc[0]}/${small_stream_rc[1]}."
    echo 'A failed stream leaves a partial destination; no recovery or safe physical-device procedure is established.'
  fi
  echo 'Only listed files and metadata were compared; tar exit 0 is not proof all app data, xattrs, SELinux labels, sparse data, or timestamps were preserved.'
  echo 'The stock updater declares DATA_SIZE=512 with sfdisk -uM for logical p5; actual head-unit size, free space, other apps and runtime sequence remain unknown.'
  echo '## Boot from extracted virtual image'
  echo "The $strategy synthetic ext4 image was unmounted and checked before being passed as -data to the same classic ARM AVD; the generic boot ramdisk and kernel remained unchanged."
  echo "The extracted ext4 filesystem started at $image_fs_bytes_before bytes; its regular-file backing was padded to 1 GiB without filesystem resize to satisfy the legacy emulator."
  echo "Padded image file size before/after emulator start: $image_size_before/$image_size_after bytes. New kernel boot ID confirmed."
  echo 'Pre-boot ext4 geometry after padding:'; cat "$work/tarboot-super-padded.txt"
  echo 'A synthetic witness added only to the extracted image was readable after boot, excluding silent fallback to original AVD userdata.'
  echo 'df /data after boot:'; cat "$work/tarboot-df.txt"
  echo 'After boot, Navitel remained registered as the data update, with the same UID; synthetic files and UIDs of Navitel and independent fixture matched before starting the fixture. Blocked fixture files matched too.'
  echo "Initial independent-fixture launch result: $initial_fixture_result. Synthetic archive removed in a separate CI-only intervention: $archive_removed."
  if [ "$archive_removed" = yes ]; then
    echo 'Fixture first failed with ENOSPC, despite free blocks visible to root. Before retry the synthetic archive was pulled and its SHA-256 matched the pre-boot file; then it was deleted ONLY in the disposable emulator.'
    echo 'Fixture marker byte counts before first launch and after its failed write:'; cat "$work/canary-failure-sizes.txt"
    echo 'The retry emitted FIXTURE_READY and recreated its marker; this does not prove that marker survived the failed write.'
    echo 'df /data after synthetic-only intervention:'; cat "$work/tarboot-df-after-intervention.txt"
    echo 'This intervention does not model stock Hibernate and is not an instruction for a real device.'
  else
    echo 'Independent fixture emitted FIXTURE_READY without the intervention.'
  fi
  echo 'System Navitel APK and services.jar matched originals; system_server mapped the services dex.'
  echo 'Mounts:'; cat "$work/mounts-tarboot.txt"
  echo 'Synthetic emulator storage after copied-image boot:'; cat "$work/du-tarboot.txt"
  echo 'Navitel launch observation (not activation):'; cat "$work/navitel-tarboot-start.txt"
  tr -d '\r' < "$work/navitel-tarboot-activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' | head -5 || true
  tr -d '\r' < "$work/navitel-tarboot-log.txt" | grep -iE 'FATAL EXCEPTION|Fatal signal|com.navitel.*(crash|died)' | tail -10 || true
  if [ "$strategy" = archive ]; then echo 'Host ext4 creation options differ from the stock formatter.'; else echo 'Streamed copy is an alternative laboratory model, NOT the stock script and NOT ready for a physical device.'; fi
  echo 'Cold booting a generic emulator is not real-device Hibernate or proof of all-data preservation.'
  echo '## Emulator crash dialog while installing'
  if [ -e "$work/navitel-crash-log.txt" ]; then echo 'Navitel stopped dialog observed'; grep -A 22 -F 'Process: com.navitel' "$work/navitel-crash-log.txt" | head -46 || true; else echo 'No Navitel crash dialog observed during installer polling; other failures may still occur'; fi
  echo '## Launch attempt (no activation asserted)'
  tr -d '\r' < "$work/start.txt"
  tr -d '\r' < "$work/activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' | head -5 || true
  tr -d '\r' < "$work/app-log.txt" | grep -iE 'FATAL EXCEPTION|Fatal signal|com.navitel.*(crash|died)' | tail -10 || true
  echo 'Kernel boot ID changed after host stopped and restarted the same disposable emulator. This is a virtual cold start after sync, not real-device hibernate or graceful car shutdown.'
  echo 'Real device app behavior, USB, rollback, settings and all data preservation remain unverified.'
} > "reports/$report_name"

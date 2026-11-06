#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never run against a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/navitel-arm-offline-system-lab.log") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-arm-offline-system-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
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
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'system-images;android-19;default;armeabi-v7a'
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
e2fsck -fy "$work/offline-system.img"
resize2fs "$work/offline-system.img" 1024M
e2fsck -fn "$work/offline-system.img"
debugfs -R "dump /framework/services.jar $work/stock-services.jar" "$work/system.img" >/dev/null 2>&1
echo "998f7b8558e55fa4d40ea676414cb4bf35f9c9b6f0eae3c81f037186229c403c  $work/stock-services.jar" | sha256sum -c -
# The source is a checked generic SDK image; mutation below affects only its disposable copy.
debugfs -w -R 'rm /framework/services.jar' "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'rm /framework/services.odex' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R "write $work/stock-services.jar /framework/services.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R "write $work/old.apk /priv-app/Navitel-large.apk" "$work/offline-system.img" >/dev/null 2>&1
printf 'u:object_r:system_file:s0\0' > "$work/system-context"
for target in /framework/services.jar /priv-app/Navitel-large.apk; do
  debugfs -w -R "set_inode_field $target mode 0100644" "$work/offline-system.img" >/dev/null 2>&1
  debugfs -w -R "ea_set -f $work/system-context $target security.selinux" "$work/offline-system.img" >/dev/null 2>&1
done
e2fsck -fn "$work/offline-system.img"
debugfs -R "dump /framework/services.jar $work/services-offline-check.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /priv-app/Navitel-large.apk $work/old-offline-check.apk" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/stock-services.jar" "$work/services-offline-check.jar"
cmp "$work/old.apk" "$work/old-offline-check.apk"
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
    kill -0 "$pid" 2>/dev/null || { echo 'Emulator exited'; exit 1; }
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

check_synthetic() {
  local phase=$1
  timeout -k 5 60 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt | tr -d '\r' > "$work/marker-$phase.txt"
  test "$(cat "$work/marker-$phase.txt")" = X60_DISPOSABLE_MIGRATION_TEST
  timeout -k 5 60 "$adb" pull /data/data/com.navitel/shared_prefs/x60_lab_probe.xml "$work/pref-$phase.xml" >/dev/null
  cmp "$work/lab-pref.xml" "$work/pref-$phase.xml"
}
query_package() {
  local phase=$1
  timeout -k 5 60 "$adb" shell pm path com.navitel | tr -d '\r' > "$work/path-$phase.txt"
  timeout -k 5 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/package-$phase.txt"
}
check_synthetic before
query_package before
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

echo 'Install matching-certificate update into emulator data partition (never touch system APK during update)'
timeout -k 10 300 "$adb" install -r "$work/new-resigned.apk" > "$work/positive.txt" 2>&1 || true
cat "$work/positive.txt"
grep -F Success "$work/positive.txt" || { echo 'Matching-signature update was not installed'; exit 1; }
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
{
  echo '# Same-signature Navitel data-update on disposable Android 4.4.2 ARM'
  echo 'Generic ARM emulator with stock-derived services.jar preloaded offline, not the head unit; host emulator network blocked.'
  echo 'Disposable generic ARM system image built and fsck-checked offline. Stock Navitel and services.jar matched byte-for-byte; services dex mapped by system_server.'
  echo 'No real maps, license, accounts, user data or SD; no APKs published. Empty virtual SD only.'
  echo 'ADB was used for emulator setup, installation and observation; actual GU file-manager installer not tested.'
  echo 'Initial stock-derived Navitel certificate equals the verified AOSP testkey certificate:'
  echo "$keycert"
  echo 'Candidate re-signed in disposable CI only; not an installation recommendation.'
  cat "$work/compare.txt"
  echo 'Negative control: original differently signed candidate rejected; installer result:'
  grep -E 'Failure \[' "$work/negative.txt" | tr -d '\r'
  echo 'Matching certificate candidate installed as data update; original emulator system APK unchanged: yes.'
  echo 'Emulator system mounted read-only from initial boot through update (no system write or remount during emulator run):'; cat "$work/mount-system.txt"
  echo "UID before/after/userspace restart: $uid_before/$uid_after/$uid_restart"
  echo '## Package paths and selected version'
  cat "$work/path-before.txt" "$work/path-after.txt" "$work/path-restart.txt"
  grep -E 'versionCode=|versionName=|codePath=' "$work/package-restart.txt" | head -10
  echo 'Synthetic marker and preferences survived install, userspace restart, and launch attempt: yes.'
  echo '## Launch attempt (no activation asserted)'
  tr -d '\r' < "$work/start.txt"
  tr -d '\r' < "$work/activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' | head -5 || true
  tr -d '\r' < "$work/app-log.txt" | grep -iE 'FATAL EXCEPTION|Fatal signal|com.navitel.*(crash|died)' | tail -10 || true
  echo 'Userspace restart is not a full reboot or real-device hibernate. App behavior, rollback, settings and all data preservation remain unverified.'
} > reports/navitel-arm-offline-system-lab.txt

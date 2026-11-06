#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never run against a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/navitel-backup-test.log") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-backup-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
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
    "$work/legacy/tools/emulator" -avd migration_arm -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -verbose >> "$work/emulator.txt" 2>&1 &
  pid=$!
}
restart_android_runtime() {
  # Restart Android userspace, not the VM: legacy QEMU hangs on adb reboot and
  # SIGTERM. This reinitializes system_server/PackageManager but is not a reboot.
  timeout 30 "$adb" shell sync
  timeout 30 "$adb" shell setprop sys.boot_completed 0
  timeout 30 "$adb" shell stop
  timeout 30 "$adb" shell start
  boot
}
start_emulator
boot() {
  "$adb" wait-for-device &
  local waitpid=$! connected=no
  for i in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null; then
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
test "$(cat "$work/fingerprint.txt")" = 'generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys' || { echo 'Unexpected emulator; abort'; exit 1; }
timeout 30 "$adb" shell getprop ro.product.cpu.abi | tr -d '\r' > "$work/abi.txt"
echo 'Trying remount of emulator system only'
timeout 60 "$adb" remount | tee "$work/remount.txt"
grep -iq 'remount succeeded' "$work/remount.txt" || { echo 'Cannot remount emulator system'; exit 1; }
timeout 30 "$adb" shell df /system | tr -d '\r'

echo 'Phase 3: push old system APK on disposable emulator'
timeout 300 "$adb" push "$work/old.apk" /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell chmod 0644 /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell restorecon /system/priv-app/Navitel-large.apk || true
echo "Phase 3a: restart Android userspace with old package"
restart_android_runtime
echo "Phase 3b: verify old system APK is unchanged and query package"
timeout 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/old-after-restart.apk" >/dev/null
cmp "$work/old.apk" "$work/old-after-restart.apk" || { echo 'Old system file changed'; exit 1; }
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

# An empty virtual SD exists in this AVD; no real card or account is used.
# Android's confirmation UI is handled only inside this disposable emulator.
confirm_emulator_dialog() {
  local expected="$1" coords=''
  for attempt in 1 2 3 4 5; do
    if timeout 50 "$adb" shell uiautomator dump /sdcard/lab-confirm.xml >/dev/null 2>&1 &&
       timeout 15 "$adb" shell cat /sdcard/lab-confirm.xml > "$work/ui.xml"; then
      coords=$(python3 tools/emulator_backup_confirmation.py "$work/ui.xml" "$expected" 2>/dev/null || true)
      if [ -n "$coords" ]; then
        read -r x y <<< "$coords"
        echo "Located confirmation UI at $x,$y: $expected"
        timeout 20 "$adb" shell input tap "$x" "$y"
        echo "Tapped virtual UI: $expected"
        return 0
      fi
    fi
    sleep 3
  done
  echo "Expected confirmation button was not found: $expected"
  cat "$work/ui.xml" 2>/dev/null || true
  return 1
}

echo 'Phase 4: Android backup of synthetic marker only'
timeout 30 "$adb" logcat -c
timeout 15 "$adb" shell input keyevent 82 || true
# Modern adb backup quotes legacy bu's arguments incompatibly on this API 19
# image. Pass one fixed, lab-only command string to the shell service instead.
timeout 300 "$adb" exec-out 'bu backup -noapk com.navitel' > "$work/synthetic.ab" 2> "$work/backup-command.txt" &
backup_pid=$!
confirm_emulator_dialog 'Back up my data' || { kill "$backup_pid" 2>/dev/null || true; exit 1; }
wait "$backup_pid" || { echo 'ADB backup command failed'; cat "$work/backup-command.txt"; exit 1; }
if ! python3 tools/check_synthetic_adb_backup.py "$work/synthetic.ab" | tee "$work/backup-check.txt"; then
  echo 'Backup command output:'; cat "$work/backup-command.txt"
  echo 'Selected backup and application logs:'
  timeout 60 "$adb" logcat -d -v brief | grep -iE 'BackupManagerService|AndroidRuntime|com\.navitel|backup agent' | tail -100 || true
  exit 1
fi

echo 'Phase 5: replace system package only in disposable emulator'
timeout 60 "$adb" remount | tee "$work/remount2.txt"
grep -iq 'remount succeeded' "$work/remount2.txt"
timeout 30 "$adb" shell rm /system/priv-app/Navitel-large.apk
timeout 300 "$adb" push "$new" /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell chmod 0644 /system/priv-app/Navitel-large.apk
timeout 30 "$adb" shell restorecon /system/priv-app/Navitel-large.apk || true
restart_android_runtime
timeout 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/new-after-restart.apk" >/dev/null
cmp "$new" "$work/new-after-restart.apk"
timeout 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/new-package.txt"
grep -q 'versionCode=360622024' "$work/new-package.txt" || { echo 'Replacement not registered'; exit 1; }
# Delete only the synthetic marker, so seeing it after restore is meaningful.
timeout 30 "$adb" shell rm /data/data/com.navitel/files/lab-marker.txt
if timeout 30 "$adb" shell test -e /data/data/com.navitel/files/lab-marker.txt; then
  echo 'Marker unexpectedly still exists before restore'; exit 1
fi

echo 'Phase 6: restore synthetic archive into new system package'
timeout 30 "$adb" logcat -c
timeout 300 "$adb" restore "$work/synthetic.ab" > "$work/restore-command.txt" 2>&1 &
restore_pid=$!
confirm_emulator_dialog 'Restore my data' || { kill "$restore_pid" 2>/dev/null || true; exit 1; }
set +e
wait "$restore_pid"; restore_status=$?
timeout 30 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt > "$work/restored-marker.txt" 2>&1; marker_status=$?
timeout 60 "$adb" logcat -d -v brief > "$work/restore-log.txt" 2>&1
set -e
uid_after=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/new-package.txt" | head -1 || true)
{
  echo '# Synthetic Android backup and cross-signature restore in disposable ARM emulator'
  echo 'Generic Android 4.4.2 emulator only; do not apply these operations to a head unit.'
  echo 'No real license, maps, user data or SD; empty virtual SD; emulator network blocked before boot.'
  echo 'Backup used legacy bu via adb exec-out; system replacement used Android userspace restart, not full VM reboot.'
  echo "Fingerprint: $(cat "$work/fingerprint.txt"); ABI: $(cat "$work/abi.txt")"
  echo "Old UID: $uid_before; new UID: ${uid_after:-unavailable}"
  echo 'Old certificate: a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc'
  echo 'New certificate: 5358662d39856446c7391c699878e0509f7ed0657d7634c0083e07b08ad2f035'
  echo '## Before restore'; cat "$work/backup-check.txt"; echo 'Synthetic marker explicitly removed before restore.'
  echo '## Restore result'; echo "adb restore exit: $restore_status; marker read exit: $marker_status"
  tr -d '\r' < "$work/restored-marker.txt"
  echo '## Selected backup manager logs'
  grep -iE 'BackupManagerService.*(com\.navitel|signature|restore|backup)|BackupManagerService.*error' "$work/restore-log.txt" | tail -60 | tr -d '\r' || true
  echo 'This is not evidence of real app settings, license, maps, actual head-unit behavior or a safe restoration procedure.'
} > reports/navitel-backup-restore-emulator.txt

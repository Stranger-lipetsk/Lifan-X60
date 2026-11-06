#!/usr/bin/env bash
# Disposable GitHub Actions emulator only. Never run on a head unit.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/no-adb-backup-lab.log") 2>&1
work=$(mktemp -d /tmp/no-adb-backup.XXXXXX)
chmod 0755 "$work"
mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"
mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq iptables unzip zip openssl
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;x86'
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
test -s "$jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n backup_x86 -k 'system-images;android-19;default;x86' -c 512M >/dev/null
sudo useradd --system --create-home --user-group backupcallerlab
emu_uid=$(id -u backupcallerlab)
sudo chown -R backupcallerlab:backupcallerlab "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status); emulator diagnostics:"
    tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'X60BackupCaller|X60SyntheticTarget|BackupManagerService|FATAL EXCEPTION' | tail -80 || true
  fi
  sudo pkill -TERM -u backupcallerlab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4/IPv6 blocked"
sudo -u backupcallerlab env HOME=/home/backupcallerlab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
  "$sdk/emulator/emulator" -avd backup_x86 -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -no-metrics > "$work/emulator.log" 2>&1 &
pid=$!
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
[ "$qemu" = 1 ] || { echo 'Not the disposable emulator'; exit 1; }
echo "Fingerprint: $fingerprint; hardware: $hardware; qemu: $qemu"

echo 'Obtain AOSP emulator platform key; verify against its framework APK'
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
for ext in x509.pem pk8; do
  gh api "repos/aosp-mirror/platform_build/contents/target/product/security/platform.$ext?ref=$ref" --jq .content | base64 -d > "$work/platform.$ext"
done
timeout -k 10 120 "$adb" pull /system/framework/framework-res.apk "$work/framework-res.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/framework-res.apk" > "$work/framework-cert.txt"
actual=$(sed -n 's/^V1 Signer: certificate SHA-256 digest: //p; s/^Signer #1 certificate SHA-256 digest: //p' "$work/framework-cert.txt" | head -1)
expected=$(openssl x509 -in "$work/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
test -n "$actual" && test "$actual" = "$expected" || { echo 'AOSP key does not match emulator platform'; cat "$work/framework-cert.txt"; exit 1; }
echo "Emulator platform cert: $actual"
keytool -genkeypair -keystore "$work/negative.keystore" -storepass test-only -keypass test-only -alias negative -keyalg RSA -keysize 2048 -validity 10 -dname 'CN=Disposable negative control' >/dev/null 2>&1

build_unsigned() {
  local name=$1 src=$2
  mkdir -p "$work/$name/classes" "$work/$name/dex"
  "$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/$name/unsigned.apk"
  find "$src/src" -name '*.java' | sort > "$work/$name/sources.txt"
  javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/$name/classes" @"$work/$name/sources.txt"
  find "$work/$name/classes" -name '*.class' > "$work/$name/classes.txt"
  "$bt/d8" --lib "$jar" --min-api 19 --output "$work/$name/dex" @"$work/$name/classes.txt"
  cp "$work/$name/dex/classes.dex" "$work/$name/classes.dex"
  (cd "$work/$name" && zip -q -u unsigned.apk classes.dex)
  "$bt/zipalign" -f 4 "$work/$name/unsigned.apk" "$work/$name/aligned.apk"
}
build_unsigned target tests/fixtures/no-adb-backup-target
build_unsigned caller tests/fixtures/no-adb-backup-caller
for name in target caller; do
  "$bt/apksigner" sign --ks "$work/negative.keystore" --ks-pass pass:test-only --key-pass pass:test-only \
    --min-sdk-version 19 --v1-signing-enabled true --out "$work/$name-negative.apk" "$work/$name/aligned.apk"
done
"$bt/apksigner" sign --key "$work/platform.pk8" --cert "$work/platform.x509.pem" --min-sdk-version 19 \
  --v1-signing-enabled true --out "$work/caller-platform.apk" "$work/caller/aligned.apk"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 "$work/caller-platform.apk"
install_apk() {
  timeout -k 10 120 "$adb" install "$1" > "$work/install.txt" 2>&1 || { cat "$work/install.txt"; exit 1; }
  grep -F Success "$work/install.txt" || { cat "$work/install.txt"; exit 1; }
}
wait_log() {
  local pattern=$1
  for i in $(seq 1 30); do
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/current-log.txt" 2>&1 || true
    if grep -Fq "$pattern" "$work/current-log.txt"; then grep -F "$pattern" "$work/current-log.txt" | tail -1; return 0; fi
    sleep 2
  done
  echo "Missing expected lab log: $pattern"; return 1
}

echo 'Create synthetic target data in the disposable emulator'
install_apk "$work/target-negative.apk"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupfixture/.MainActivity > "$work/target-start.txt" 2>&1
wait_log FIXTURE_READY

echo 'Negative control: ordinary signed caller should not receive BACKUP'
install_apk "$work/caller-negative.apk"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupcallerfixture/.MainActivity > "$work/negative-start.txt" 2>&1
wait_log 'BACKUP_PERMISSION=false'
timeout -k 5 60 "$adb" shell pm uninstall ru.lifanx60.backupcallerfixture > "$work/uninstall.txt" 2>&1
grep -F Success "$work/uninstall.txt"

echo 'Positive control: app signed with emulator platform key, no shared UID'
install_apk "$work/caller-platform.apk"
timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.backupcallerfixture > "$work/caller-package.txt"
caller_uid=$(tr -d '\r' < "$work/caller-package.txt" | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -1)
case "$caller_uid" in ''|*[!0-9]*) echo 'Caller UID missing'; exit 1;; esac
[ "$caller_uid" -ge 10000 ] || { echo "Unexpected shared/system caller UID: $caller_uid"; exit 1; }
request_synthetic_backup() {
  local label=$1 confirmed=no coords x y
  timeout -k 5 30 "$adb" logcat -c
  timeout -k 5 15 "$adb" shell input keyevent 82 || true
  timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupcallerfixture/.MainActivity > "$work/$label-start.txt" 2>&1
  wait_log 'BACKUP_PERMISSION=true'
  wait_log 'STARTING_SYNTHETIC_BACKUP'
  for attempt in $(seq 1 8); do
    if timeout -k 5 50 "$adb" shell uiautomator dump /sdcard/no-adb-lab-ui.xml >/dev/null 2>&1 &&
       timeout -k 5 15 "$adb" shell cat /sdcard/no-adb-lab-ui.xml > "$work/ui.xml"; then
      coords=$(python3 tools/emulator_backup_confirmation.py "$work/ui.xml" 'Back up my data' 2>/dev/null || true)
      if [ -n "$coords" ]; then
        read -r x y <<< "$coords"
        timeout -k 5 20 "$adb" shell input tap "$x" "$y"
        echo "Emulator confirmation tapped at $x,$y"
        confirmed=yes; break
      fi
    fi
    sleep 3
  done
  [ "$confirmed" = yes ] || { echo 'Confirmation UI not found'; return 1; }
  wait_log BACKUP_CALL_RETURNED
  if grep -Fq BACKUP_CALL_FAILED "$work/current-log.txt"; then echo 'Backup call failed'; return 1; fi
  timeout -k 5 60 "$adb" pull /sdcard/Android/data/ru.lifanx60.backupcallerfixture/files/synthetic.ab "$work/$label.ab" >/dev/null
  python3 tools/check_no_adb_lab_backup.py "$work/$label.ab" > "$work/$label-check.txt"
}
request_synthetic_backup ordinary

echo 'Repeat with the synthetic package as a system app with its own backup agent'
timeout -k 5 60 "$adb" shell pm uninstall ru.lifanx60.backupfixture > "$work/uninstall-target.txt" 2>&1
grep -F Success "$work/uninstall-target.txt"
timeout -k 5 60 "$adb" root || true
timeout -k 5 90 "$adb" wait-for-device
id=$(timeout -k 5 30 "$adb" shell id | tr -d '\r')
grep -q 'uid=0' <<< "$id" || { echo 'Root adb unavailable on disposable emulator'; exit 1; }
timeout -k 5 60 "$adb" remount | tee "$work/remount.txt"
grep -iq 'remount succeeded' "$work/remount.txt" || { echo 'Cannot remount emulator'; exit 1; }
timeout -k 10 120 "$adb" push "$work/target-negative.apk" /system/priv-app/BackupFixture.apk
timeout -k 5 30 "$adb" shell chmod 0644 /system/priv-app/BackupFixture.apk
timeout -k 5 30 "$adb" shell restorecon /system/priv-app/BackupFixture.apk || true
timeout -k 5 30 "$adb" shell sync
timeout -k 5 30 "$adb" shell setprop sys.boot_completed 0
timeout -k 5 30 "$adb" shell stop
timeout -k 5 30 "$adb" shell start
booted=no
for i in $(seq 1 100); do
  if [ "$(timeout -k 5 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  sleep 3
done
[ "$booted" = yes ] || { echo 'Userspace restart timeout'; exit 1; }
timeout -k 5 60 "$adb" shell pm path ru.lifanx60.backupfixture | tr -d '\r' > "$work/system-target-path.txt"
grep -F 'package:/system/priv-app/BackupFixture.apk' "$work/system-target-path.txt"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.backupfixture/.MainActivity > "$work/system-target-start.txt" 2>&1
wait_log FIXTURE_READY
request_synthetic_backup system
{
  echo '# Application-initiated synthetic backup, no ADB backup transport'
  echo 'Disposable generic Android 4.4.2 x86 emulator; no real device, Navitel, license, maps or real SD.'
  echo 'ADB was used only for laboratory install, observation, virtual UI and pulling the synthetic result; the app called the backup service itself.'
  echo 'Emulator-only AOSP platform signature; no shared UID; this is not a device APK or instructions.'
  echo "Fingerprint: $fingerprint; hardware: $hardware; caller UID: $caller_uid"
  echo "Emulator platform certificate: $actual"
  echo 'Negative control: unsigned-to-platform app BACKUP_PERMISSION=false.'
  echo 'Platform-signed app: BACKUP_PERMISSION=true; confirmation tapped in virtual UI; backup call returned.'
  echo '## Ordinary synthetic target'; cat "$work/ordinary-check.txt"
  echo '## System synthetic target with a backup agent'; cat "$work/system-target-path.txt"; cat "$work/system-check.txt"
  echo 'Android userspace restarted before the system target test; not a full emulator reboot.'
  echo 'No restore, real applications, real media, full partition image, or real head-unit behavior tested.'
} > reports/no-adb-backup-emulator.txt
cat reports/no-adb-backup-emulator.txt

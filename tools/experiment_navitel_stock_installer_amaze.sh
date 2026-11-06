#!/usr/bin/env bash
# Disposable generic x86 emulator only. Never run against a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/navitel-stock-installer-amaze-lab.log") 2>&1
# Accessible to the dedicated unprivileged emulator account, unlike runner's private temp.
work=$(mktemp -d /tmp/navitel-stock-installer-amaze-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
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
for spec in 'app/AmazeFileManager.apk:amaze.apk' 'app/PackageInstaller.apk:installer.apk'; do
  src=${spec%%:*}; dst=${spec#*:}
  debugfs -R "dump /$src $work/$dst" "$work/system.img" >/dev/null 2>&1
  test -s "$work/$dst"
done
echo "2a9bc50c6672b1cb6efdfbd9bd9149bf280274e386305663163cc365abd393f3  $work/amaze.apk" | sha256sum -c -
echo "39abdee3fc202e75bba6b3fc1c8d91081d3ff9bfeaa4c4e1297634f827794f5b  $work/installer.apk" | sha256sum -c -
"$bt/aapt" dump badging "$work/installer.apk" | grep -F "package: name='com.android.packageinstaller'"
"$bt/aapt" dump badging "$work/amaze.apk" | grep -F "package: name='com.amaze.filemanager'"
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

"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;x86'
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
test -s "$jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n backup_x86 -k 'system-images;android-19;default;x86' -c 512M >/dev/null
sudo useradd --system --create-home --user-group signedupdatex86
emu_uid=$(id -u signedupdatex86)
sudo chown -R signedupdatex86:signedupdatex86 "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status); emulator diagnostics:"
    tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'PackageManager|installd|com.navitel|FATAL EXCEPTION' | tail -80 || true
    timeout -k 5 30 "$adb" shell dmesg 2>/dev/null | grep -iE 'ext4|read.only|error' | tail -50 || true
    timeout -k 5 30 "$adb" shell df /system 2>/dev/null || true
  fi
  sudo pkill -TERM -u signedupdatex86 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4/IPv6 blocked"
sudo -u signedupdatex86 env HOME=/home/signedupdatex86 ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
  "$sdk/emulator/emulator" -avd backup_x86 -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -writable-system -partition-size 1536 -gpu swiftshader_indirect -no-metrics > "$work/emulator.log" 2>&1 &
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


restart_android_runtime() {
  timeout -k 5 30 "$adb" shell sync
  timeout -k 5 30 "$adb" shell setprop sys.boot_completed 0
  timeout -k 5 30 "$adb" shell stop
  timeout -k 5 30 "$adb" shell start
  local ready=no
  for i in $(seq 1 100); do
    if [ "$(timeout -k 5 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then ready=yes; break; fi
    sleep 3
  done
  [ "$ready" = yes ] || { echo 'Userspace restart timeout'; return 1; }
}
timeout -k 5 30 "$adb" shell getprop ro.build.fingerprint | tr -d '\r' > "$work/fingerprint.txt"
timeout -k 5 30 "$adb" shell getprop ro.product.cpu.abi | tr -d '\r' > "$work/abi.txt"
timeout -k 5 30 "$adb" root || true
timeout -k 5 90 "$adb" wait-for-device
id=$(timeout -k 5 30 "$adb" shell id | tr -d '\r')
grep -q 'uid=0' <<< "$id" || { echo 'Root unavailable for emulator preparation'; exit 1; }
timeout -k 5 60 "$adb" remount | tee "$work/remount.txt"
grep -iq 'remount succeeded' "$work/remount.txt" || { echo 'Cannot remount emulator system'; exit 1; }

echo 'Phase 3: stop disposable emulator userspace before installing fixture system APK'
timeout -k 5 30 "$adb" shell df /system
timeout -k 5 30 "$adb" shell setprop sys.boot_completed 0
timeout -k 5 30 "$adb" shell stop
# Prepare only this disposable emulator with stock-derived installer and Amaze;
# never replace a real device's installer.
timeout -k 5 30 "$adb" shell rm /system/priv-app/PackageInstaller.apk
timeout -k 10 120 "$adb" push "$work/installer.apk" /system/priv-app/PackageInstaller.apk
timeout -k 5 30 "$adb" shell chmod 0644 /system/priv-app/PackageInstaller.apk
timeout -k 10 120 "$adb" push "$work/amaze.apk" /system/app/AmazeFileManager.apk
timeout -k 5 30 "$adb" shell chmod 0644 /system/app/AmazeFileManager.apk
timeout -k 5 30 "$adb" shell restorecon /system/priv-app/PackageInstaller.apk /system/app/AmazeFileManager.apk || true
timeout -k 10 300 "$adb" push "$work/old.apk" /system/priv-app/Navitel-large.apk
timeout -k 5 30 "$adb" shell chmod 0644 /system/priv-app/Navitel-large.apk
timeout -k 5 30 "$adb" shell restorecon /system/priv-app/Navitel-large.apk || true
echo "Phase 3a: start Android userspace with old package"
timeout -k 5 30 "$adb" shell start
ready=no
for i in $(seq 1 100); do
  if [ "$(timeout -k 5 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then ready=yes; break; fi
  sleep 3
done
[ "$ready" = yes ] || { echo 'Userspace start timeout'; exit 1; }
echo "Phase 3b: verify old system APK is unchanged and query package"
timeout -k 5 60 "$adb" shell pm path com.android.packageinstaller | tr -d '\r' | tee "$work/installer-path.txt"
grep -F 'package:/system/priv-app/PackageInstaller.apk' "$work/installer-path.txt"
timeout -k 5 60 "$adb" shell pm path com.amaze.filemanager | tr -d '\r' | tee "$work/amaze-path.txt"
grep -F 'package:/system/app/AmazeFileManager.apk' "$work/amaze-path.txt"
timeout -k 10 120 "$adb" pull /system/priv-app/PackageInstaller.apk "$work/installer-check.apk" >/dev/null
cmp "$work/installer.apk" "$work/installer-check.apk"
timeout -k 10 120 "$adb" pull /system/app/AmazeFileManager.apk "$work/amaze-check.apk" >/dev/null
cmp "$work/amaze.apk" "$work/amaze-check.apk"
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

echo 'Create a second independent synthetic app to check unrelated data'
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
for i in $(seq 1 30); do
  timeout -k 5 20 "$adb" logcat -d -v brief > "$work/canary-log.txt" 2>&1 || true
  if grep -Fq FIXTURE_READY "$work/canary-log.txt"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Unrelated synthetic app not ready'; exit 1; }

check_synthetic() {
  local phase=$1
  timeout -k 5 60 "$adb" shell cat /data/data/com.navitel/files/lab-marker.txt | tr -d '\r' > "$work/marker-$phase.txt"
  test "$(cat "$work/marker-$phase.txt")" = X60_DISPOSABLE_MIGRATION_TEST
  timeout -k 5 60 "$adb" pull /data/data/com.navitel/shared_prefs/x60_lab_probe.xml "$work/pref-$phase.xml" >/dev/null
  cmp "$work/lab-pref.xml" "$work/pref-$phase.xml"
  timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupfixture/files/lab-marker.txt "$work/canary-marker-$phase.txt" >/dev/null
  timeout -k 5 60 "$adb" pull /data/data/ru.lifanx60.backupfixture/shared_prefs/lab_probe.xml "$work/canary-pref-$phase.xml" >/dev/null
  python3 - "$work/canary-marker-$phase.txt" "$work/canary-pref-$phase.xml" <<'PY'
import sys
from pathlib import Path
from tools.check_no_adb_lab_backup import verify_contents
verify_contents(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes())
print('Independent synthetic app marker and preferences verified')
PY
}
query_package() {
  local phase=$1
  timeout -k 5 60 "$adb" shell pm path com.navitel | tr -d '\r' > "$work/path-$phase.txt"
  timeout -k 5 60 "$adb" shell dumpsys package com.navitel | tr -d '\r' > "$work/package-$phase.txt"
}
check_synthetic before
query_package before
# Match a normal read-only Android system mount. This is inside the disposable
# emulator and does not change how any actual head unit is mounted.
echo 'Remount disposable emulator system read-only before testing update'
timeout -k 5 60 "$adb" shell mount -o ro,remount /system
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep ' /system ' > "$work/mount-system.txt"
grep -E ' /system [^ ]+ ro[, ]' "$work/mount-system.txt" || { cat "$work/mount-system.txt"; exit 1; }
echo 'Device-side md5 after read-only remount:'
md5sum "$work/old.apk"
timeout -k 5 120 "$adb" shell /system/bin/md5 /system/priv-app/Navitel-large.apk | tr -d '\r'

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
  echo 'System APK read-back already differs after negative control'
  sha256sum "$work/old.apk" "$work/stock-after-negative.apk"
  echo 'Host and emulator md5 checks (md5 used only to diagnose transport versus source):'
  md5sum "$work/old.apk" "$work/stock-after-negative.apk"
  timeout -k 5 120 "$adb" shell /system/bin/md5 /system/priv-app/Navitel-large.apk | tr -d '\r' || true
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

echo 'Launch new activity with empty virtual SD and isolated network; no license or account'
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n com.navitel/com.navitel.app.MainActivity > "$work/start.txt" 2>&1 || true
sleep 12
timeout -k 5 60 "$adb" shell dumpsys activity activities > "$work/activities.txt" 2>&1 || true
timeout -k 5 60 "$adb" logcat -d -v brief > "$work/app-log.txt" 2>&1 || true
check_synthetic launch

echo 'Full reboot of disposable x86 virtual device, then verify package and synthetic data'
timeout -k 5 30 "$adb" shell cat /proc/sys/kernel/random/boot_id | tr -d '\r' > "$work/boot-id-before.txt"
grep -E '^[0-9a-f-]{36}$' "$work/boot-id-before.txt"
timeout -k 10 60 "$adb" reboot
rebooted=no
for i in $(seq 1 120); do
  current_id=$(timeout -k 2 5 "$adb" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
  state=$(timeout -k 2 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [[ "$current_id" =~ ^[0-9a-f-]{36}$ ]] && [ "$current_id" != "$(cat "$work/boot-id-before.txt")" ] && [ "$state" = 1 ]; then
    printf '%s\n' "$current_id" > "$work/boot-id-after.txt"; rebooted=yes; break
  fi
  sleep 3
done
[ "$rebooted" = yes ] || { echo 'Did not observe completed full emulator reboot with changed boot ID'; exit 1; }
query_package fullreboot
grep -E '^package:/data/app/com\.navitel[^/]*\.apk$' "$work/path-fullreboot.txt"
grep -F 'versionCode=360622024' "$work/package-fullreboot.txt"
uid_reboot=$(sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' "$work/package-fullreboot.txt" | head -1)
test "$uid_before" = "$uid_reboot"
check_synthetic fullreboot
timeout -k 10 300 "$adb" pull /system/priv-app/Navitel-large.apk "$work/stock-after-fullreboot.apk" >/dev/null
cmp "$work/old.apk" "$work/stock-after-fullreboot.apk"
{
  echo '# Same-signature Navitel update via stock-derived Amaze and installer on disposable Android 4.4.2 x86'
  echo 'Generic emulator, not the device or vendor PackageManager; host emulator network blocked.'
  echo 'No real maps, license, accounts, user data or SD; no APKs published. Empty virtual SD only.'
  echo 'ADB prepared and observed the emulator and tapped its virtual UI; update was initiated by the stock-derived Amaze app and installed by the stock-derived PackageInstaller; generic emulator framework and virtual storage only.'
  echo 'Initial stock-derived Navitel certificate equals the verified AOSP testkey certificate:'
  echo "$keycert"
  echo 'Candidate re-signed in disposable CI only; not an installation recommendation.'
  cat "$work/compare.txt"
  echo 'Negative control: original differently signed candidate rejected; installer result:'
  grep -E 'Failure \[' "$work/negative.txt" | tr -d '\r'
  echo 'Matching certificate candidate installed via Amaze and PackageInstaller as data update; original emulator system APK unchanged: yes.'
  echo 'Emulator system mounted read-only during update:'; cat "$work/mount-system.txt"
  echo "UID before/after/userspace restart/full emulator reboot: $uid_before/$uid_after/$uid_restart/$uid_reboot"
  echo 'Full virtual device reboot confirmed via changed kernel boot ID; system APK still matched afterward.'
  echo 'Stock-derived PackageInstaller and Amaze paths:'; cat "$work/installer-path.txt" "$work/amaze-path.txt"
  echo '## Package paths and selected version'
  cat "$work/path-before.txt" "$work/path-after.txt" "$work/path-restart.txt" "$work/path-fullreboot.txt"
  grep -E 'versionCode=|versionName=|codePath=' "$work/package-restart.txt" | head -10
  echo 'Synthetic marker and preferences for Navitel and one independent fixture app survived install, userspace restart, launch attempt, and full emulator reboot: yes.'
  echo '## Launch attempt (no activation asserted)'
  tr -d '\r' < "$work/start.txt"
  tr -d '\r' < "$work/activities.txt" | grep -E 'mResumedActivity|mFocusedActivity' | head -5 || true
  tr -d '\r' < "$work/app-log.txt" | grep -iE 'FATAL EXCEPTION|Fatal signal|com.navitel.*(crash|died)' | tail -10 || true
  echo 'Generic emulator full reboot is not real-device hibernate. App behavior, rollback, settings and all data preservation remain unverified.'
} > reports/navitel-stock-installer-amaze-lab.txt

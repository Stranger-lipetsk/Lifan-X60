#!/usr/bin/env bash
# Disposable GitHub Actions emulator only. Never run on a head unit.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/storage-vfat-probe-lab.log") 2>&1
work=$(mktemp -d /tmp/storage-vfat-probe.XXXXXX)
chmod 0755 "$work"
mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"
mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq iptables unzip zip openssl e2fsprogs
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;x86'
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
test -s "$jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n backup_x86 -k 'system-images;android-19;default;x86' -c 512M >/dev/null
sudo useradd --system --create-home --user-group storagegrouplab
emu_uid=$(id -u storagegrouplab)
sudo chown -R storagegrouplab:storagegrouplab "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status); emulator diagnostics:"
    tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'X60BackupCaller|X60RestoreCaller|X60SyntheticTarget|BackupManagerService|FATAL EXCEPTION' | tail -80 || true
  fi
  sudo pkill -TERM -u storagegrouplab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4/IPv6 blocked"
sudo -u storagegrouplab env HOME=/home/storagegrouplab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
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


echo 'Obtain checked stock image, extract only permission map for comparison'
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" system.img > "$work/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $work/system.img" | sha256sum -c -
debugfs -R "dump /etc/permissions/platform.xml $work/stock-platform.xml" "$work/system.img" >/dev/null 2>&1
test -s "$work/stock-platform.xml"
timeout -k 5 30 "$adb" root || true
timeout -k 5 90 "$adb" wait-for-device
timeout -k 5 30 "$adb" shell id | grep -F 'uid=0'
timeout -k 5 60 "$adb" remount | grep -i 'remount succeeded'
timeout -k 10 120 "$adb" pull /system/etc/permissions/platform.xml "$work/generic-platform.xml" >/dev/null
python3 - "$work/stock-platform.xml" "$work/generic-platform.xml" "$work/emulator-platform.xml" <<'PY2'
import sys, xml.etree.ElementTree as ET
name = 'android.permission.WRITE_EXTERNAL_STORAGE'
stock = ET.parse(sys.argv[1])
generic = ET.parse(sys.argv[2])
stock_items = [x for x in stock.getroot().findall('permission') if x.get('name') == name]
generic_items = [x for x in generic.getroot().findall('permission') if x.get('name') == name]
if len(stock_items) != 1 or len(generic_items) != 1: raise SystemExit('Expected one storage mapping')
groups = [e.get('gid') for e in stock_items[0].findall('group')]
print('Stock groups:', groups)
if set(groups) != {'sdcard_r', 'sdcard_rw', 'media_rw'}: raise SystemExit('Unexpected stock storage mapping')
entry = generic_items[0]
for child in list(entry):
    if child.tag == 'group': entry.remove(child)
for gid in groups: ET.SubElement(entry, 'group', {'gid': gid})
generic.write(sys.argv[3], encoding='utf-8', xml_declaration=True)
print('Only generic emulator WRITE_EXTERNAL_STORAGE groups changed to match stock mapping')
PY2
# Only this disposable emulator is modified. Restart Android so PackageManager reloads group rules.
timeout -k 5 30 "$adb" shell setprop sys.boot_completed 0
timeout -k 5 30 "$adb" shell stop
timeout -k 10 120 "$adb" push "$work/emulator-platform.xml" /system/etc/permissions/platform.xml
timeout -k 5 30 "$adb" shell chmod 0644 /system/etc/permissions/platform.xml
timeout -k 5 30 "$adb" shell restorecon /system/etc/permissions/platform.xml || true
timeout -k 5 30 "$adb" shell start
booted=no
for i in $(seq 1 100); do
  if [ "$(timeout -k 5 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  sleep 3
done
[ "$booted" = yes ] || { echo 'Userspace restart timeout'; exit 1; }
timeout -k 10 120 "$adb" pull /system/etc/permissions/platform.xml "$work/platform-readback.xml" >/dev/null
cmp "$work/emulator-platform.xml" "$work/platform-readback.xml"
# The virtual SD belongs to the disposable AVD, never a real USB device.
echo 'Wait for and verify the AVD virtual FAT filesystem and its actual mount options'
ready=no
for i in $(seq 1 50); do
  timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' > "$work/mounts.txt"
  if grep -E ' /mnt/media_rw/sdcard vfat rw[, ]' "$work/mounts.txt" > "$work/mock-dir.txt"; then ready=yes; break; fi
  sleep 2
done
[ "$ready" = yes ] || { echo 'Virtual SD VFAT mount absent'; cat "$work/mounts.txt"; exit 1; }
grep -E 'uid=1023,gid=1023' "$work/mock-dir.txt"
grep -E 'fmask=0007,dmask=0007' "$work/mock-dir.txt"
cat "$work/mock-dir.txt"
timeout -k 5 30 "$adb" shell 'ls -ldn /mnt /mnt/media_rw /mnt/media_rw/sdcard; getenforce' | tr -d '\r' | tee "$work/mount-parents.txt"
timeout -k 5 30 "$adb" shell 'if [ -e /mnt/media_rw/sdcard/x60-synthetic-probe.txt ]; then echo UNEXPECTED_FILE; else echo SYNTHETIC_PATH_EMPTY; fi' | tr -d '\r' | grep -Fx SYNTHETIC_PATH_EMPTY

echo 'Build two test-key-signed apps, same code, with/without external storage permission'
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
for ext in x509.pem pk8; do
  gh api "repos/aosp-mirror/platform_build/contents/target/product/security/testkey.$ext?ref=$ref" --jq .content | base64 -d > "$work/testkey.$ext"
done
src=tests/fixtures/storage-vfat-probe
mkdir -p "$work/classes" "$work/dex"
find "$src/src" -name '*.java' | sort > "$work/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/classes" @"$work/sources.txt"
find "$work/classes" -name '*.class' > "$work/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/dex" @"$work/classes.txt"
cp "$work/dex/classes.dex" "$work/classes.dex"
for mode in negative positive; do
  mkdir -p "$work/$mode-manifest"
  cp "$src/$mode.xml" "$work/$mode-manifest/AndroidManifest.xml"
  "$bt/aapt" package -f -M "$work/$mode-manifest/AndroidManifest.xml" -I "$jar" -F "$work/$mode-unsigned.apk"
  (cd "$work" && zip -q -u "$mode-unsigned.apk" classes.dex)
  "$bt/zipalign" -f 4 "$work/$mode-unsigned.apk" "$work/$mode-aligned.apk"
  "$bt/apksigner" sign --key "$work/testkey.pk8" --cert "$work/testkey.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/$mode.apk" "$work/$mode-aligned.apk"
  timeout -k 10 120 "$adb" install "$work/$mode.apk" > "$work/$mode-install.txt" 2>&1
  grep -F Success "$work/$mode-install.txt"
done
run_probe() {
  local pkg=$1 name=$2 expected=$3 activity=$4
  timeout -k 5 30 "$adb" logcat -c
  timeout -k 5 60 "$adb" shell am start -n "$pkg/ru.lifanx60.storagegrouplab.$activity" > "$work/$name-start.txt" 2>&1
  for i in $(seq 1 30); do
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/$name-log.txt" 2>&1 || true
    if grep -Eq 'SYNTHETIC_WRITE_READ_(OK|FAILED)' "$work/$name-log.txt"; then break; fi
    sleep 2
  done
  grep -F X60StorageGroupLab "$work/$name-log.txt" | head -25 || true
  grep -F "$expected" "$work/$name-log.txt"
}
echo 'Baseline generic emulator parent is mode 0700: record access before changing anything'
run_probe ru.lifanx60.storagegroupwith positive-initial SYNTHETIC_WRITE_READ_FAILED MainActivity
grep -F 'EACCES (Permission denied)' "$work/positive-initial-log.txt"
grep -E 'Groups:.*[[:space:]]1023([[:space:]]|$)' "$work/positive-initial-log.txt"
# LAB ONLY: bind this disposable emulator's FAT mount below a synthetic
# parent with the mode and ownership in stock init.rc. No real-device changes.
timeout -k 5 30 "$adb" shell 'mkdir -p /data/local/tmp/x60-vfat-model/sdcard && chown 1023:1023 /data/local/tmp/x60-vfat-model && chmod 0751 /data/local/tmp/x60-vfat-model && mount -o bind /mnt/media_rw/sdcard /data/local/tmp/x60-vfat-model/sdcard && ls -ldn /data/local/tmp/x60-vfat-model && echo STOCK_PARENT_MODEL_SET' | tr -d '\r' | tee "$work/parent-model.txt"
grep -Fx STOCK_PARENT_MODEL_SET "$work/parent-model.txt"
grep -E '^drwxr-x--x[[:space:]]+1023[[:space:]]+1023' "$work/parent-model.txt"
timeout -k 5 30 "$adb" shell cat /proc/mounts | tr -d '\r' | grep -E ' /data/local/tmp/x60-vfat-model/sdcard vfat rw[, ]' | tee -a "$work/parent-model.txt"
run_probe ru.lifanx60.storagegroupwithout negative SYNTHETIC_WRITE_READ_FAILED ModelActivity
grep -F 'EACCES (Permission denied)' "$work/negative-log.txt"
if grep -E 'Groups:.*[[:space:]]1023([[:space:]]|$)' "$work/negative-log.txt"; then echo 'Unexpected media_rw group in negative control'; exit 1; fi
timeout -k 5 30 "$adb" shell 'if [ -e /mnt/media_rw/sdcard/x60-synthetic-probe.txt ]; then echo UNEXPECTED_FILE; else echo SYNTHETIC_PATH_EMPTY; fi' | tr -d '\r' | grep -Fx SYNTHETIC_PATH_EMPTY
run_probe ru.lifanx60.storagegroupwith positive SYNTHETIC_WRITE_READ_OK ModelActivity
grep -E 'Groups:.*[[:space:]]1023([[:space:]]|$)' "$work/positive-log.txt"
timeout -k 5 60 "$adb" pull /mnt/media_rw/sdcard/x60-synthetic-probe.txt "$work/readback.txt" >/dev/null
printf 'X60-LAB\n' > "$work/expected.txt"
cmp "$work/expected.txt" "$work/readback.txt"
{
  echo '# Synthetic virtual VFAT and modeled parent permissions on disposable Android 4.4.2 x86'
  echo 'The target is the disposable emulator virtual SD FAT filesystem, not real USB or the head unit.'
  echo 'Generic platform.xml WRITE_EXTERNAL_STORAGE group mapping replaced with the mapping read from the checked stock image; other framework, kernel and SELinux are emulator only.'
  echo 'Unprivileged app signed with public testkey, no shared UID; ADB only prepared and observed the emulator.'
  echo "Fingerprint: $fingerprint; hardware: $hardware"
  echo 'Virtual SD mount options:'; cat "$work/mock-dir.txt"
  echo 'Generic parent directory and emulator SELinux mode before adjustment:'; cat "$work/mount-parents.txt"
  echo '## Baseline: app has media_rw group but generic parent mode 0700 blocks access'
  grep -E 'Groups:|UID=|SYNTHETIC_WRITE_READ_FAILED|EACCES \(Permission denied\)' "$work/positive-initial-log.txt" | head -8
  echo '## FAT bind mount below emulator-only parent permission model matching stock init.rc'; cat "$work/parent-model.txt"
  echo '## Negative app without WRITE_EXTERNAL_STORAGE'; grep -F X60StorageGroupLab "$work/negative-log.txt" | head -20
  echo '## Positive app with WRITE_EXTERNAL_STORAGE'; grep -F X60StorageGroupLab "$work/positive-log.txt" | head -20
  echo 'Synthetic bytes fsynced, read by app and compared again by host: yes.'
  echo 'Result does not prove actual USB mount flags, DAC, SELinux, mount lifetime, free space or successful writing on the head unit.'
} > reports/stock-storage-vfat-emulator.txt

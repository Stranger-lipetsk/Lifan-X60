#!/usr/bin/env bash
# Disposable GitHub Actions emulator only. Never run on a head unit.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/system-prop-arm-lab.log") 2>&1
work=$(mktemp -d /tmp/system-prop-arm-lab.XXXXXX)
chmod 0755 "$work"
mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"
mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq iptables unzip zip openssl e2fsprogs android-sdk-libsparse-utils
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'platforms;android-19' 'system-images;android-19;default;armeabi-v7a'
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar="$sdk/platforms/android-19/android.jar"
test -s "$jar"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n backup_arm -k 'system-images;android-19;default;armeabi-v7a' -c 512M >/dev/null
# Create a generic ARM system image offline; substitute only stock-derived
# services.jar. This is an emulator test and never a firmware for flashing.
curl -fLsS --retry 3 --max-time 120 https://dl.google.com/android/repository/tools_r25.2.5-linux.zip -o "$work/legacy.zip"
echo "577516819c8b5fae680f049d39014ff1ba4af870b687cab10595783e6f22d33e  $work/legacy.zip" | sha256sum -c -
mkdir -p "$work/legacy"; unzip -q "$work/legacy.zip" -d "$work/legacy"; chmod -R a+rX "$work/legacy"
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" system.img > "$work/stock-system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $work/stock-system.img" | sha256sum -c -
debugfs -R "dump /framework/services.jar $work/stock-services.jar" "$work/stock-system.img" >/dev/null 2>&1
echo "998f7b8558e55fa4d40ea676414cb4bf35f9c9b6f0eae3c81f037186229c403c  $work/stock-services.jar" | sha256sum -c -
generic="$sdk/system-images/android-19/default/armeabi-v7a/system.img"
magic=$(od -An -tx1 -N4 "$generic" | tr -d ' \n')
if [ "$magic" = '3aff26ed' ]; then simg2img "$generic" "$work/offline-system.img"; else cp --sparse=always "$generic" "$work/offline-system.img"; fi
rc=0; e2fsck -fy "$work/offline-system.img" || rc=$?; [ "$rc" -le 1 ]
resize2fs "$work/offline-system.img" 1024M
rc=0; e2fsck -fy "$work/offline-system.img" || rc=$?; [ "$rc" -le 1 ]
debugfs -w -R 'rm /framework/services.jar' "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'rm /framework/services.odex' "$work/offline-system.img" >/dev/null 2>&1 || true
debugfs -w -R "write $work/stock-services.jar /framework/services.jar" "$work/offline-system.img" >/dev/null 2>&1
debugfs -w -R 'set_inode_field /framework/services.jar mode 0100644' "$work/offline-system.img" >/dev/null 2>&1
printf 'u:object_r:system_file:s0\0' > "$work/system-context"
debugfs -w -R "ea_set -f $work/system-context /framework/services.jar security.selinux" "$work/offline-system.img" >/dev/null 2>&1
debugfs -R "dump /framework/services.jar $work/services-readback.jar" "$work/offline-system.img" >/dev/null 2>&1
cmp "$work/services-readback.jar" "$work/stock-services.jar"
chmod a+r "$work/offline-system.img"

sudo useradd --system --create-home --user-group systemproparmlab
emu_uid=$(id -u systemproparmlab)
sudo chown -R systemproparmlab:systemproparmlab "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status); emulator diagnostics:"
    tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'X60SystemPropLab|PackageManager|FATAL EXCEPTION' | tail -80 || true
  fi
  sudo pkill -TERM -u systemproparmlab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4/IPv6 blocked"
sudo -u systemproparmlab env HOME=/home/systemproparmlab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
  "$work/legacy/tools/emulator" -avd backup_arm -port 5554 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -partition-size 1024 -system "$work/offline-system.img" > "$work/emulator.log" 2>&1 &
pid=$!
timeout -k 5 300 "$adb" wait-for-device
booted=no
for i in $(seq 1 180); do
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

echo 'Verify stock-derived services.jar from running ARM emulator'
timeout -k 10 120 "$adb" pull /system/framework/services.jar "$work/runtime-services.jar" >/dev/null
cmp "$work/runtime-services.jar" "$work/stock-services.jar"
server_pid=$(timeout -k 5 30 "$adb" shell ps | tr -d '\r' | awk '$NF == "system_server" && !seen++ {print $2}')
case "$server_pid" in ''|*[!0-9]*) echo 'Missing system_server PID'; exit 1;; esac
timeout -k 5 30 "$adb" shell "cat /proc/$server_pid/maps" | tr -d '\r' | grep -F 'system@framework@services.jar@classes.dex' > "$work/maps.txt"

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
echo 'Check emulator shell package certificate and manifest'
timeout -k 10 120 "$adb" pull /system/priv-app/Shell.apk "$work/shell.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/shell.apk" > "$work/shell-cert.txt"
shellcert=$(sed -n 's/^V1 Signer: certificate SHA-256 digest: //p; s/^Signer #1 certificate SHA-256 digest: //p' "$work/shell-cert.txt" | head -1)
test "$shellcert" = "$actual" || { echo 'Emulator shell certificate differs from platform'; exit 1; }
"$bt/aapt" dump xmltree "$work/shell.apk" AndroidManifest.xml > "$work/shell-manifest.txt"
grep -F 'android.uid.shell' "$work/shell-manifest.txt"

echo 'Build guarded generic-emulator fixture; no APK is published'
src=tests/fixtures/system-prop-lab
mkdir -p "$work/classes" "$work/dex"
"$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/unsigned.apk"
mkdir -p "$work/negative"
sed -e 's/ru.lifanx60.systempropfixture/ru.lifanx60.systempropnegative/' -e 's/ android:sharedUserId="android.uid.system"//' "$src/AndroidManifest.xml" > "$work/negative/AndroidManifest.xml"
# The negative uses the same Java activity class but an ordinary application UID.
sed -i 's/android:name=".MainActivity"/android:name="ru.lifanx60.systempropfixture.MainActivity"/' "$work/negative/AndroidManifest.xml"
"$bt/aapt" package -f -M "$work/negative/AndroidManifest.xml" -I "$jar" -F "$work/negative-unsigned.apk"
find "$src/src" -name '*.java' | sort > "$work/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/classes" @"$work/sources.txt"
find "$work/classes" -name '*.class' > "$work/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/dex" @"$work/classes.txt"
cp "$work/dex/classes.dex" "$work/classes.dex"
for which in unsigned negative-unsigned; do
  (cd "$work" && zip -q -u "$which.apk" classes.dex)
  "$bt/zipalign" -f 4 "$work/$which.apk" "$work/$which-aligned.apk"
  "$bt/apksigner" sign --key "$work/platform.pk8" --cert "$work/platform.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/$which-signed.apk" "$work/$which-aligned.apk"
done

echo 'Baseline adbd and security settings in generic emulator'
for prop in ro.secure ro.debuggable ro.adb.secure service.adb.tcp.port init.svc.adbd; do
  printf '%s=' "$prop"; "$adb" shell getprop "$prop" | tr -d '\r'; done | tee "$work/baseline.txt"
"$adb" shell id | tr -d '\r' | tee "$work/baseline-id.txt"
oldport=$("$adb" shell getprop service.adb.tcp.port | tr -d '\r')
test "$oldport" != 43127
"$adb" install "$work/negative-unsigned-signed.apk" | tee "$work/negative-install.txt"
grep -F Success "$work/negative-install.txt"
"$adb" logcat -c
"$adb" shell am start -n ru.lifanx60.systempropnegative/ru.lifanx60.systempropfixture.MainActivity
for i in $(seq 1 30); do
  "$adb" logcat -d -s X60SystemPropLab:I '*:S' > "$work/negative-log.txt" 2>&1
  grep -q 'OWN_UID=' "$work/negative-log.txt" && break
  sleep 1
done
cat "$work/negative-log.txt"
grep -q 'OWN_UID=' "$work/negative-log.txt"
! grep -q 'OWN_UID=1000 ' "$work/negative-log.txt"
test "$("$adb" shell getprop service.adb.tcp.port | tr -d '\r')" = "$oldport"

echo 'Positive control: platform-signed shared system UID in disposable emulator'
"$adb" shell ps > "$work/ps-before.txt"
"$adb" install "$work/unsigned-signed.apk" | tee "$work/system-install.txt"
grep -F Success "$work/system-install.txt"
"$adb" logcat -c
# Restart can disconnect this command; only the guarded app controls the property.
"$adb" shell am start -n ru.lifanx60.systempropfixture/.MainActivity > "$work/system-start.txt" 2>&1 || true
ready=no
for i in $(seq 1 90); do
  if timeout -k 3 5 "$adb" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r' | grep -qx 43127; then
    if timeout -k 3 5 "$adb" logcat -d -s X60SystemPropLab:I '*:S' > "$work/system-log.txt" 2>&1 && grep -q 'NO_RESTART_REQUESTED' "$work/system-log.txt"; then ready=yes; break; fi
  fi
  sleep 2
done
[ "$ready" = yes ] || { cat "$work/system-start.txt" "$work/system-log.txt" 2>/dev/null || true; exit 1; }
grep -F 'OWN_UID=1000 ' "$work/system-log.txt"; grep -F 'AFTER=43127' "$work/system-log.txt"; grep -F 'SYNTHETIC_ROOT_PROPERTY=1' "$work/system-log.txt"; grep -F 'NO_RESTART_REQUESTED' "$work/system-log.txt"
# Classic ARM qemud loses the host ADB transport when adbd is restarted.
# This separate ARM experiment intentionally does not restart it, so that
# both property writes can be observed. Restart was tested separately on x86.
echo 'ARM fixture intentionally did not restart adbd; no TCP test.'
{
  echo '# Platform-signed system UID property experiment: generic Android 4.4.2 ARM with stock-derived services.jar only'
  echo 'Disposable emulator; no head unit, real storage, user data, or user network accessed.'
  echo 'Host firewall blocks non-loopback emulator traffic. No LAN or TCP client was tested.'
  echo "Fingerprint: $fingerprint; hardware: $hardware; qemu: $qemu"
  echo 'Stock-derived services.jar compared byte-for-byte after boot; system_server mapped its generated dex.'
  echo 'Generic baseline properties:'; cat "$work/baseline.txt"; echo 'Generic baseline shell:'; cat "$work/baseline-id.txt"
  echo 'Same-signature ordinary UID negative control: property unchanged:'; grep -F 'OWN_UID=' "$work/negative-log.txt" | tail -1
  echo 'System UID fixture:'; grep -F 'OWN_UID=' "$work/system-log.txt" | tail -1; grep -F 'SYNTHETIC_ROOT_PROPERTY=' "$work/system-log.txt" | tail -1
  echo 'ARM fixture deliberately did not restart adbd; no TCP or restart behavior tested in ARM.'
  echo 'Emulator uses qemud transport; this does not test whether a physical device will listen on TCP.'
  echo 'Emulator adbd identity and behavior are NOT evidence of stock adbd privileges, network access, authentication or safe data backup on GU.'
  echo 'No application released; do not enable network ADB or use this test on a real head unit.'
} > reports/system-property-adb-arm-lab.txt

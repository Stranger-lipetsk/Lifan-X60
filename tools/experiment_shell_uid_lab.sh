#!/usr/bin/env bash
# Disposable GitHub Actions emulator only. Never run on a head unit.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/shell-uid-lab.log") 2>&1
work=$(mktemp -d /tmp/shell-uid-lab.XXXXXX)
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
sudo useradd --system --create-home --user-group shelluidlab
emu_uid=$(id -u shelluidlab)
sudo chown -R shelluidlab:shelluidlab "$ANDROID_AVD_HOME"
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Lab failed ($status); emulator diagnostics:"
    tail -45 "$work/emulator.log" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 20 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'X60ShellUidLab|PackageManager|FATAL EXCEPTION' | tail -80 || true
  fi
  sudo pkill -TERM -u shelluidlab 2>/dev/null || true
  [ "$blocked4" != yes ] || sudo iptables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT || true
  [ "$blocked6" != yes ] || sudo ip6tables -D OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT || true
}
trap cleanup EXIT
sudo iptables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT; blocked4=yes
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT; blocked6=yes
sudo iptables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d 127.0.0.0/8 -j REJECT
sudo ip6tables -C OUTPUT -m owner --uid-owner "$emu_uid" ! -d ::1/128 -j REJECT
echo "Emulator host UID $emu_uid: non-loopback IPv4/IPv6 blocked"
sudo -u shelluidlab env HOME=/home/shelluidlab ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
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
echo 'Check emulator shell package certificate and manifest'
timeout -k 10 120 "$adb" pull /system/priv-app/Shell.apk "$work/shell.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/shell.apk" > "$work/shell-cert.txt"
shellcert=$(sed -n 's/^V1 Signer: certificate SHA-256 digest: //p; s/^Signer #1 certificate SHA-256 digest: //p' "$work/shell-cert.txt" | head -1)
test "$shellcert" = "$actual" || { echo 'Emulator shell certificate differs from platform'; exit 1; }
"$bt/aapt" dump xmltree "$work/shell.apk" AndroidManifest.xml > "$work/shell-manifest.txt"
grep -F 'android.uid.shell' "$work/shell-manifest.txt"

echo 'Build UID-only fixture; no commands or access to other packages'
src=tests/fixtures/shell-uid-lab
mkdir -p "$work/classes" "$work/dex"
"$bt/aapt" package -f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/unsigned.apk"
find "$src/src" -name '*.java' | sort > "$work/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/classes" @"$work/sources.txt"
find "$work/classes" -name '*.class' > "$work/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/dex" @"$work/classes.txt"
cp "$work/dex/classes.dex" "$work/classes.dex"
(cd "$work" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
keytool -genkeypair -keystore "$work/negative.keystore" -storepass test-only -keypass test-only -alias negative -keyalg RSA -keysize 2048 -validity 10 -dname 'CN=Disposable negative control' >/dev/null 2>&1
"$bt/apksigner" sign --ks "$work/negative.keystore" --ks-pass pass:test-only --key-pass pass:test-only --min-sdk-version 19 --v1-signing-enabled true --out "$work/negative.apk" "$work/aligned.apk"
"$bt/apksigner" sign --key "$work/platform.pk8" --cert "$work/platform.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/platform.apk" "$work/aligned.apk"

echo 'Negative installation must be rejected for incompatible shared UID signature'
timeout -k 10 120 "$adb" install "$work/negative.apk" > "$work/negative.txt" 2>&1 || true
cat "$work/negative.txt"
grep -F 'INSTALL_FAILED_SHARED_USER_INCOMPATIBLE' "$work/negative.txt"
echo 'Platform-signed fixture installation'
timeout -k 10 120 "$adb" install "$work/platform.apk" > "$work/positive.txt" 2>&1 || true
cat "$work/positive.txt"
grep -F Success "$work/positive.txt"
timeout -k 5 30 "$adb" logcat -c
timeout -k 5 60 "$adb" shell am start -n ru.lifanx60.shelluidfixture/.MainActivity > "$work/start.txt" 2>&1
found=no
for i in $(seq 1 30); do
  timeout -k 5 30 "$adb" logcat -d -v brief > "$work/log.txt" 2>&1 || true
  if grep -Fq 'OWN_UID=' "$work/log.txt"; then found=yes; break; fi
  sleep 2
done
[ "$found" = yes ] || { echo 'Fixture did not report UID'; exit 1; }
grep -F 'OWN_UID=2000' "$work/log.txt"
timeout -k 5 60 "$adb" shell dumpsys package ru.lifanx60.shelluidfixture | tr -d '\r' > "$work/package.txt"
grep -E 'userId=2000|sharedUser=SharedUserSetting' "$work/package.txt" || true
{
  echo '# Shared shell UID: disposable generic Android 4.4.2 x86'
  echo 'Emulator only. Fixture reports its own UID; it does not execute su, read app data, or write to other apps.'
  echo 'ADB prepared and observed emulator. No real head unit, real user data, or real storage used.'
  echo "Fingerprint: $fingerprint; hardware: $hardware; emulator platform and shell cert match: $actual"
  echo 'Incorrectly signed shared UID fixture rejected: yes.'
  echo 'Platform-signed shared UID fixture installed and reported:'
  grep -F 'OWN_UID=' "$work/log.txt" | tail -1
  echo 'This does not test stock firmware, SELinux, su, remounting, storage access, data backup, or update.'
} > reports/shell-uid-lab.txt

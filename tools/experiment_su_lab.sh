#!/usr/bin/env bash
# Disposable generic ARM emulator only. Never run on a physical device.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable emulator only'; exit 1; }
export ANDROID_SERIAL=emulator-5554
exec > >(tee "$RUNNER_TEMP/su-lab.log") 2>&1
work=$(mktemp -d /tmp/su-lab.XXXXXX); chmod 0755 "$work"; mkdir -p reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
adb="$sdk/platform-tools/adb"
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip zip openssl iptables
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'platforms;android-19'
jar="$sdk/platforms/android-19/android.jar"
test -s "$jar"
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
sudo useradd --system --create-home --user-group sulabuser
emu_uid=$(id -u sulabuser)
sudo chown -R sulabuser:sulabuser "$ANDROID_AVD_HOME"
pid=''; blocked4=no; blocked6=no
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Failure ($status): emulator log"; tail -50 "$work/emulator.txt" 2>/dev/null || true
    timeout -k 5 10 "$adb" devices -l || true
    timeout -k 5 30 "$adb" logcat -d -v brief 2>/dev/null | grep -iE 'PackageManager|installd|X60SuLab|install|FATAL EXCEPTION' | tail -120 || true
    timeout -k 5 30 "$adb" shell dmesg 2>/dev/null | grep -iE 'ext4|read.only|error|avc:|denied' | tail -60 || true
    timeout -k 5 30 "$adb" shell 'ls -ldZ /data /data/data /data/data/ru.lifanx60.sulabshell /data/app-lib; getenforce' 2>/dev/null || true
  fi
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  sudo pkill -TERM -u sulabuser 2>/dev/null || true
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
  sudo -u sulabuser env HOME=/home/sulabuser ANDROID_HOME="$sdk" ANDROID_AVD_HOME="$ANDROID_AVD_HOME" \
    "$work/legacy/tools/emulator" -avd migration_arm -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader -engine classic -verbose >> "$work/emulator.txt" 2>&1 &
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
      ps -fu sulabuser || true
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
echo 'Trying remount of emulator system only'
timeout -k 5 60 "$adb" remount | tee "$work/remount.txt"
grep -iq 'remount succeeded' "$work/remount.txt" || { echo 'Cannot remount emulator system'; exit 1; }
timeout -k 5 30 "$adb" shell df /system | tr -d '\r'

echo 'Verify hardware and emulator guard before testing'
hardware=$(timeout -k 5 30 "$adb" shell getprop ro.hardware | tr -d '\r')
qemu=$(timeout -k 5 30 "$adb" shell getprop ro.kernel.qemu | tr -d '\r')
case "$hardware" in *goldfish*) ;; *) echo "Unexpected hardware: $hardware"; exit 1;; esac
[ "$qemu" = 1 ] || { echo 'Not the emulator'; exit 1; }
echo 'Copy only stock su binary into disposable emulator; never a physical device'
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" system.img > "$work/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $work/system.img" | sha256sum -c -
debugfs -R "dump /xbin/su $work/su" "$work/system.img" >/dev/null 2>&1
echo "13ac24ca792e36c9d0c32ec79bfaa03490492e71e9dfa11d712390e613dc7fb4  $work/su" | sha256sum -c -
timeout -k 10 120 "$adb" push "$work/su" /system/xbin/x60-lab-su
timeout -k 5 30 "$adb" shell chown 0:0 /system/xbin/x60-lab-su
timeout -k 5 30 "$adb" shell chmod 6755 /system/xbin/x60-lab-su
timeout -k 5 30 "$adb" shell ls -l /system/xbin/x60-lab-su | tr -d '\r' > "$work/mode.txt"
grep -E '^-rwsr-sr-x' "$work/mode.txt" || { echo 'Setuid/setgid mode missing'; exit 1; }
timeout -k 10 120 "$adb" pull /system/xbin/x60-lab-su "$work/copied-su" >/dev/null
cmp "$work/su" "$work/copied-su"

echo 'Use matching emulator platform key, not stock signing key'
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
for ext in x509.pem pk8; do gh api "repos/aosp-mirror/platform_build/contents/target/product/security/platform.$ext?ref=$ref" --jq .content | base64 -d > "$work/platform.$ext"; done
timeout -k 10 120 "$adb" pull /system/framework/framework-res.apk "$work/framework.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/framework.apk" > "$work/cert.txt"
actual=$(sed -n 's/^V1 Signer: certificate SHA-256 digest: //p; s/^Signer #1 certificate SHA-256 digest: //p' "$work/cert.txt" | head -1)
expected=$(openssl x509 -in "$work/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
test -n "$actual" && test "$actual" = "$expected" || { echo 'Emulator key mismatch'; exit 1; }
src=tests/fixtures/su-lab
mkdir -p "$work/classes" "$work/dex"
find "$src/src" -name '*.java' | sort > "$work/sources.txt"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/classes" @"$work/sources.txt"
find "$work/classes" -name '*.class' > "$work/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/dex" @"$work/classes.txt"
for name in ordinary shell; do
  mkdir -p "$work/$name"
  cp "$src/manifests/$name.xml" "$work/$name/AndroidManifest.xml"
  "$bt/aapt" package -f -M "$work/$name/AndroidManifest.xml" -I "$jar" -F "$work/$name/unsigned.apk"
  cp "$work/dex/classes.dex" "$work/$name/classes.dex"
  (cd "$work/$name" && zip -q -u unsigned.apk classes.dex)
  "$bt/zipalign" -f 4 "$work/$name/unsigned.apk" "$work/$name/aligned.apk"
  "$bt/apksigner" sign --key "$work/platform.pk8" --cert "$work/platform.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/$name.apk" "$work/$name/aligned.apk"
  timeout -k 10 120 "$adb" install "$work/$name.apk" > "$work/$name-install.txt" 2>&1 || true
  if ! grep -Fq Success "$work/$name-install.txt"; then
    cat "$work/$name-install.txt"
    [ "$name" = shell ] || exit 1
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/shell-install-log.txt" 2>&1 || true
    printf '%s\n' 'Shell shared UID fixture installation failed; no app test performed.' > "$work/shell-result.txt"
    grep -iE 'PackageManager|installd|avc:|denied' "$work/shell-install-log.txt" | tail -15 >> "$work/shell-result.txt" || true
    continue
  fi
  timeout -k 5 30 "$adb" logcat -c
  timeout -k 5 60 "$adb" shell am start -n "ru.lifanx60.sulab$name/ru.lifanx60.sulab.MainActivity" > "$work/$name-start.txt" 2>&1
  doneflag=no
  for i in $(seq 1 40); do
    timeout -k 5 30 "$adb" logcat -d -v brief > "$work/$name-log.txt" 2>&1 || true
    if grep -Eq 'X60SuLab.*(EXIT=|FAILED)' "$work/$name-log.txt"; then doneflag=yes; break; fi
    sleep 3
  done
  [ "$doneflag" = yes ] || { echo "$name test did not finish"; exit 1; }
  grep -F 'X60SuLab' "$work/$name-log.txt" | tr -d '\r' > "$work/$name-result.txt"
  cat "$work/$name-result.txt"
done
if grep -Fq 'OWN_UID=' "$work/shell-result.txt"; then grep -F 'OWN_UID=2000' "$work/shell-result.txt"; fi
grep -E 'OWN_UID=1[0-9]{4}' "$work/ordinary-result.txt"

echo 'Separate shell-context control: unroot adb on disposable emulator, then fixed identity check'
timeout -k 5 60 "$adb" unroot > "$work/unroot.txt" 2>&1 || true
timeout -k 5 120 "$adb" wait-for-device
shell_id=$(timeout -k 5 30 "$adb" shell id | tr -d '\r')
echo "ADB shell identity: $shell_id"
grep -q 'uid=2000' <<< "$shell_id" || { echo 'Did not obtain unprivileged emulator ADB shell'; exit 1; }
timeout -k 5 60 "$adb" shell /system/xbin/x60-lab-su 0 /system/bin/id > "$work/adb-su-result.txt" 2>&1 || true
tr -d '\r' < "$work/adb-su-result.txt" > "$work/adb-su-clean.txt"
cat "$work/adb-su-clean.txt"
{
  echo "Unprivileged emulator ADB shell before su: $shell_id"
  cat "$work/adb-su-clean.txt"
} > "$work/shell-context-result.txt"
{
  echo '# Stock-derived su identity check in disposable ARM Android 4.4.2 emulator'
  echo 'No real device, applications, data or external media. Fixture invokes only a fixed identity check.'
  echo 'Stock su binary copied to emulator system filesystem with mode 06755; emulator policy/kernel, not stock head unit.'
  echo "Fingerprint: $(cat "$work/fingerprint.txt"); hardware: $hardware; emulator certificate: $actual"
  echo 'The ADB transport was used to prepare and observe the emulator. No APKs or su binary published.'
  echo '## Ordinary application'; cat "$work/ordinary-result.txt"
  echo '## Shell shared UID application'; cat "$work/shell-result.txt"
  echo '## Separate emulator ADB shell-context control, not an app'; cat "$work/shell-context-result.txt"
  echo 'ADB shell and app SELinux contexts may differ. Even a positive result does not prove actual device installation, privileges, storage access or safety.'
} > reports/su-identity-lab.txt

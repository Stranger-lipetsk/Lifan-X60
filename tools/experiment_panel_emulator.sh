#!/usr/bin/env bash
# Disposable emulator integration experiment only: never touch a head unit or publish APKs.
set -euo pipefail
exec > >(tee "$RUNNER_TEMP/panel-emulator.log") 2>&1
work="$RUNNER_TEMP/panel-lab"
mkdir -p "$work" reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar=$(find "$sdk/platforms" -name android.jar | sort -V | tail -1)
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"
mkdir -p "$ANDROID_AVD_HOME"

echo 'Phase 1: obtain and verify exact stock-derived Launcher2'
gh release download 'рабочая-с-лаунчером' -p system.img -D "$work"
echo "79df29ec1ea97fd2e1da605c9651c6e5cce9d05d79518ff8e3e7d1dd16553dba  $work/system.img" | sha256sum -c -
debugfs -R "dump /priv-app/Launcher2.apk $work/stock-launcher.apk" "$work/system.img" >/dev/null 2>&1
echo "82787a6007589a169242f2c1391252342a9824748a8b469d1d522acab83458e6  $work/stock-launcher.apk" | sha256sum -c -
unzip -p "$work/stock-launcher.apk" AndroidManifest.xml > "$work/old-manifest"
python3 tools/experiment_launcher_manifest.py "$work/old-manifest" "$work/new-manifest"
python3 - "$work/stock-launcher.apk" "$work/new-manifest" "$work/launcher-unsigned.apk" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as old, zipfile.ZipFile(sys.argv[3], 'w') as out:
    entries = old.infolist()
    if len({e.filename for e in entries}) != len(entries): raise SystemExit('Duplicate entries')
    for entry in entries:
        if entry.filename.upper().startswith('META-INF/'): continue
        out.writestr(entry, open(sys.argv[2], 'rb').read() if entry.filename == 'AndroidManifest.xml' else old.read(entry))
PY
"$bt/zipalign" -f 4 "$work/launcher-unsigned.apk" "$work/launcher-aligned.apk"

echo 'Phase 2: build disposable panel and mock HOME'
keytool -genkeypair -keystore "$work/temp.keystore" -storepass test-only -keypass test-only \
  -alias emulator-test -keyalg RSA -keysize 2048 -validity 1000 -dname 'CN=Disposable emulator panel test' >/dev/null 2>&1
build_test_apk() {
  local name=$1 src=$2 java=$3
  mkdir -p "$work/$name/classes" "$work/$name/dex"
  local args=(-f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/$name/unsigned.apk")
  [ ! -d "$src/res" ] || args+=(-S "$src/res")
  "$bt/aapt" package "${args[@]}"
  javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/$name/classes" "$src/$java"
  find "$work/$name/classes" -name '*.class' > "$work/$name/classes.txt"
  "$bt/d8" --lib "$jar" --min-api 19 --output "$work/$name/dex" @"$work/$name/classes.txt"
  cp "$work/$name/dex/classes.dex" "$work/$name/classes.dex"
  (cd "$work/$name" && zip -q -u unsigned.apk classes.dex)
  "$bt/zipalign" -f 4 "$work/$name/unsigned.apk" "$work/$name/aligned.apk"
  "$bt/apksigner" sign --ks "$work/temp.keystore" --ks-pass pass:test-only --key-pass pass:test-only \
    --min-sdk-version 19 --v1-signing-enabled true --out "$work/$name.apk" "$work/$name/aligned.apk"
  "$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 "$work/$name.apk"
}
build_test_apk panel launcher-panel-integrated src/ru/lifanx60/panel/MainActivity.java
build_test_apk fakehome tests/fixtures/launcher-home src/tw/com/elead/el830/home/Home.java
"$bt/aapt" dump badging "$work/panel.apk" | grep -E "package:|sdkVersion:|launchable-activity:"
gh release download v3.5.3 --repo TeamAmaze/AmazeFileManager -p app-fdroid-release.apk -D "$work"
echo "2a9bc50c6672b1cb6efdfbd9bd9149bf280274e386305663163cc365abd393f3  $work/app-fdroid-release.apk" | sha256sum -c -

echo 'Phase 3: boot disposable generic x86 emulator'
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'system-images;android-19;default;x86'
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n panel_api19 -k 'system-images;android-19;default;x86' -c 512M >/dev/null
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
"$sdk/emulator/emulator" -avd panel_api19 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -no-metrics > "$work/emulator.txt" 2>&1 &
pid=$!
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Emulator diagnostics on failure ($status):"
    tail -50 "$work/emulator.txt" || true
    "$adb" devices -l || true
  fi
  kill "$pid" 2>/dev/null || true
}
trap cleanup EXIT
timeout 120 "$adb" wait-for-device
booted=no
for i in $(seq 1 100); do
  if [ "$(timeout 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  kill -0 "$pid" 2>/dev/null || { echo 'Emulator exited early'; exit 1; }
  sleep 3
done
[ "$booted" = yes ] || { echo 'Emulator failed to boot'; exit 1; }
"$adb" root >/dev/null || true
timeout 90 "$adb" wait-for-device
echo "Emulator: $("$adb" shell getprop ro.build.fingerprint | tr -d '\r')"

echo 'Phase 4: match emulator signer and install modified stock Launcher2'
path=$("$adb" shell pm path com.android.launcher | tr -d '\r' | sed -n 's/^package://p' | head -1)
[ -n "$path" ] || { echo 'Default emulator launcher missing'; exit 1; }
"$adb" pull "$path" "$work/emulator-launcher.apk" >/dev/null
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --print-certs "$work/emulator-launcher.apk" > "$work/emulator-certs.txt"
cert=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p; s/^V1 Signer: certificate SHA-256 digest: //p' "$work/emulator-certs.txt" | head -1)
[ -n "$cert" ] || { cat "$work/emulator-certs.txt"; exit 1; }
echo "Emulator launcher certificate SHA-256: $cert"
ref=54004d146e0532a5d2ded2bbca55d496e081c08b
match=''
for name in platform shared testkey; do
  for ext in x509.pem pk8; do gh api "repos/aosp-mirror/platform_build/contents/target/product/security/$name.$ext?ref=$ref" --jq .content | base64 -d > "$work/$name.$ext"; done
  actual=$(openssl x509 -in "$work/$name.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
  if [ "$actual" = "$cert" ]; then match="$name"; break; fi
done
[ -n "$match" ] || { echo 'No matching public AOSP test certificate; no update attempted'; exit 1; }
echo "Matched emulator-only AOSP certificate: $match"
"$bt/apksigner" sign --key "$work/$match.pk8" --cert "$work/$match.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/launcher-emulator-only.apk" "$work/launcher-aligned.apk"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --verbose --print-certs "$work/launcher-emulator-only.apk" > "$work/launcher-verify.txt"
python3 tools/compare_apk_payload.py "$work/stock-launcher.apk" "$work/launcher-emulator-only.apk" AndroidManifest.xml > "$work/payload.txt"
"$bt/aapt" dump xmltree "$work/launcher-emulator-only.apk" AndroidManifest.xml > "$work/manifest.txt"
if grep -qF 'android.intent.category.HOME' "$work/manifest.txt"; then echo 'HOME remains'; exit 1; fi
"$adb" install "$work/fakehome.apk" > "$work/install-home.txt" 2>&1
grep -q Success "$work/install-home.txt"
"$adb" install -r "$work/launcher-emulator-only.apk" > "$work/install-launcher.txt" 2>&1 || { cat "$work/install-launcher.txt"; exit 1; }
grep -q Success "$work/install-launcher.txt"
"$adb" install "$work/panel.apk" > "$work/install-panel.txt" 2>&1
grep -q Success "$work/install-panel.txt"
"$adb" install "$work/app-fdroid-release.apk" > "$work/install-amaze.txt" 2>&1
grep -q Success "$work/install-amaze.txt"
uid=$("$adb" shell dumpsys package com.amaze.filemanager | tr -d '\r' | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -1)
case "$uid" in ''|*[!0-9]*) echo 'Amaze UID missing'; exit 1;; esac
"$adb" shell iptables -I OUTPUT 1 -m owner --uid-owner "$uid" -j REJECT
"$adb" shell iptables -C OUTPUT -m owner --uid-owner "$uid" -j REJECT

echo 'Phase 5: verify HOME resolution and panel buttons'
"$adb" logcat -c
"$adb" logcat -v brief > "$work/logcat.txt" 2>&1 &
logpid=$!
timeout 30 "$adb" shell am start -W -a android.intent.action.MAIN -c android.intent.category.HOME > "$work/home-result.txt" 2>&1
cat "$work/home-result.txt"
grep -q 'tw.com.elead.el830.home/.Home' "$work/home-result.txt" || { echo 'HOME did not resolve to fake Home'; exit 1; }
open_panel() {
  timeout 30 "$adb" shell am start -W -n ru.lifanx60.panel/.MainActivity > "$work/panel-result.txt" 2>&1
  grep -q 'Status: ok' "$work/panel-result.txt"
}
tap_label() {
  local label="$1"
  timeout 45 "$adb" shell uiautomator dump /sdcard/panel-ui.xml > "$work/ui-dump.txt" 2>&1
  "$adb" pull /sdcard/panel-ui.xml "$work/panel-ui.xml" >/dev/null 2>&1
  local xy
  xy=$(python3 - "$work/panel-ui.xml" "$label" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
found = [n for n in root.iter() if n.get('text') == sys.argv[2]]
if len(found) != 1: raise SystemExit('Button not uniquely found: ' + sys.argv[2])
m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', found[0].get('bounds', ''))
if not m: raise SystemExit('Missing button bounds')
x1, y1, x2, y2 = map(int, m.groups())
if x2 <= x1 or y2 <= y1: raise SystemExit('Empty button bounds')
print((x1+x2)//2, (y1+y2)//2)
PY
  )
  "$adb" shell input tap $xy
  sleep 3
}
check_resumed() {
  local expected="$1" result="$2"
  "$adb" shell dumpsys activity activities | tr -d '\r' | grep -E 'mResumedActivity|mFocusedActivity' > "$work/$result.txt"
  cat "$work/$result.txt"
  grep -F "$expected" "$work/$result.txt" >/dev/null || { echo "Expected $expected"; exit 1; }
}
open_panel; tap_label 'Штатный экран магнитолы'; check_resumed 'tw.com.elead.el830.home/.Home' click-home
open_panel; tap_label 'Рабочий стол Android'; check_resumed 'com.android.launcher/com.android.launcher2.Launcher' click-launcher
open_panel; tap_label 'Файловый менеджер Amaze'; check_resumed 'com.amaze.filemanager/' click-amaze
kill "$logpid" 2>/dev/null || true
wait "$logpid" 2>/dev/null || true
{
  echo '# Disposable Android 4.4.2 x86 panel and Launcher2 experiment'
  echo 'Not a head unit test, not firmware, no APK published.'
  echo 'The real stock-derived Launcher2 has exactly its HOME category removed and is re-signed solely for this AOSP emulator with its matching public AOSP key. This APK is not the Freescale-signed device candidate.'
  echo 'Car Home is a minimal test double, not the actual E-lead Home. Amaze is the checked v3.5.3 APK and was network-blocked.'
  echo 'User data, SD maps, Hibernate, radio, MCU and display hardware were not tested.'
  echo "Emulator certificate: $cert ($match); source launcher SHA-256 82787a6007589a169242f2c1391252342a9824748a8b469d1d522acab83458e6"
  echo '## Non-signature payload comparison'; cat "$work/payload.txt"
  echo '## APK signing (emulator only)'; cat "$work/launcher-verify.txt"
  echo '## Install results'; cat "$work/install-home.txt" "$work/install-launcher.txt" "$work/install-panel.txt" "$work/install-amaze.txt" | tr -d '\r'
  echo '## Implicit HOME result'; cat "$work/home-result.txt" | tr -d '\r'
  echo '## Activities after UI button taps'; cat "$work/click-home.txt" "$work/click-launcher.txt" "$work/click-amaze.txt"
  echo '## Selected errors (may include unrelated emulator noise)'
  grep -iE 'FATAL EXCEPTION|fatal signal|ANR in (com\.android\.launcher|ru\.lifanx60\.panel|com\.amaze\.filemanager)' "$work/logcat.txt" | tail -30 | tr -d '\r' || true
} > reports/panel-launcher-emulator-laboratory.txt

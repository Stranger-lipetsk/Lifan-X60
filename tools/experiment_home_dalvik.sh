#!/usr/bin/env bash
# Invoke three original/patched Home methods in a disposable generic emulator.
# No firmware or private device data; real Home.onCreate/services are NOT run.
set -euo pipefail
exec > >(tee "$RUNNER_TEMP/home-dalvik.log") 2>&1
work="$RUNNER_TEMP/home-dalvik"; mkdir -p "$work" reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar=$(find "$sdk/platforms" -name android.jar | sort -V | tail -1)
adb="$sdk/platform-tools/adb"
export ANDROID_AVD_HOME="$work/avd"; mkdir -p "$ANDROID_AVD_HOME"

echo 'Phase 1: extract source Home and build exact experimental dex'
sudo apt-get update -qq
sudo apt-get install -y -qq p7zip-full e2fsprogs
gh release download stock -p x60_2021.7z -D "$work"
echo "75e7d6cd900fac971b55fec9f59913153bf7a1096bd761f7229c9a1d6d57b540  $work/x60_2021.7z" | sha256sum -c -
7z e -y "$work/x60_2021.7z" -o"$work" system.img >/dev/null
echo "b6bbbe529942ffec250cad993ae9cbb808721c27cf2536fb3fb11120130e8545  $work/system.img" | sha256sum -c -
mkdir -p "$work/assets"
for item in 'priv-app/EL830LF01_Home.apk:home-original.apk' 'framework/framework.jar:framework.jar' 'framework/framework2.jar:framework2.jar'; do
  src=${item%%:*}; dst=${item#*:}
  debugfs -R "dump /$src $work/assets/$dst" "$work/system.img" >/dev/null 2>&1
  test -s "$work/assets/$dst"
done
echo "75ee685d5399e4c394146cac593ec2ed4bfbd5f6cc9151f9ae479992c84011a6  $work/assets/home-original.apk" | sha256sum -c -
curl -fLsS --retry 3 --max-time 120 -o "$work/apktool.jar" https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar
java -jar "$work/apktool.jar" d -f -r "$work/assets/home-original.apk" -o "$work/decoded" >/dev/null
python3 tools/experiment_home_carousel.py "$work/decoded"
java -jar "$work/apktool.jar" b -f "$work/decoded" -o "$work/rebuilt.apk" >/dev/null
unzip -p "$work/rebuilt.apk" classes.dex > "$work/new.dex"; test -s "$work/new.dex"
python3 - "$work/assets/home-original.apk" "$work/new.dex" "$work/assets/home-patched.apk" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as old, zipfile.ZipFile(sys.argv[3], 'w') as out:
    entries = old.infolist()
    if len({e.filename for e in entries}) != len(entries): raise SystemExit('Duplicate APK entry')
    for entry in entries:
        if entry.filename.upper().startswith('META-INF/'): continue
        out.writestr(entry, open(sys.argv[2], 'rb').read() if entry.filename == 'classes.dex' else old.read(entry))
PY
python3 tools/compare_apk_payload.py "$work/assets/home-original.apk" "$work/assets/home-patched.apk" > "$work/compare.txt"

echo 'Phase 2: build isolated harness and target panel (temporary signing key)'
keytool -genkeypair -keystore "$work/temp.keystore" -storepass test-only -keypass test-only \
  -alias dalvik-test -keyalg RSA -keysize 2048 -validity 1000 -dname 'CN=Disposable Home Dalvik Test' >/dev/null 2>&1
build_apk() {
  local name=$1 src=$2 java=$3 use_assets=$4
  mkdir -p "$work/$name/classes" "$work/$name/dex"
  local args=(-f -M "$src/AndroidManifest.xml" -I "$jar" -F "$work/$name/unsigned.apk")
  [ ! -d "$src/res" ] || args+=(-S "$src/res")
  [ "$use_assets" = no ] || args+=(-A "$work/assets")
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
build_apk panel launcher-panel-integrated src/ru/lifanx60/panel/MainActivity.java no
build_apk harness tests/fixtures/home-dalvik src/ru/lifanx60/homelab/MainActivity.java yes
gh release download v3.5.3 --repo TeamAmaze/AmazeFileManager -p app-fdroid-release.apk -D "$work"
echo "2a9bc50c6672b1cb6efdfbd9bd9149bf280274e386305663163cc365abd393f3  $work/app-fdroid-release.apk" | sha256sum -c -

echo 'Phase 3: boot clean Android 4.4.2 x86'
"$sdk/cmdline-tools/latest/bin/sdkmanager" --install 'emulator' 'platform-tools' 'system-images;android-19;default;x86'
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -f -n home_dalvik -k 'system-images;android-19;default;x86' -c 512M >/dev/null
[ ! -e /dev/kvm ] || sudo chmod a+rw /dev/kvm
"$sdk/emulator/emulator" -avd home_dalvik -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -no-metrics > "$work/emulator.txt" 2>&1 &
pid=$!
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Emulator diagnostics ($status):"; tail -40 "$work/emulator.txt" || true
    if [ -s "$work/logcat.txt" ]; then echo 'Harness log:'; grep -A40 'HomeDalvikLab' "$work/logcat.txt" | tail -100 || true; fi
  fi
  kill "$pid" 2>/dev/null || true
}
trap cleanup EXIT
timeout 120 "$adb" wait-for-device
booted=no
for i in $(seq 1 100); do
  if [ "$(timeout 5 "$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=yes; break; fi
  kill -0 "$pid" 2>/dev/null || { echo 'Emulator exited'; exit 1; }
  sleep 3
done
[ "$booted" = yes ] || { echo 'Emulator not booted'; exit 1; }
"$adb" install "$work/panel.apk" | tee "$work/panel-install.txt"
"$adb" install "$work/harness.apk" | tee "$work/harness-install.txt"
"$adb" install "$work/app-fdroid-release.apk" | tee "$work/amaze-install.txt"
grep -q Success "$work/panel-install.txt"; grep -q Success "$work/harness-install.txt"; grep -q Success "$work/amaze-install.txt"
"$adb" logcat -c
"$adb" logcat -v brief > "$work/logcat.txt" 2>&1 &
logpid=$!
for case in original patched; do
  value=false; [ "$case" != patched ] || value=true
  timeout 30 "$adb" shell am start -n ru.lifanx60.homelab/.MainActivity --ez patched "$value"
  for i in $(seq 1 60); do
    if grep -q "RESULT ${case^^} " "$work/logcat.txt"; then break; fi
    sleep 1
  done
  grep -F "RESULT ${case^^} PASS" "$work/logcat.txt" || { echo "Harness case $case did not pass"; exit 1; }
done
kill "$logpid" 2>/dev/null || true
wait "$logpid" 2>/dev/null || true
{
  echo '# Isolated Dalvik method harness for original and modified Home (Android 4.4.2 x86)'
  echo 'NOT a firmware, not a head-unit test. Home was dynamically loaded, not installed or started normally.'
  echo 'Real Home.onCreate, HomeService, hardware, audio, boot, preferences and Hibernate were not run.'
  echo 'Original and patched Home resources and methods were loaded in separate classloaders, using stock framework jars; generic Android services are not vendor services.'
  echo 'Amaze v3.5.3 and candidate panel were installed only for PackageManager resolution, not launched.'
  echo '## APK payload comparison'; cat "$work/compare.txt"
  echo '## Harness results'; grep 'HomeDalvikLab' "$work/logcat.txt" | tr -d '\r'
} > reports/home-dalvik-laboratory.txt

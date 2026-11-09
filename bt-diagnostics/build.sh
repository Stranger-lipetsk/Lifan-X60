#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
BT="$SDK/build-tools/34.0.0"
API_JAR="$SDK/platforms/android-34/android.jar"
[[ -x "$BT/aapt" && -f "$API_JAR" ]] || { echo "Android SDK 34/build-tools 34.0.0 not found under $SDK" >&2; exit 1; }

OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex"
"$BT/aapt" package -f -m -J "$OUT/gen" -M AndroidManifest.xml -I "$API_JAR"
find src "$OUT/gen" -name '*.java' -print > "$OUT/sources.txt"
[[ -s "$OUT/sources.txt" ]] || { echo 'No Java sources found' >&2; exit 1; }
javac -source 8 -target 8 -Xlint:-options \
  -bootclasspath "$API_JAR" -classpath "$API_JAR" \
  -d "$OUT/classes" @"$OUT/sources.txt"
find "$OUT/classes" -name '*.class' -print > "$OUT/classes.txt"
[[ -s "$OUT/classes.txt" ]] || { echo 'javac produced no class files' >&2; exit 1; }
"$BT/d8" --lib "$API_JAR" --min-api 19 --output "$OUT/dex" @"$OUT/classes.txt"
"$BT/aapt" package -f -M AndroidManifest.xml -I "$API_JAR" -F "$OUT/app-unsigned.apk"
cp "$OUT/dex/classes.dex" "$OUT/classes.dex"
(cd "$OUT" && zip -q -u app-unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/app-unsigned.apk" "$OUT/app-aligned.apk"
keytool -genkeypair -keystore "$OUT/diag-debug.keystore" \
  -storepass diag-test -keypass diag-test -alias diag-test \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Wi-Fi Radio Diagnostics, OU=Prototype, O=Lifan X60, C=RU" \
  >/dev/null 2>&1
"$BT/apksigner" sign --ks "$OUT/diag-debug.keystore" \
  --ks-pass pass:diag-test --key-pass pass:diag-test \
  --min-sdk-version 19 --v1-signing-enabled true \
  --out "$OUT/wifi-radio-check.apk" "$OUT/app-aligned.apk"
"$BT/apksigner" verify --min-sdk-version 19 "$OUT/wifi-radio-check.apk"
"$BT/aapt" dump badging "$OUT/wifi-radio-check.apk" > "$OUT/badging.txt"
grep -q "package: name='ru.lifanx60.radiodiagnostics'" "$OUT/badging.txt"
grep -q "sdkVersion:'19'" "$OUT/badging.txt"
sha256sum "$OUT/wifi-radio-check.apk" | tee "$OUT/sha256.txt"
echo "Built $OUT/wifi-radio-check.apk"
cat "$OUT/badging.txt" | head -12

#!/usr/bin/env bash
# Сборка APK «Переключатель» для ГУ Lifan X60 FL (Android 4.4.2, API 19).
# Требуется Android SDK: build-tools (aapt, d8, zipalign, apksigner) и platforms/android-XX/android.jar
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
BT=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)
API_JAR=$(ls "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)

[ -n "$BT" ] || { echo "ОШИБКА: build-tools не найдены в $SDK"; exit 1; }
[ -n "$API_JAR" ] || { echo "ОШИБКА: android.jar не найден в $SDK/platforms"; exit 1; }

echo "build-tools: $BT"
echo "android.jar: $API_JAR"

OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/dex"

echo "== 1. aapt: генерация R.java =="
"$BT/aapt" package -f -m \
  -J "$OUT/gen" \
  -M AndroidManifest.xml \
  -S res \
  -I "$API_JAR"

echo "== 2. javac =="
find src "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -source 8 -target 8 -nowarn \
  -bootclasspath "$API_JAR" \
  -classpath "$API_JAR" \
  -d "$OUT/obj" @"$OUT/sources.txt" 2>&1 | grep -v "bootstrap class path" || true

echo "== 3. d8: dex =="
find "$OUT/obj" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --lib "$API_JAR" --min-api 19 --output "$OUT/dex" @"$OUT/classes.txt"

echo "== 4. aapt: пакет ресурсов =="
"$BT/aapt" package -f \
  -M AndroidManifest.xml \
  -S res \
  -I "$API_JAR" \
  -F "$OUT/app-unsigned.apk"

echo "== 5. добавляем classes.dex =="
cp "$OUT/dex/classes.dex" "$OUT/classes.dex"
( cd "$OUT" && zip -q -u app-unsigned.apk classes.dex )

echo "== 6. zipalign =="
"$BT/zipalign" -f 4 "$OUT/app-unsigned.apk" "$OUT/app-aligned.apk"

echo "== 7. подпись (v1 — обязательна для Android 4.4) =="
KS="$OUT/debug.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -v -keystore "$KS" -storepass lifan123 -keypass lifan123 \
    -alias lifan -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Lifan X60, OU=Head Unit, O=Community, C=RU" >/dev/null 2>&1
fi
"$BT/apksigner" sign \
  --ks "$KS" --ks-pass pass:lifan123 --key-pass pass:lifan123 \
  --min-sdk-version 19 --v1-signing-enabled true \
  --out switcher.apk "$OUT/app-aligned.apk"

"$BT/apksigner" verify --min-sdk-version 19 switcher.apk || true

echo
echo "ГОТОВО: $(pwd)/switcher.apk"
ls -l switcher.apk
echo "sha256: $(sha256sum switcher.apk | cut -d' ' -f1)"
echo
echo "Проверка содержимого:"
"$BT/aapt" dump badging switcher.apk 2>/dev/null | head -12

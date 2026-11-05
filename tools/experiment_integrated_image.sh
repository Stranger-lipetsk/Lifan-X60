#!/usr/bin/env bash
# Internal-only complete archive rehearsal. NEVER publish or flash its output.
set -euo pipefail
exec > >(tee "$RUNNER_TEMP/integrated-image.log") 2>&1
work="$RUNNER_TEMP/integrated-lab"; mkdir -p "$work/full" "$work/old-tree" "$work/new-tree" reports
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
jar=$(find "$sdk/platforms" -name android.jar | sort -V | tail -1)
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip

echo 'Phase 1: check complete previously tested base archive'
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
python3 - "$work/lifan-file-manager-test.zip" <<'PY'
import sys, zipfile
wanted = {'system.img', 'boot.img', 'sd_boot.img', 'u-boot.bin', 'MCU_FW.hex', 'backup/config.ini'}
with zipfile.ZipFile(sys.argv[1]) as z:
    files = [x.filename for x in z.infolist() if not x.is_dir()]
    if len(files) != len(set(files)) or set(files) != wanted: raise SystemExit('Unexpected archive members')
    print('Baseline archive members:', sorted(files))
PY
unzip -q "$work/lifan-file-manager-test.zip" -d "$work/full"
base="$work/full/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $base" | sha256sum -c -
navitel="$GITHUB_WORKSPACE/firmware/apks/com.navitel.apk"
echo "96876415d8b4342952558fd30d6e11b0ca9355c802060c0a9740b6cc84fc4e1b  $navitel" | sha256sum -c -
e2fsck -fn "$base" > "$work/fsck-before.txt" 2>&1
python3 tools/check_stock_fsck.py "$work/fsck-before.txt" 0
for spec in 'priv-app/EL830LF01_Home.apk:Home-original.apk' 'priv-app/Launcher2.apk:Launcher2-original.apk'; do
  src=${spec%%:*}; dest=${spec#*:}
  debugfs -R "dump /$src $work/$dest" "$base" >/dev/null 2>&1
done
echo "75ee685d5399e4c394146cac593ec2ed4bfbd5f6cc9151f9ae479992c84011a6  $work/Home-original.apk" | sha256sum -c -
echo "82787a6007589a169242f2c1391252342a9824748a8b469d1d522acab83458e6  $work/Launcher2-original.apk" | sha256sum -c -

echo 'Phase 2: build Home and Launcher2 with original Freescale certificate identities'
curl -fLsS --retry 3 --max-time 120 -o "$work/apktool.jar" https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar
java -jar "$work/apktool.jar" d -f -r "$work/Home-original.apk" -o "$work/decoded" >/dev/null
python3 tools/experiment_home_carousel.py "$work/decoded"
java -jar "$work/apktool.jar" b -f "$work/decoded" -o "$work/home-rebuilt.apk" >/dev/null
unzip -p "$work/home-rebuilt.apk" classes.dex > "$work/new.dex"
unzip -p "$work/Launcher2-original.apk" AndroidManifest.xml > "$work/old-manifest"
python3 tools/experiment_launcher_manifest.py "$work/old-manifest" "$work/new-manifest"
python3 - "$work" <<'PY'
import pathlib, sys, zipfile
w = pathlib.Path(sys.argv[1])
for original, changed, replacement, output in [
    ('Home-original.apk', 'classes.dex', 'new.dex', 'home-unsigned.apk'),
    ('Launcher2-original.apk', 'AndroidManifest.xml', 'new-manifest', 'launcher-unsigned.apk'),
]:
    with zipfile.ZipFile(w / original) as old, zipfile.ZipFile(w / output, 'w') as out:
        entries = old.infolist()
        if len({e.filename for e in entries}) != len(entries): raise SystemExit('Duplicate input ZIP entry')
        if sum(e.filename == changed for e in entries) != 1: raise SystemExit('Missing changed entry')
        for e in entries:
            if e.filename.upper().startswith('META-INF/'): continue
            out.writestr(e, (w / replacement).read_bytes() if e.filename == changed else old.read(e))
PY
ref=495a2e2f50ecbd6d97922aeaf0224a90d1ed6d94
for name in platform shared; do
  for ext in x509.pem pk8; do gh api "repos/Avnet/android-imx-device-fsl/contents/common/security/$name.$ext?ref=$ref" --jq .content | base64 -d > "$work/$name.$ext"; done
done
plat=$(openssl x509 -in "$work/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
shared=$(openssl x509 -in "$work/shared.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
test "$plat" = 7fbae817b7db24642d8959c347b561c003c6cfde2cb10f909c932f21a4d6d804
test "$shared" = 212912e875e5077f955c3079b6ceb1151c2b64d9bd9f6673dceff70d312eb2d5
for spec in 'home:platform:Home-new.apk' 'launcher:shared:Launcher2-new.apk'; do
  IFS=: read -r part key output <<< "$spec"
  "$bt/zipalign" -f 4 "$work/$part-unsigned.apk" "$work/$part-aligned.apk"
  "$bt/apksigner" sign --key "$work/$key.pk8" --cert "$work/$key.x509.pem" --min-sdk-version 19 --v1-signing-enabled true --out "$work/$output" "$work/$part-aligned.apk"
  "$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --verbose --print-certs "$work/$output" > "$work/$part-signature.txt"
  grep -F 'Verified using v1 scheme (JAR signing): true' "$work/$part-signature.txt"
  case "$key" in platform) expected="$plat";; shared) expected="$shared";; esac
  grep -F "certificate SHA-256 digest: $expected" "$work/$part-signature.txt"
done
python3 tools/compare_apk_payload.py "$work/Home-original.apk" "$work/Home-new.apk" > "$work/home-diff.txt"
python3 tools/compare_apk_payload.py "$work/Launcher2-original.apk" "$work/Launcher2-new.apk" AndroidManifest.xml > "$work/launcher-diff.txt"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 "$navitel" > "$work/navitel-signature.txt"

echo 'Phase 3: build panel with temporary laboratory signature'
mkdir -p "$work/panel/classes" "$work/panel/dex"
"$bt/aapt" package -f -M launcher-panel-integrated/AndroidManifest.xml -S launcher-panel-integrated/res -I "$jar" -F "$work/panel/unsigned.apk"
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/panel/classes" launcher-panel-integrated/src/ru/lifanx60/panel/MainActivity.java
find "$work/panel/classes" -name '*.class' > "$work/panel/classes.txt"
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/panel/dex" @"$work/panel/classes.txt"
cp "$work/panel/dex/classes.dex" "$work/panel/classes.dex"
(cd "$work/panel" && zip -q -u unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$work/panel/unsigned.apk" "$work/panel/aligned.apk"
keytool -genkeypair -keystore "$work/panel-temp.keystore" -storepass test-only -keypass test-only -alias panel \
  -keyalg RSA -keysize 2048 -validity 1000 -dname 'CN=Disposable Image Rehearsal Panel' >/dev/null 2>&1
"$bt/apksigner" sign --ks "$work/panel-temp.keystore" --ks-pass pass:test-only --key-pass pass:test-only \
  --min-sdk-version 19 --v1-signing-enabled true --out "$work/Panel-new.apk" "$work/panel/aligned.apk"
"$bt/apksigner" verify --min-sdk-version 19 --max-sdk-version 19 --verbose "$work/Panel-new.apk" > "$work/panel-signature.txt"
"$bt/aapt" dump badging "$work/Panel-new.apk" > "$work/panel-badging.txt"
grep -F "package: name='ru.lifanx60.panel'" "$work/panel-badging.txt"
grep -F "launchable-activity: name='ru.lifanx60.panel.MainActivity'" "$work/panel-badging.txt"

echo 'Phase 4: modify only a copy of system image in place'
python3 tools/inplace_patch.py --system "$base" --out "$work/candidate.img" \
  --add-file "$navitel:/priv-app/Navitel-large.apk" \
  --add-file "$work/Home-new.apk:/priv-app/EL830LF01_Home.apk" \
  --add-file "$work/Launcher2-new.apk:/priv-app/Launcher2.apk" \
  --add-file "$work/Panel-new.apk:/app/LifanLauncherPanel.apk" > "$work/patch.txt"
printf 'u:object_r:system_file:s0\0' > "$work/selinux.bin"
for path in /priv-app/Navitel-large.apk /priv-app/EL830LF01_Home.apk /priv-app/Launcher2.apk /app/LifanLauncherPanel.apk; do
  for cmd in "sif $path mode 0100644" "sif $path uid 0" "sif $path gid 0" "ea_set -f $work/selinux.bin $path security.selinux"; do
    debugfs -w -R "$cmd" "$work/candidate.img" >> "$work/patch.txt" 2>&1
  done
  debugfs -R "stat $path" "$work/candidate.img" > "$work/stat-$(basename "$path").txt" 2>&1
  grep -Eq 'Mode:[[:space:]]+0644' "$work/stat-$(basename "$path").txt"
  grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' "$work/stat-$(basename "$path").txt"
  grep -F 'u:object_r:system_file:s0' "$work/stat-$(basename "$path").txt" >/dev/null
done
e2fsck -fn "$work/candidate.img" > "$work/fsck-after.txt" 2>&1
python3 tools/check_stock_fsck.py "$work/fsck-after.txt" 0
test "$(stat -c %s "$base")" = "$(stat -c %s "$work/candidate.img")"
for spec in "$base:old-tree" "$work/candidate.img:new-tree"; do
  img=${spec%%:*}; dir=${spec#*:}
  debugfs -R "rdump / $work/$dir" "$img" > "$work/$dir.log" 2>&1
  if grep -iE 'no space left|input/output error|filesystem not open|failed to open|ext2.* error' "$work/$dir.log"; then exit 1; fi
  test -s "$work/$dir/build.prop" && test -d "$work/$dir/priv-app"
  find "$work/$dir" -type d -exec chmod u+rwx {} +
  find "$work/$dir" -type f -exec chmod u+r {} +
done
python3 tools/check_integrated_laboratory_image.py "$work/old-tree" "$work/new-tree" \
  --home "$work/Home-new.apk" --launcher "$work/Launcher2-new.apk" --navitel "$navitel" --panel "$work/Panel-new.apk" > "$work/tree-compare.txt"

echo 'Phase 5: exercise full archive packaging without publication'
cp "$work/candidate.img" "$base"
python3 - "$work/full" "$work/internal-only.zip" "$work/archive-report.txt" <<'PY'
import hashlib, pathlib, sys, zipfile
root, out, report = map(pathlib.Path, sys.argv[1:])
names = {'system.img', 'boot.img', 'sd_boot.img', 'u-boot.bin', 'MCU_FW.hex', 'backup/config.ini'}
actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
if actual != names: raise SystemExit('Unexpected full archive file set')
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as z:
    for name in sorted(names): z.write(root / name, name)
with zipfile.ZipFile(out) as z, report.open('w') as f:
    if set(z.namelist()) != names or len(z.namelist()) != len(names): raise SystemExit('Archive members differ')
    for name in sorted(names):
        actual_hash = hashlib.sha256()
        with z.open(name) as src:
            for buf in iter(lambda: src.read(1024*1024), b''): actual_hash.update(buf)
        expected = hashlib.sha256()
        with (root / name).open('rb') as src:
            for buf in iter(lambda: src.read(1024*1024), b''): expected.update(buf)
        if actual_hash.digest() != expected.digest(): raise SystemExit('Archive data mismatch: ' + name)
        print(name, actual_hash.hexdigest(), file=f)
    print('All six ZIP members match local source files; no archive published.', file=f)
PY
{
  echo '# Integrated full archive rehearsal — NOT A RELEASE, DO NOT FLASH'
  echo 'Input: previously tested file-manager-test-20261105 ZIP; no physical device, SD or user data accessed.'
  echo 'Four image modifications: Navitel APK, Home APK, Launcher2 APK, and new panel. Amaze remains unchanged.'
  echo 'Home and Launcher2 use matching public Freescale test certificates. Panel has a disposable key that is NOT retained; this is NOT a distribution build.'
  echo 'No device boot, MCU behavior, Hibernate, license, SD maps, actual radio, display or firmware write tested.'
  echo 'The six-file archive and image exist only temporarily and are intentionally not published.'
  echo '## Checked extracted file changes'; cat "$work/tree-compare.txt"
  echo '## Home APK payload'; cat "$work/home-diff.txt"
  echo '## Launcher APK payload'; cat "$work/launcher-diff.txt"
  echo '## Filesystem before'; cat "$work/fsck-before.txt"
  echo '## Filesystem after'; cat "$work/fsck-after.txt"
  echo '## Written APK metadata'; for f in "$work"/stat-*.txt; do echo "--- $(basename "$f")"; cat "$f"; done
  echo '## Full archive contents verified'; cat "$work/archive-report.txt"
} > reports/integrated-full-archive-laboratory.txt

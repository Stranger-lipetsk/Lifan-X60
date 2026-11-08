#!/usr/bin/env bash
# Extract BT stack components from the selected published system image and emit
# a text-only static audit. No binary firmware or APK is uploaded as an artifact.
set -euo pipefail

archive=${1:?usage: audit_bt_release_asset.sh RELEASE_ZIP REPORT_PATH}
report=${2:?usage: audit_bt_release_asset.sh RELEASE_ZIP REPORT_PATH}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$report")"

asset_sha=$(sha256sum "$archive" | awk '{print $1}')
asset_size=$(stat -c '%s' "$archive")
member=$(unzip -Z1 "$archive" | grep -E '(^|/)system\.img$' | head -n 1 || true)
if [[ -z "$member" ]]; then
  printf 'ERROR: system.img not found in selected release archive\n' > "$report"
  exit 1
fi
unzip -p "$archive" "$member" > "$work/system.img"
image_sha=$(sha256sum "$work/system.img" | awk '{print $1}')
image_size=$(stat -c '%s' "$work/system.img")

{
  echo '# Static Bluetooth audit of file-manager-test release'
  echo 'Scope: release asset and image files only; no physical device, no APK launch.'
  echo "Archive: $(basename "$archive")"
  echo "Archive bytes: $asset_size"
  echo "Archive SHA-256: $asset_sha"
  echo 'Expected archive SHA-256 from docs/37: 4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f'
  [[ "$asset_sha" == '4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f' ]] && echo 'Archive identity: MATCH' || echo 'Archive identity: DIFFERENT (inspect actual hashes below)'
  echo "ZIP member: $member"
  echo "system.img bytes: $image_size"
  echo "system.img SHA-256: $image_sha"
  echo 'Expected system.img SHA-256 from docs/37: a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511'
  [[ "$image_sha" == 'a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511' ]] && echo 'System image identity: MATCH' || echo 'System image identity: DIFFERENT (inspect actual hashes below)'
  echo
  echo '## Extracted file inventory'
} > "$report"

paths=(
  '/etc/bluetooth/bt_vendor.conf'
  '/etc/firmware/bcm20710a1.hcd'
  '/lib/libbluelet.so'
  '/lib/libbt_platform.so'
  '/vendor/lib/libbt-vendor.so'
  '/bin/blueletd'
  '/lib/hw/bluetooth.default.so'
  '/app/Bluetooth.apk'
  '/app/EL831CLF01_elBTService_2016.09.05.01.apk'
  '/app/EL831CLF01_elBluetoothSetup_2016.12.13.01.apk'
  '/app/EL831CLF01_elBluetoothPhone_2016.12.13.01.apk'
)
for path in "${paths[@]}"; do
  out="$work/$(echo "$path" | tr '/' '_')"
  if debugfs -R "dump $path $out" "$work/system.img" >/dev/null 2>&1 && [[ -s "$out" ]]; then
    printf '%s | bytes=%s | sha256=%s\n' "$path" "$(stat -c '%s' "$out")" "$(sha256sum "$out" | awk '{print $1}')" >> "$report"
    case "$path" in
      *.so|*/blueletd)
        {
          echo
          echo "## ELF: $path"
          readelf -h "$out" 2>&1 | grep -E 'Class:|Data:|Machine:' || true
          echo 'Exported dynamic function symbols (filtered):'
          readelf -Ws "$out" 2>/dev/null | awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" {print $8}' | sort -u | grep -Ei 'bt|spp|rfcomm|hci|serial|connect|pair|bond|socket|blue' | head -120 || true
          echo 'Relevant strings:'
          strings -a "$out" 2>/dev/null | grep -Ei 'SPP|RFCOMM|Serial Port|BluetoothStack|BluetoothSocket|HCI_Init|HCI_TL|pair|bond|/dev/tty' | sort -u | head -120 || true
        } >> "$report"
        ;;
      *.apk)
        {
          echo
          echo "## APK strings: $path"
          unzip -p "$out" classes.dex 2>/dev/null | strings -a | grep -Ei 'com/ivt/bluetooth|BluetoothStack|SPP|RFCOMM|SerialPort|BluetoothSocket|createRfcomm|bond|pair' | sort -u | head -120 || true
        } >> "$report"
        ;;
      */bt_vendor.conf)
        {
          echo
          echo '## bt_vendor.conf contents'
          cat "$out"
        } >> "$report"
        ;;
    esac
  else
    printf '%s | MISSING\n' "$path" >> "$report"
  fi
done
cat >> "$report" <<'EOF'

## Interpretation limits
This is static inspection of the published test image, not a runtime test. SPP/RFCOMM strings or symbols do not prove that the custom stack exposes Android BluetoothSocket or that ELM327 pairing works. No firmware, APK, or extracted binary is committed; only this text report is intended for Git.
EOF

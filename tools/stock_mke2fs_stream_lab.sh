#!/usr/bin/env bash
# Source only from the guarded disposable CI experiment. This formats ONLY a
# validated newly-created 512 MiB regular-file loop, never a device image.
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable image only'; exit 1; }
: "${work:?}" "${GITHUB_RUN_ID:?}"
stock_loop=''
stock_container="x60-stream-format-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-0}"
prepare_stock_formatter() {
  mkdir -p "$work/formatter/system/bin" "$work/formatter/system/etc"
  debugfs -R "dump /bin/mke2fs $work/formatter/system/bin/mke2fs" "$work/system.img" >/dev/null 2>&1
  echo "45b4cad925fe740a013f64192f6ba09784038b4b9dca4f5f1a3ed37f1a364c3e  $work/formatter/system/bin/mke2fs" | sha256sum -c -
  debugfs -R "dump /bin/linker $work/formatter/system/bin/linker" "$work/system.img" >/dev/null 2>&1
  timeout -k 5 180 debugfs -R "rdump /lib $work/formatter/system" "$work/system.img" > "$work/formatter-libs.txt" 2>&1
  test -s "$work/formatter/system/lib/libc.so" && test -s "$work/formatter/system/bin/linker"
  debugfs -R "dump /etc/mke2fs.conf $work/formatter/system/etc/mke2fs.conf" "$work/system.img" >/dev/null 2>&1 || true
  if [ -s "$work/formatter/system/etc/mke2fs.conf" ]; then echo 'stock mke2fs.conf present' > "$work/formatter-config.txt"; sha256sum "$work/formatter/system/etc/mke2fs.conf" >> "$work/formatter-config.txt"; else echo 'No stock mke2fs.conf found in image' > "$work/formatter-config.txt"; fi
  cp /usr/bin/qemu-arm-static "$work/formatter/qemu-arm-static"
  chmod 0755 "$work/formatter/qemu-arm-static" "$work/formatter/system/bin/"{linker,mke2fs}
  printf 'FROM scratch\nCOPY system /system\nCOPY qemu-arm-static /qemu-arm-static\n' > "$work/formatter/Dockerfile"
  docker build -q -t x60-stream-stock-mke2fs "$work/formatter"
  # Synthetic empty Android 4.4 property area, never real device properties.
  python3 - "$work/formatter-properties" <<'PY'
import struct, sys
b = bytearray(128 * 1024)
struct.pack_into('<IIII', b, 0, 20, 0, 0x504f5250, 0xfc6ed0ab)
open(sys.argv[1], 'wb').write(b)
PY
  sudo chown 0:0 "$work/formatter-properties"; sudo chmod 0444 "$work/formatter-properties"
}
format_stock_image() {
  local target=$1 label=$2 backing rc=0
  case "$target" in "$work/synthetic-p5.img"|"$work/synthetic-p5-plus.img") ;; *) echo 'Unexpected image path'; return 1;; esac
  [ -f "$target" ] && [ ! -L "$target" ] && [ "$(stat -c %s "$target")" = 536870912 ] || return 1
  # Only a freshly created, still-blank regular file is allowed.
  [ "$(od -An -tx1 -N16 "$target" | tr -d ' 0\n')" = '' ] || { echo 'Synthetic image is not blank'; return 1; }
  stock_loop=$(timeout -k 5 30 sudo losetup --find --show "$target")
  [[ "$stock_loop" =~ ^/dev/loop[0-9]+$ ]] || return 1
  backing=$(sudo losetup -n -O BACK-FILE "$stock_loop")
  [ "$(realpath -e "$backing")" = "$(realpath -e "$target")" ] || { echo 'Unexpected loop backing'; return 1; }
  timeout -k 5 60 docker run --rm --name "$stock_container" --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges --memory 256m --pids-limit 32 \
    --device "$stock_loop:$stock_loop:rwm" \
    --mount "type=bind,source=$work/formatter-properties,target=/dev/__properties__,readonly" \
    x60-stream-stock-mke2fs /qemu-arm-static /system/bin/mke2fs -t ext4 "$stock_loop" > "$work/formatter-$label.txt" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then cat "$work/formatter-$label.txt"; echo "Synthetic format failed: $rc"; return 1; fi
  sudo losetup -d "$stock_loop"; stock_loop=''
  e2fsck -fn "$target" > "$work/formatter-$label-fsck.txt" 2>&1
  dumpe2fs -h "$target" 2>/dev/null | grep -E '^Filesystem features:|^Block count:|^Reserved block count:|^Block size:' > "$work/formatter-$label-geometry.txt"
}
cleanup_stock_formatter() {
  timeout -k 5 20 docker rm -f "$stock_container" >/dev/null 2>&1 || true
  if [ -n "$stock_loop" ]; then sudo losetup -d "$stock_loop" || echo 'Cannot detach isolated formatter loop'; stock_loop=''; fi
}

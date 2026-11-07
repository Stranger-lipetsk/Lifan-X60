#!/usr/bin/env bash
# CI-only synthetic external backup. NEVER run against physical devices.
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI disposable image only'; exit 1; }
: "${work:?}"
check_external_digest() {
  local file=$1 expected=$2 actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ]
}
prepare_external_synthetic_backup() {
  mkdir -p "$work/external-backup" "$work/external-tar"
  test ! -e "$work/synthetic-external.img" && test ! -L "$work/synthetic-external.img"
  truncate -s 512M "$work/synthetic-external.img"
  sudo mkfs.vfat -F 32 "$work/synthetic-external.img" > "$work/external-format.txt"
  sudo mount -t vfat -o "loop,uid=$(id -u),gid=$(id -g),umask=000" "$work/synthetic-external.img" "$work/external-backup"
  [ "$(findmnt -n -o FSTYPE --target "$work/external-backup")" = vfat ]
  cp /usr/bin/qemu-arm-static "$work/external-tar/qemu-arm-static"
  cp "$work/stock-busybox" "$work/external-tar/busybox"
  chmod 0755 "$work/external-tar/"{qemu-arm-static,busybox}
  printf 'FROM scratch\nCOPY busybox /busybox\nCOPY qemu-arm-static /qemu-arm-static\n' > "$work/external-tar/Dockerfile"
  docker build -q -t x60-external-backup-lab "$work/external-tar"
  external_create_rc=0
  docker run --rm --network none --read-only --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges --memory 512m --pids-limit 32 \
    --mount "type=bind,source=$work/copy-source,target=/fixture/source,readonly" \
    --mount "type=bind,source=$work/external-backup,target=/fixture/external" \
    --workdir /fixture/source x60-external-backup-lab /qemu-arm-static /busybox tar -cf /fixture/external/data.tar ./. > "$work/external-create.log" 2>&1 || external_create_rc=$?
  [ "$external_create_rc" = 0 ] || { echo "External archive creation failed: $external_create_rc"; tail -40 "$work/external-create.log"; return 1; }
  test -s "$work/external-backup/data.tar"
  sudo sync
  external_before=$(sha256sum "$work/external-backup/data.tar" | awk '{print $1}')
  sudo umount "$work/external-backup"
  sudo mount -t vfat -o "loop,uid=$(id -u),gid=$(id -g),umask=000" "$work/synthetic-external.img" "$work/external-backup"
  external_after=$(sha256sum "$work/external-backup/data.tar" | awk '{print $1}')
  [ "$external_before" = "$external_after" ] || { echo 'External archive changed on remount'; return 1; }
  # Whole regular-file content and selected metadata checked before any target
  # image is created or formatted. This is a static source snapshot, not live.
  sudo python3 tools/check_offline_tar_snapshot.py "$work/copy-source" "$work/external-backup/data.tar" | tee "$work/external-verify.txt"
  echo "$external_before" > "$work/external-sha.txt"
  # Deliberately corrupt a separate synthetic copy on the CI host. Require
  # digest gate to reject it while target image does not yet exist.
  cp --sparse=always "$work/external-backup/data.tar" "$work/corrupt-synthetic-backup.tar"
  python3 - "$work/corrupt-synthetic-backup.tar" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(4096)
    old = f.read(1)
    if len(old) != 1: raise SystemExit('Fixture too short')
    f.seek(4096)
    f.write(bytes([old[0] ^ 0x01]))
PY
  if check_external_digest "$work/corrupt-synthetic-backup.tar" "$external_before"; then
    echo 'Corrupted synthetic archive incorrectly passed digest gate'; return 1
  fi
  check_external_digest "$work/external-backup/data.tar" "$external_before" || { echo 'Verified synthetic archive failed digest gate'; return 1; }
  test ! -e "$work/synthetic-p5.img" && test ! -L "$work/synthetic-p5.img"
  echo 'Synthetic corrupted copy rejected by SHA-256 before any destination image existed.' > "$work/external-corruption-gate.txt"
  rm "$work/corrupt-synthetic-backup.tar"
  df -k "$work/external-backup" > "$work/external-df.txt"
}

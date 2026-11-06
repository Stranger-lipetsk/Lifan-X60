#!/usr/bin/env bash
# Destructive experiment solely on a fresh regular-file image in a disposable
# CI VM. No GU, ADB, physical media, existing images or stock scripts.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Disposable CI runner only'; exit 1; }
: "${RUNNER_TEMP:?}"
exec > >(tee "$RUNNER_TEMP/stock-mke2fs-mounted.log") 2>&1
w=$(mktemp -d "$RUNNER_TEMP/x60-mke2fs-test.XXXXXXXX"); chmod 0755 "$w"
mkdir -p "$w/root/system/bin" "$w/root/system/etc" "$w/mounted" reports
loop=''; container_name="x60-mke2fs-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}"
cleanup() {
  status=$?
  timeout -k 5 20 docker rm -f "$container_name" >/dev/null 2>&1 || true
  if mountpoint -q "$w/mounted"; then sudo umount "$w/mounted" || echo 'Cannot unmount synthetic image'; fi
  if [ -n "$loop" ]; then sudo losetup -d "$loop" || echo 'Cannot detach synthetic loop device'; fi
  if [ "$status" != 0 ]; then
    echo "Experiment failed: $status"
    for log in "$w/control.log" "$w/mount-check.log" "$w/mounted-run.log" "$w/post-fsck.log"; do
      if [ -f "$log" ]; then echo "## $(basename "$log")"; tail -50 "$log"; fi
    done
  fi
}
trap cleanup EXIT
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip qemu-user-static file

gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$w"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $w/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$w/lifan-file-manager-test.zip" system.img > "$w/stock-system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $w/stock-system.img" | sha256sum -c -
debugfs -R "dump /bin/mke2fs $w/root/system/bin/mke2fs" "$w/stock-system.img" >/dev/null 2>&1
echo "45b4cad925fe740a013f64192f6ba09784038b4b9dca4f5f1a3ed37f1a364c3e  $w/root/system/bin/mke2fs" | sha256sum -c -
debugfs -R "dump /bin/linker $w/root/system/bin/linker" "$w/stock-system.img" >/dev/null 2>&1
debugfs -R "dump /bin/bin/busybox $w/root/busybox" "$w/stock-system.img" >/dev/null 2>&1
echo "b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613  $w/root/busybox" | sha256sum -c -
echo 'Extract stock libraries, without running them on the host'
timeout -k 5 180 debugfs -R "rdump /lib $w/root/system" "$w/stock-system.img" > "$w/libs-dump.log" 2>&1
test -s "$w/root/system/lib/libc.so" && test -s "$w/root/system/bin/linker"
# Configuration may be absent; the exact binary is tested either way.
debugfs -R "dump /etc/mke2fs.conf $w/root/system/etc/mke2fs.conf" "$w/stock-system.img" >/dev/null 2>&1 || true
cp /usr/bin/qemu-arm-static "$w/root/qemu-arm-static"
chmod 0755 "$w/root/"{busybox,qemu-arm-static} "$w/root/system/bin/"{linker,mke2fs}
cat > "$w/root/Dockerfile" <<'DOCKER'
FROM scratch
COPY system /system
COPY qemu-arm-static /qemu-arm-static
COPY busybox /busybox
DOCKER
echo 'Build isolated formatter container'
timeout -k 5 240 docker build -q -t x60-disposable-mke2fs "$w/root"
truncate -s 64M "$w/target.img"
[ -f "$w/target.img" ] && [ ! -L "$w/target.img" ]
echo 'Attach dedicated synthetic file as loop device'
loop=$(timeout -k 5 30 sudo losetup --find --show "$w/target.img")
[[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || { echo 'Unexpected loop device'; exit 1; }
backing=$(sudo losetup -n -O BACK-FILE "$loop")
[ "$(realpath -e "$backing")" = "$(realpath -e "$w/target.img")" ] || { echo 'Loop is not the new synthetic image'; exit 1; }
run_in_lab() {
  timeout -k 5 30 docker run --rm --name "$container_name" --network none --read-only --cap-drop ALL --cap-add DAC_OVERRIDE -e QEMU_STRACE=1 \
    --security-opt no-new-privileges --memory 256m --pids-limit 32 \
    --device "$loop:$loop:rwm" \
    --mount "type=bind,source=$w/mounted,target=/fixture/mounted" \
    x60-disposable-mke2fs /qemu-arm-static "$@"
}
# Positive control: the stock formatter must work on the blank and unmounted
# synthetic loop device. The device is never used for anything except this lab.
echo 'Run unmounted positive control'
control_rc=0
run_in_lab /system/bin/mke2fs -t ext4 "$loop" > "$w/control.log" 2>&1 || control_rc=$?
[ "$control_rc" = 0 ] || { echo "Stock formatter control failed: $control_rc"; exit 1; }
sudo e2fsck -fn "$w/target.img" > "$w/control-fsck.log" 2>&1
sudo mount -t ext4 "$loop" "$w/mounted"
printf 'SYNTHETIC_ONLY_MARKER\n' | sudo tee "$w/mounted/synthetic-marker" >/dev/null
sudo sync
# The formatter must see the *same* block device as mounted in its container.
run_in_lab /busybox cat /proc/mounts > "$w/mount-check.log"
grep -F "$loop /fixture/mounted " "$w/mount-check.log"
before=$(sha256sum "$w/target.img" | awk '{print $1}')
echo 'Run mounted synthetic target control'
mounted_rc=0
# No -F and no interactive input, matching the stock script's invocation.
run_in_lab /system/bin/mke2fs -t ext4 "$loop" > "$w/mounted-run.log" 2>&1 || mounted_rc=$?
[ "$mounted_rc" -ne 124 ] && [ "$mounted_rc" -ne 137 ] || { echo 'Formatter timed out; no conclusion'; exit 1; }
sudo sync
after=$(sha256sum "$w/target.img" | awk '{print $1}')
sudo umount "$w/mounted"
post_fsck_rc=0
sudo e2fsck -fn "$w/target.img" > "$w/post-fsck.log" 2>&1 || post_fsck_rc=$?
remount=failed; marker=unknown
if sudo mount -t ext4 -o ro "$loop" "$w/mounted"; then
  remount=success
  if sudo grep -Fxq SYNTHETIC_ONLY_MARKER "$w/mounted/synthetic-marker"; then marker=present; else marker=absent; fi
  sudo umount "$w/mounted"
fi
{
  echo '# Stock-derived ARM mke2fs against an isolated synthetic mounted loop device'
  echo 'Offline CI-only Linux/QEMU user-mode restricted container; no actual GU, Android kernel, physical partition, user files, or hibernation script.'
  echo 'Stock-derived mke2fs SHA-256: 45b4cad925fe740a013f64192f6ba09784038b4b9dca4f5f1a3ed37f1a364c3e.'
  echo 'Positive control: exact binary formatted a blank unmounted 64 MiB file-backed loop, then read-only e2fsck succeeded.'
  echo 'The same image was then mounted read-write in the CI host and exposed as a mounted filesystem and the same loop device inside the restricted container.'
  echo "Invocation without -F and with no interactive input: mke2fs -t ext4 synthetic-loop; exit $mounted_rc."
  echo '## Formatter output'; cat "$w/mounted-run.log"
  echo "Synthetic image SHA-256 before: $before"
  echo "Synthetic image SHA-256 after:  $after"
  echo "Post-unmount read-only e2fsck exit: $post_fsck_rc; read-only remount: $remount; synthetic marker: $marker."
  echo 'This model tests the extracted formatter with the host kernel and synthetic loop device, not the real GU block device or repeated Hibernate sequence.'
} > reports/stock-mke2fs-mounted-lab.txt

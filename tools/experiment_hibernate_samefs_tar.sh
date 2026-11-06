#!/usr/bin/env bash
# CI only: two mounts of a NEW file-backed ext4 filesystem. No GU/device/data.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Disposable CI runner only'; exit 1; }
: "${RUNNER_TEMP:?}"
exec > >(tee "$RUNNER_TEMP/hibernate-samefs-tar.log") 2>&1
w=$(mktemp -d "$RUNNER_TEMP/x60-samefs.XXXXXXXX"); chmod 0755 "$w"
mkdir -p "$w"/{live,dest,image} reports
loop=''; container_name="x60-samefs-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}"
cleanup() {
  status=$?
  timeout -k 5 20 docker rm -f "$container_name" >/dev/null 2>&1 || true
  for m in "$w/dest" "$w/live"; do
    if mountpoint -q "$m"; then sudo umount "$m" || echo "Cannot unmount $m"; fi
  done
  [ -z "$loop" ] || sudo losetup -d "$loop" || true
  if [ "$status" != 0 ]; then
    echo "Synthetic test failed: $status"
    for log in "$w/create.log" "$w/extract.log"; do
      if [ -f "$log" ]; then echo "## $(basename "$log")"; tail -30 "$log"; fi
    done
  fi
}
trap cleanup EXIT
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip qemu-user-static

gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$w"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $w/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$w/lifan-file-manager-test.zip" system.img > "$w/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $w/system.img" | sha256sum -c -
debugfs -R "dump /bin/bin/busybox $w/image/busybox" "$w/system.img" >/dev/null 2>&1
echo "b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613  $w/image/busybox" | sha256sum -c -
cp /usr/bin/qemu-arm-static "$w/image/qemu-arm-static"; chmod 0755 "$w/image/"{busybox,qemu-arm-static}
printf 'FROM scratch\nCOPY busybox /busybox\nCOPY qemu-arm-static /qemu-arm-static\n' > "$w/image/Dockerfile"
timeout -k 5 240 docker build -q -t x60-disposable-samefs "$w/image"
truncate -s 64M "$w/synthetic.img"
test -f "$w/synthetic.img" && [ ! -L "$w/synthetic.img" ]
sudo mkfs.ext4 -q -F "$w/synthetic.img"
loop=$(sudo losetup --find --show "$w/synthetic.img")
[[ "$loop" =~ ^/dev/loop[0-9]+$ ]]
backing=$(sudo losetup -n -O BACK-FILE "$loop")
[ "$(realpath -e "$backing")" = "$(realpath -e "$w/synthetic.img")" ]
sudo mount -t ext4 "$loop" "$w/live"
sudo mount -t ext4 "$loop" "$w/dest"
[ "$(findmnt -n -o SOURCE --target "$w/live")" = "$loop" ]
[ "$(findmnt -n -o SOURCE --target "$w/dest")" = "$loop" ]
printf 'SYNTHETIC_MARKER\n' | sudo tee "$w/live/marker.txt" >/dev/null
printf 'OLD_SYNTHETIC_ARCHIVE\n' | sudo tee "$w/live/data.tar" >/dev/null
before=$(sudo sha256sum "$w/live/data.tar" | awk '{print $1}')
[ "$(sudo stat -c '%d:%i' "$w/live/data.tar")" = "$(sudo stat -c '%d:%i' "$w/dest/data.tar")" ]
run_tar() {
  timeout -k 5 60 docker run --rm --name "$container_name" --network none --read-only --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges --memory 256m --pids-limit 32 \
    --mount "type=bind,source=$w/live,target=/fixture/live,readonly" \
    --mount "type=bind,source=$w/dest,target=/fixture/dest" \
    --workdir "$1" x60-disposable-samefs /qemu-arm-static /busybox tar "${@:2}"
}
create_rc=0
run_tar /fixture/live -cf /fixture/dest/data.tar ./. > "$w/create.log" 2>&1 || create_rc=$?
[ "$create_rc" -ne 124 ] && [ "$create_rc" -ne 137 ] || { echo 'Timed out, no conclusion'; exit 1; }
after=$(sudo sha256sum "$w/live/data.tar" | awk '{print $1}')
archive_size=$(sudo stat -c '%s' "$w/live/data.tar")
# Record whether the resulting tar is parseable and whether it contains itself.
sudo python3 - "$w/live/data.tar" <<'PY' > "$w/archive-info.txt"
import sys, tarfile
try:
    with tarfile.open(sys.argv[1]) as archive:
        members = archive.getmembers()
        names = [m.name.removeprefix('./').removeprefix('./') for m in members]
        print('Archive parseable: yes')
        print('Archive includes output data.tar:', 'data.tar' in names)
        print('Archive includes marker.txt:', 'marker.txt' in names)
        print('Archive member count:', len(names))
except (tarfile.TarError, OSError) as exc:
    print('Archive parseable: no:', type(exc).__name__)
PY
extract_rc=not_attempted
if [ "$create_rc" = 0 ] && grep -Fxq 'Archive parseable: yes' "$w/archive-info.txt"; then
  extract_rc=0
  run_tar /fixture/dest -xvf /fixture/dest/data.tar > "$w/extract.log" 2>&1 || extract_rc=$?
  [ "$extract_rc" -ne 124 ] && [ "$extract_rc" -ne 137 ] || { echo 'Extraction timed out, no conclusion'; exit 1; }
fi
marker=absent_or_changed
if sudo grep -Fxq SYNTHETIC_MARKER "$w/live/marker.txt"; then marker=present; fi
{
  echo '# Synthetic same-filesystem tar scenario with stock-derived BusyBox'
  echo 'CI-only 64 MiB file-backed ext4 with two mounts of the same loop device, restricted offline ARM/QEMU container; no physical GU or actual Hibernate.'
  echo 'The output data.tar already existed on that same synthetic filesystem. Same device and inode were verified from both mountpoints.'
  echo "tar -cf DEST/data.tar ./. exit: $create_rc; resulting archive size bytes: $archive_size."
  echo "Previous synthetic data.tar SHA-256 before: $before"
  echo "After archive creation SHA-256: $after"
  echo 'Create diagnostics:'; cat "$w/create.log"
  cat "$w/archive-info.txt"
  echo "Same-filesystem extraction exit (when archive creation succeeded and was parseable): $extract_rc; marker: $marker."
  if [ -e "$w/extract.log" ]; then echo 'Extract diagnostics:'; tail -15 "$w/extract.log"; fi
  echo 'This is a hypothetical repeated-copy setup, not evidence that the GU reaches this state or that its mount or format behaves identically.'
} > reports/stock-hibernate-samefs-tar-lab.txt

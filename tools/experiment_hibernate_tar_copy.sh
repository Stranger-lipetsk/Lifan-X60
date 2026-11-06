#!/usr/bin/env bash
# CI-only host-side synthetic fixture. Never runs the hibernate script, touches
# physical partitions, or connects to Android/ADB; no real data/device involved.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Disposable CI runner only'; exit 1; }
: "${RUNNER_TEMP:?}"
exec > >(tee "$RUNNER_TEMP/hibernate-tar-model.log") 2>&1
w=$(mktemp -d "$RUNNER_TEMP/hibernate-tar-model.XXXXXXXX")
mkdir -p "$w"/{source,dest,image} reports
cleanup() {
  status=$?
  if [ "$status" != 0 ]; then
    echo "Synthetic lab failed: $status"
    for log in "$w/create.log" "$w/extract.log"; do
      if [ -f "$log" ]; then echo "## $(basename "$log")"; cat "$log"; fi
    done
  fi
  for target in "$w/dest-tight" "$w/dest-full" "$w/dest" "$w/source"; do
    if mountpoint -q "$target"; then sudo umount "$target" || echo "Disposable mount unmount failed: $target"; fi
  done
}
trap cleanup EXIT
chmod 0755 "$w"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs unzip qemu-user-static
# The only executable under test is the BusyBox in the inspected system image.
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$w"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $w/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$w/lifan-file-manager-test.zip" system.img > "$w/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $w/system.img" | sha256sum -c -
debugfs -R "stat /bin/bin/tar" "$w/system.img" > "$w/tar-stat.txt" 2>&1
grep -F 'Fast link dest: "busybox"' "$w/tar-stat.txt"
debugfs -R "dump /bin/bin/busybox $w/image/busybox" "$w/system.img" >/dev/null 2>&1
echo "b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613  $w/image/busybox" | sha256sum -c -
cp /usr/bin/qemu-arm-static "$w/image/qemu-arm-static"
chmod 0755 "$w/image/"{busybox,qemu-arm-static}
cat > "$w/image/Dockerfile" <<'DOCKER'
FROM scratch
COPY busybox /busybox
COPY qemu-arm-static /qemu-arm-static
DOCKER
# No internet and only the synthetic temp directory is visible to the ARM
# binary. No host devices, Android partitions, or Docker socket are mounted.
docker build -q -t x60-disposable-hibernate-tar "$w/image"
# These mounts exist only in this short-lived CI VM. The ext4 target is a NEW
# regular file created in the private temp directory, never a block device.
sudo mount -t tmpfs -o size=128m,mode=0755 tmpfs "$w/source"
truncate -s 128M "$w/synthetic-dest.img"
[ -f "$w/synthetic-dest.img" ] && [ ! -L "$w/synthetic-dest.img" ]
sudo mkfs.ext4 -q -F "$w/synthetic-dest.img"
sudo mount -t ext4 -o loop "$w/synthetic-dest.img" "$w/dest"
[ "$(findmnt -n -o FSTYPE --target "$w/source")" = tmpfs ]
[ "$(findmnt -n -o FSTYPE --target "$w/dest")" = ext4 ]
sudo chown "$(id -u):$(id -g)" "$w/source" "$w/dest"
mkdir -p "$w/source/data/com.navitel/files" "$w/source/data/com.navitel/shared_prefs" \
  "$w/source/data/ru.lifanx60.fixture/files" "$w/source/system" "$w/source/app" "$w/source/race"
printf 'SYNTHETIC_NAVITEL_MARKER\n' > "$w/source/data/com.navitel/files/lab-marker.txt"
printf '<probe synthetic="true"/>\n' > "$w/source/data/com.navitel/shared_prefs/probe.xml"
printf 'INDEPENDENT_SYNTHETIC_FIXTURE\n' > "$w/source/data/ru.lifanx60.fixture/files/marker.txt"
printf '<packages synthetic="true"/>\n' > "$w/source/system/packages.xml"
printf 'NOT_AN_APK_SYNTHETIC_BYTES\n' > "$w/source/app/com.navitel-1.apk"
printf 'before-archive\n' > "$w/source/race/late-write.txt"
ln -s lab-marker.txt "$w/source/data/com.navitel/files/link-to-marker"
ln "$w/source/data/com.navitel/files/lab-marker.txt" "$w/source/data/com.navitel/files/hardlink-to-marker"
python3 - "$w/source/data/com.navitel/files/lab-marker.txt" <<'PY'
import os,sys
os.setxattr(sys.argv[1], 'user.x60_test', b'synthetic user attribute')
PY
# Synthetic Android-like numeric owners only within the private CI directory.
sudo chown -R 10013:10013 "$w/source/data/com.navitel"
sudo chown -R 10055:10055 "$w/source/data/ru.lifanx60.fixture"
sudo chown 1000:1000 "$w/source/system/packages.xml"
sudo chown 1000:1000 "$w/source/app/com.navitel-1.apk"
sudo chmod 0700 "$w/source/data/com.navitel" "$w/source/data/ru.lifanx60.fixture"
sudo chmod 0600 "$w/source/data/com.navitel/files/lab-marker.txt" "$w/source/data/com.navitel/shared_prefs/probe.xml" "$w/source/data/ru.lifanx60.fixture/files/marker.txt"
sandbox_dest="$w/dest"
run_busybox() {
  docker run --rm --network none --read-only --cap-drop ALL --cap-add CHOWN \
    --cap-add DAC_OVERRIDE --cap-add FOWNER --security-opt no-new-privileges \
    --memory 256m --pids-limit 32 \
    --mount "type=bind,source=$w/source,target=/fixture/source,readonly" \
    --mount "type=bind,source=$sandbox_dest,target=/fixture/dest" \
    --workdir "$1" x60-disposable-hibernate-tar /qemu-arm-static /busybox "${@:2}"
}
run_tar() { local wd=$1; shift; run_busybox "$wd" tar "$@"; }
# These options and source spelling match the copy commands in the script;
# destination is a host directory, not the real ext4 partition or Hibernate.
run_tar /fixture/source -cf /fixture/dest/data.tar ./. > "$w/create.log" 2>&1
test -s "$w/dest/data.tar"
# Deterministic simulation of a write after the snapshot, not evidence that an
# actual GU process writes at this point or retains descriptors after resume.
printf 'after-archive\n' > "$w/source/race/late-write.txt"
run_tar /fixture/dest -xvf /fixture/dest/data.tar > "$w/extract.log" 2>&1
# Positive controls: destination permits both lchown in the same container
# and user xattrs. These controls do not change the copied test files.
ln -s nonexistent "$w/dest/chown-control"
run_busybox /fixture/dest chown -h 10013:10013 /fixture/dest/chown-control
python3 - "$w/dest" <<'PY'
from pathlib import Path
import os, sys
p = Path(sys.argv[1])
st = (p / 'chown-control').lstat()
assert (st.st_uid, st.st_gid) == (10013, 10013), (st.st_uid, st.st_gid)
probe = p / 'xattr-control'
probe.write_bytes(b'synthetic')
os.setxattr(probe, 'user.x60_test', b'control')
assert os.getxattr(probe, 'user.x60_test') == b'control'
PY
printf 'before-archive\n' > "$w/race-expected.txt"
cmp "$w/race-expected.txt" "$w/dest/race/late-write.txt"
grep -Fx after-archive "$w/source/race/late-write.txt"
# Independent, intentionally undersized ext4 image: demonstrate failure paths
# without using a real partition or exhausting the runner's filesystem.
mkdir -p "$w/dest-full" "$w/source/space-test"
truncate -s 16M "$w/synthetic-full.img"
[ -f "$w/synthetic-full.img" ] && [ ! -L "$w/synthetic-full.img" ]
sudo mkfs.ext4 -q -F "$w/synthetic-full.img"
sudo mount -t ext4 -o loop "$w/synthetic-full.img" "$w/dest-full"
[ "$(findmnt -n -o FSTYPE --target "$w/dest-full")" = ext4 ]
sudo chown "$(id -u):$(id -g)" "$w/dest-full"
dd if=/dev/zero of="$w/source/space-test/synthetic-large.bin" bs=1M count=24 status=none
sandbox_dest="$w/dest-full"
create_rc=0
run_tar /fixture/source/space-test -cf /fixture/dest/data.tar ./. > "$w/full-create.log" 2>&1 || create_rc=$?
extract_rc=0
run_tar /fixture/dest -xvf /fixture/dest/data.tar > "$w/full-extract.log" 2>&1 || extract_rc=$?
[ "$create_rc" -ne 0 ] || { echo 'Expected low-space create failure not observed'; exit 1; }
[ "$extract_rc" -ne 0 ] || { echo 'Expected low-space extract failure not observed'; exit 1; }
if [ -f "$w/dest-full/synthetic-large.bin" ] && cmp -s "$w/source/space-test/synthetic-large.bin" "$w/dest-full/synthetic-large.bin"; then
  echo 'Unexpected full copy in undersized image'; exit 1
fi
# Enough capacity for the tar alone, but not for tar plus its extracted payload.
mkdir "$w/dest-tight"
truncate -s 40M "$w/synthetic-tight.img"
[ -f "$w/synthetic-tight.img" ] && [ ! -L "$w/synthetic-tight.img" ]
sudo mkfs.ext4 -q -F "$w/synthetic-tight.img"
sudo mount -t ext4 -o loop "$w/synthetic-tight.img" "$w/dest-tight"
[ "$(findmnt -n -o FSTYPE --target "$w/dest-tight")" = ext4 ]
sudo chown "$(id -u):$(id -g)" "$w/dest-tight"
sandbox_dest="$w/dest-tight"
run_tar /fixture/source/space-test -cf /fixture/dest/data.tar ./. > "$w/tight-create.log" 2>&1
test -s "$w/dest-tight/data.tar"
tight_extract_rc=0
run_tar /fixture/dest -xvf /fixture/dest/data.tar > "$w/tight-extract.log" 2>&1 || tight_extract_rc=$?
[ "$tight_extract_rc" -ne 0 ] || { echo 'Expected tar-plus-extraction failure not observed'; exit 1; }
if [ -f "$w/dest-tight/synthetic-large.bin" ] && cmp -s "$w/source/space-test/synthetic-large.bin" "$w/dest-tight/synthetic-large.bin"; then
  echo 'Unexpected complete copy in tight image'; exit 1
fi
{
  echo '# Synthetic stock-derived BusyBox tar copy; not a hibernation test'
  echo 'ARM BusyBox b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613, run under QEMU user mode in an offline restricted container.'
  echo 'Only synthetic files in CI temp. Source: host tmpfs; destination: ext4 on a newly created disposable regular-file loop image. This is not the GU, its partitions, its kernel, stock script or hibernation.'
  echo 'Exact command options: tar -cf DEST/data.tar ./. and tar -xvf DEST/data.tar.'
  echo '## Synthetic content and selected numeric metadata'
  sudo python3 tools/hibernate_tar_lab.py "$w/source" "$w/dest"
  echo 'Positive controls passed: same container can lchown a symlink; destination supports user xattrs.'
  sudo python3 - "$w/dest/data.tar" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    matches = [m for m in archive.getmembers() if m.name.endswith('/link-to-marker')]
    if len(matches) != 1 or not matches[0].issym():
        raise SystemExit('Unexpected archive symlink metadata')
    m = matches[0]
    print('Symlink archive header numeric UID/GID:', m.uid, m.gid, '; target:', m.linkname)
PY
  echo '## Deliberately undersized synthetic destination'
  echo "24 MiB synthetic file, separate 16 MiB ext4 image: create exit $create_rc; extract exit $extract_rc; no complete extracted copy."
  echo 'Create diagnostics:'; tail -5 "$w/full-create.log"
  echo 'Extract diagnostics:'; tail -5 "$w/full-extract.log"
  echo "Same 24 MiB file, separate 40 MiB ext4 image: tar creation succeeded; extraction exit $tight_extract_rc; no complete copy."
  echo 'Tight-image extract diagnostics:'; tail -5 "$w/tight-extract.log"
  echo 'The archive and extracted files occupy the destination at the same time. This models insufficient space, not the actual capacity or free space of the GU partition.'
  echo '## Deliberately scheduled late write'
  echo 'Source was modified after archive finished and before extraction. Extracted file contained the earlier snapshot; late source change did not appear.'
  echo 'This illustrates a possible consistency window only. Real script timing and concurrent writes, app descriptors, actual Hibernate, the GU ext4 implementation, ACLs and SELinux were not tested.'
} > reports/stock-hibernate-tar-synthetic-lab.txt

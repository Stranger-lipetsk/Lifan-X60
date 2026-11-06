#!/usr/bin/env bash
# CI-only host-side synthetic fixture. Never runs the hibernate script, mounts
# partitions, or connects to Android/ADB; no real data/device/media involved.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Disposable CI runner only'; exit 1; }
: "${RUNNER_TEMP:?}"
w=$(mktemp -d "$RUNNER_TEMP/hibernate-tar-model.XXXXXXXX")
mkdir -p "$w"/{source,dest,image} reports
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
run_tar() {
  docker run --rm --network none --read-only --cap-drop ALL --cap-add CHOWN \
    --cap-add DAC_OVERRIDE --cap-add FOWNER --security-opt no-new-privileges \
    --memory 256m --pids-limit 32 --mount "type=bind,source=$w,target=/fixture" \
    --workdir "$1" x60-disposable-hibernate-tar /qemu-arm-static /busybox tar "${@:2}"
}
# These options and source spelling match the copy commands in the script;
# destination is a host directory, not the real ext4 partition or Hibernate.
run_tar /fixture/source -cf /fixture/dest/data.tar ./. > "$w/create.log" 2>&1
test -s "$w/dest/data.tar"
# Deterministic simulation of a write after the snapshot, not evidence that an
# actual GU process writes at this point or retains descriptors after resume.
printf 'after-archive\n' > "$w/source/race/late-write.txt"
run_tar /fixture/dest -xvf /fixture/dest/data.tar > "$w/extract.log" 2>&1
printf 'before-archive\n' > "$w/race-expected.txt"
cmp "$w/race-expected.txt" "$w/dest/race/late-write.txt"
grep -Fx after-archive "$w/source/race/late-write.txt"
{
  echo '# Synthetic stock-derived BusyBox tar copy; not a hibernation test'
  echo 'ARM BusyBox b40cc88591ddbe851e0d37e41990e7e0a7e19b6ab195dac827e1f952efe51613, run under QEMU user mode in an offline restricted container.'
  echo 'Only synthetic files in CI temp. Host filesystem, not GU tmpfs/ext4; no device, stock script, mount, partition formatting or kernel hibernate.'
  echo 'Exact command options: tar -cf DEST/data.tar ./. and tar -xvf DEST/data.tar.'
  echo '## Synthetic content and selected numeric metadata'
  sudo python3 tools/hibernate_tar_lab.py "$w/source" "$w/dest"
  echo '## Deliberately scheduled late write'
  echo 'Source was modified after archive finished and before extraction. Extracted file contained the earlier snapshot; late source change did not appear.'
  echo 'This illustrates a possible consistency window only. Real script timing and concurrent writes, app descriptors, actual Hibernate, ext4, ACLs and SELinux were not tested.'
} > reports/stock-hibernate-tar-synthetic-lab.txt

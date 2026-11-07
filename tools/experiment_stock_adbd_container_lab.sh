#!/usr/bin/env bash
# Only exact stock-derived adbd and synthetic properties in a network-none
# throwaway CI container; no head unit, user data, writable mounts or LAN.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'CI only'; exit 1; }
: "${RUNNER_TEMP:?}" "${GITHUB_RUN_ID:?}"
exec > >(tee "$RUNNER_TEMP/stock-adbd-container-lab.log") 2>&1
work=$(mktemp -d /tmp/x60-adbd-ci-lab.XXXXXX)
name="x60-adbd-lab-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-0}"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sudo apt-get update -qq
sudo apt-get install -y -qq cpio qemu-user-static e2fsprogs unzip util-linux
gh release download file-manager-test-20261105 -p lifan-file-manager-test.zip -D "$work"
echo "4be81211994221e80e401ce712ce484b5320156902fff3707737b73e3945d17f  $work/lifan-file-manager-test.zip" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" boot.img > "$work/boot.img"
echo "060d291a523bbe0d40c86537f070ed0feb90e04e0db0efef2a3e4594e9223b4b  $work/boot.img" | sha256sum -c -
unzip -p "$work/lifan-file-manager-test.zip" system.img > "$work/system.img"
echo "a660f062716fd42d5a6185faec059f42675b3024304de7b81fac5d705cc88511  $work/system.img" | sha256sum -c -
mkdir -p "$work/root/sbin" "$work/root/system/bin"
python3 - "$work/boot.img" "$work/root" <<'PY'
import gzip, struct, subprocess, sys
b=open(sys.argv[1],'rb').read()
assert b[:8] == b'ANDROID!'
k,_,r,_,_,_,_,page=struct.unpack('<8I',b[8:40])
offset=page+((k+page-1)//page)*page
subprocess.run(['cpio','-id','--no-absolute-filenames','sbin/adbd'], input=gzip.decompress(b[offset:offset+r]), cwd=sys.argv[2], check=True)
PY
echo "3e6c06ffa3946e2c5ba51e7dd52a522e4c5c83ad2a006115531a9465af6b294a  $work/root/sbin/adbd" | sha256sum -c -
debugfs -R "dump /bin/linker $work/root/system/bin/linker" "$work/system.img" >/dev/null 2>&1
debugfs -R "dump /bin/toolbox $work/root/system/bin/toolbox" "$work/system.img" >/dev/null 2>&1
debugfs -R "rdump /lib $work/root/system" "$work/system.img" > "$work/lib-extract.log" 2>&1
for f in "$work/root/system/bin/linker" "$work/root/system/bin/toolbox" "$work/root/system/lib/libc.so"; do
  [ -s "$f" ] || { echo "Missing extracted component: $f"; tail -20 "$work/lib-extract.log"; exit 1; }
done
mkdir -p "$work/root/lab"
printf 'X60 isolated synthetic root-only fixture\n' > "$work/root/lab/root-only-synthetic.txt"
chmod 0400 "$work/root/lab/root-only-synthetic.txt"
cp /usr/bin/qemu-arm-static "$work/root/qemu-arm-static"
chmod 0755 "$work/root/qemu-arm-static" "$work/root/sbin/adbd" "$work/root/system/bin/"{linker,toolbox}
printf 'FROM scratch\nCOPY . /\n' > "$work/root/Dockerfile"
docker build -q -t "x60-adbd-synthetic-${GITHUB_RUN_ID}" "$work/root"
mkdir -p reports
{
  echo '# Stock-derived ARM adbd: isolated container and synthetic properties'
  echo 'Exact boot-derived adbd under QEMU user mode, host kernel; no head unit, real properties, device blocks or LAN.'
  echo 'Containers use network none, read-only filesystem, no-new-privileges, capped capabilities and no published ports.'
  echo 'Android properties below are fabricated only; real device values and policy may differ.'
  echo 'ro.secure=1 ro.debuggable=1 ro.kernel.qemu=0 service.adb.tcp.port=43127'
} > "$work/result.txt"
for case_spec in 0:0 1:0 1:1; do
  mode=${case_spec%:*}; auth=${case_spec#*:}; label="$mode-$auth"
  python3 tools/android44_synthetic_property_area.py "$mode" "$auth" "$work/props-$label"
  sudo chown 0:0 "$work/props-$label"; sudo chmod 0444 "$work/props-$label"
  # Validate the area by running stock Android toolbox linked to stock bionic.
  for prop in ro.secure ro.debuggable ro.adb.secure ro.kernel.qemu service.adb.tcp.port service.adb.root; do
    actual=$(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
      --mount "type=bind,source=$work/props-$label,target=/dev/__properties__,readonly" \
      "x60-adbd-synthetic-${GITHUB_RUN_ID}" /qemu-arm-static /system/bin/toolbox getprop "$prop" | tr -d '\r')
    case "$prop" in ro.secure|ro.debuggable) expected=1;; ro.kernel.qemu) expected=0;; ro.adb.secure) expected=$auth;; service.adb.tcp.port) expected=43127;; service.adb.root) expected=$mode;; esac
    [ "$actual" = "$expected" ] || { echo "Synthetic property mismatch $prop: $actual"; exit 1; }
  done
  echo "Validated synthetic properties via stock toolbox: service.adb.root=$mode ro.adb.secure=$auth"
  docker run -d --name "$name" --network none --read-only --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add SETPCAP \
    --security-opt no-new-privileges --memory 128m --pids-limit 32 \
    --mount "type=bind,source=$work/props-$label,target=/dev/__properties__,readonly" \
    "x60-adbd-synthetic-${GITHUB_RUN_ID}" /qemu-arm-static /sbin/adbd > "$work/container-id"
  network=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")
  [ "$network" = none ] || { echo 'Refusing non-isolated network'; exit 1; }
  pid=$(docker inspect -f '{{.State.Pid}}' "$name")
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { docker logs "$name"; exit 1; }
  echo "Synthetic service.adb.root=$mode ro.adb.secure=$auth" | tee -a "$work/result.txt"
  expected_response=CNXN; [ "$auth" != 1 ] || expected_response=AUTH
  if ! timeout -k 5 35 sudo nsenter -t "$pid" -n -- python3 tools/probe_synthetic_adbd_handshake.py "$expected_response" | tee -a "$work/result.txt"; then
    docker logs "$name" || true; docker inspect "$name" --format '{{.State.Status}} exit={{.State.ExitCode}}' || true; exit 1
  fi
  # Read the listener address within this isolated net namespace only.
  sudo nsenter -t "$pid" -n -- cat /proc/net/tcp /proc/net/tcp6 > "$work/listeners-$label.txt"
  python3 - "$work/listeners-$label.txt" <<'PYLIST' | tee -a "$work/result.txt"
import sys
for line in open(sys.argv[1]):
    cols = line.split()
    if len(cols) > 3 and cols[1].endswith(':A877') and cols[3] == '0A':
        addr = cols[1].split(':')[0]
        print('Listener bind address in isolated namespace:', 'all interfaces' if int(addr, 16) == 0 else 'non-wildcard')
PYLIST
  if [ "$auth" = 0 ]; then
    timeout -k 5 30 sudo nsenter -t "$pid" -n -- python3 tools/probe_synthetic_adbd_sync.py "$mode" | tee -a "$work/result.txt"
  fi
  grep -E '^(Name|Uid|Gid|CapEff):' "/proc/$pid/status" | tee -a "$work/result.txt"
  docker rm -f "$name" >/dev/null
 done
{
  echo 'Greeting and fixed synthetic sync read are not a backup or evidence about a real head unit.'
  echo 'UID above is the QEMU host process status, not a complete validation of guest privileges or real-device behavior.'
  echo 'Disabled-auth cases are intentional isolated negative security controls and must not be assumed safe or present on GU.'
} >> "$work/result.txt"
cp "$work/result.txt" reports/stock-adbd-container-lab.txt

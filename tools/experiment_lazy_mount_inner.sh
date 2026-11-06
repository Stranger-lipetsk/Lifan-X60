#!/usr/bin/env bash
# Called only by CI wrapper inside a new private mount namespace.
set -euo pipefail
[ "${X60_LAB_NAMESPACE:-}" = yes ] && [ "$(id -u)" = 0 ] || exit 1
: "${LAB_ROOT:?}" "${LAB_BASE:?}"
base=$(realpath -e "$LAB_BASE")
w=$(realpath -e "$LAB_ROOT")
case "$w" in "$base"/x60-lazy-mount.*) ;; *) echo 'Unsafe lab path'; exit 1;; esac
[ -f "$w/ONLY_SYNTHETIC_LAB" ] && [ ! -L "$w/ONLY_SYNTHETIC_LAB" ] || exit 1
# All paths and the single ext4 file below were just created in CI temp.
mkdir "$w/live" "$w/staging"
writer=''
cleanup() {
  local status=$?
  [ -z "$writer" ] || kill "$writer" 2>/dev/null || true
  for m in "$w/live" "$w/staging"; do
    if mountpoint -q "$m"; then umount -l "$m" || true; fi
  done
  exit "$status"
}
trap cleanup EXIT
truncate -s 32M "$w/virtual-destination.img"
[ -f "$w/virtual-destination.img" ] && [ ! -L "$w/virtual-destination.img" ] || exit 1
mkfs.ext4 -q -F "$w/virtual-destination.img"
mount -t tmpfs -o size=8m tmpfs "$w/live"
mount -t ext4 -o loop "$w/virtual-destination.img" "$w/staging"
[ "$(findmnt -n -o FSTYPE --target "$w/live")" = tmpfs ]
[ "$(findmnt -n -o FSTYPE --target "$w/staging")" = ext4 ]
printf 'INITIAL\n' > "$w/live/synthetic-marker"
mkfifo "$w/commands" "$w/replies"
python3 tools/lazy_mount_fixture_writer.py "$w/live/synthetic-marker" < "$w/commands" > "$w/replies" &
writer=$!
exec 3> "$w/commands"
exec 4< "$w/replies"
read -r -t 15 ready <&4
[[ "$ready" =~ ^READY\ [0-9]+:[0-9]+$ ]]
# Represent copy with host GNU tar. Prior tests independently exercised the
# stock BusyBox; no physical storage or actual hibernate is involved here.
(cd "$w/live" && tar -cf "$w/staging/data.tar" ./.)
tar -xf "$w/staging/data.tar" -C "$w/staging"
printf 'before-switch\n' >&3
read -r -t 15 ack <&4
[ "$ack" = 'WROTE before-switch' ]
grep -Fx WRITE_AFTER_SNAPSHOT_BEFORE_SWITCH "$w/live/synthetic-marker"
! grep -Fq WRITE_AFTER_SNAPSHOT_BEFORE_SWITCH "$w/staging/synthetic-marker"
# The open FD retains the detached tmpfs inode after this lazy unmount.
umount -l "$w/live"
umount "$w/staging"
mount -t ext4 -o loop "$w/virtual-destination.img" "$w/live"
[ "$(findmnt -n -o FSTYPE --target "$w/live")" = ext4 ]
newid=$(stat -c '%d:%i' "$w/live/synthetic-marker")
[ "${ready#READY }" != "$newid" ]
printf 'after-switch\n' >&3
read -r -t 15 ack <&4
[ "$ack" = 'WROTE after-switch' ]
# Old FD writes did not change the file visible through the newly mounted path.
printf 'INITIAL\n' > "$w/expected"
cmp "$w/expected" "$w/live/synthetic-marker"
printf 'NEW_PATH_WRITE\n' >> "$w/live/synthetic-marker"
grep -Fx NEW_PATH_WRITE "$w/live/synthetic-marker"
printf 'finish\n' >&3
read -r -t 15 ack <&4
[ "$ack" = 'OLD_FD_CONTAINS_BOTH=true' ]
exec 3>&- 4<&-
wait "$writer"; writer=''
{
  echo '# Synthetic lazy-unmount and open-file-descriptor model'
  echo 'CI-only private Linux mount namespace; no Android device, actual GU partition, kernel hibernation, or user data.'
  echo 'Source was a temporary tmpfs; destination an ext4 filesystem on a new temporary regular-file image. Host GNU tar copied a synthetic file before mount switch.'
  echo 'A helper opened the original file before the snapshot and held its file descriptor through a lazy unmount and remount at the same path.'
  echo "Before: $ready; new path device:inode: $newid (different)."
  echo 'The helper wrote once after the copy and once after the mount switch. Both writes were readable through its old FD, but absent from the new filesystem path.'
  echo 'A new write opened via the path after remount appeared on the new filesystem.'
  echo 'This establishes Linux behavior in this host model only: no evidence that a head-unit process retains such an FD, writes at those times, or causes observed app loss.'
} > "$w/result.txt"

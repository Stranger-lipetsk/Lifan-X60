#!/usr/bin/env bash
# CI VM only. Never targets physical media or Android; unshare mount namespace.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Disposable CI runner only'; exit 1; }
: "${RUNNER_TEMP:?}"
exec > >(tee "$RUNNER_TEMP/lazy-mount-model.log") 2>&1
w=$(mktemp -d "$RUNNER_TEMP/x60-lazy-mount.XXXXXXXX")
chmod 0755 "$w"
printf 'Synthetic-only CI fixture\n' > "$w/ONLY_SYNTHETIC_LAB"
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs util-linux
sudo env X60_LAB_NAMESPACE=yes LAB_BASE="$RUNNER_TEMP" LAB_ROOT="$w" \
  unshare --mount --propagation private bash tools/experiment_lazy_mount_inner.sh
mkdir -p reports
sudo cp "$w/result.txt" reports/stock-hibernate-lazy-mount-model.txt
sudo chown "$(id -u):$(id -g)" reports/stock-hibernate-lazy-mount-model.txt

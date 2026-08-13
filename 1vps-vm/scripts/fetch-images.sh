#!/usr/bin/env bash
# Prefetch OS cloud images into the host cache used by 1vps-vm.
# Default source: Hetzner S3 bucket 1vps-vm-images (public-read objects).
set -euo pipefail
CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
VM_IMAGE_BASE="${VM_IMAGE_BASE:-https://fsn1.your-objectstorage.com/1vps-vm-images}"
mkdir -p "$CACHE_DIR"

OS_LIST="${*:-debian-12 debian-13 ubuntu-22 ubuntu-24}"

for os in $OS_LIST; do
  dest="${CACHE_DIR}/${os}.qcow2"
  url="${VM_IMAGE_BASE}/${os}.qcow2"
  if [[ -f "$dest" && $(stat -c%s "$dest") -gt 1048576 ]] && qemu-img info "$dest" >/dev/null 2>&1; then
    echo "cached: $dest ($(du -h "$dest" | awk '{print $1}'))"
    continue
  fi
  echo "fetch $os <- $url"
  tmp="${dest}.partial"
  curl -4 -fL --retry 5 --retry-delay 2 -o "$tmp" "$url"
  qemu-img info "$tmp" >/dev/null
  mv -f "$tmp" "$dest"
  echo "ok: $dest ($(du -h "$dest" | awk '{print $1}'))"
done

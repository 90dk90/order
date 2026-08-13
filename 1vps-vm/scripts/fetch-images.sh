#!/usr/bin/env bash
# Prefetch OS images into host cache (fast multi-stream S3).
set -euo pipefail
CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
VM_IMAGE_BASE="${VM_IMAGE_BASE:-https://fsn1.your-objectstorage.com/1vps-vm-images}"
S3_REMOTE="${S3_REMOTE:-hetzner:1vps-vm-images}"
RCLONE_BIN="${RCLONE_BIN:-/opt/1vps/lumenvm-net/bin/rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/1vps/lumenvm-net/rclone/rclone.conf}"
S3_STREAMS="${S3_STREAMS:-16}"

mkdir -p "$CACHE_DIR"
OS_LIST="${*:-debian-12 debian-13 ubuntu-22 ubuntu-24}"

for os in $OS_LIST; do
  dest="${CACHE_DIR}/${os}.qcow2"
  if [[ -f "$dest" && $(stat -c%s "$dest") -gt 1048576 ]] && qemu-img info "$dest" >/dev/null 2>&1; then
    echo "cached: $dest ($(du -h "$dest" | awk '{print $1}'))"
    continue
  fi
  tmp="${dest}.partial"
  rm -f "$tmp"
  echo "fetch $os (streams=${S3_STREAMS})"
  if [[ -x "$RCLONE_BIN" && -f "$RCLONE_CONFIG" ]]; then
    "$RCLONE_BIN" --config "$RCLONE_CONFIG" copyto \
      "${S3_REMOTE%/}/${os}.qcow2" "$tmp" \
      --multi-thread-streams "$S3_STREAMS" \
      --multi-thread-cutoff 64M \
      --multi-thread-chunk-size 32M \
      --buffer-size 128M \
      --retries 5 --stats 5s --stats-one-line
  elif command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x "$S3_STREAMS" -s "$S3_STREAMS" -k 1M --file-allocation=none \
      --allow-overwrite=true --auto-file-renaming=false \
      -d "$(dirname "$tmp")" -o "$(basename "$tmp")" \
      "${VM_IMAGE_BASE%/}/${os}.qcow2"
  else
    curl -4 -fL --retry 5 --retry-delay 2 -o "$tmp" "${VM_IMAGE_BASE%/}/${os}.qcow2"
  fi
  qemu-img info "$tmp" >/dev/null
  mv -f "$tmp" "$dest"
  echo "ok: $dest ($(du -h "$dest" | awk '{print $1}'))"
done

#!/usr/bin/env bash
# Prefetch popular OS images from Hetzner S3 into the host cache (fast path).
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
VM_IMAGE_BASE="${VM_IMAGE_BASE:-https://fsn1.your-objectstorage.com/1vps-vm-images}"
S3_REMOTE="${S3_REMOTE:-hetzner:1vps-vm-images}"
RCLONE_BIN="${RCLONE_BIN:-/opt/1vps/lumenvm-net/bin/rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/1vps/lumenvm-net/rclone/rclone.conf}"
LOG="${LOG:-/var/log/1vps-prewarm.log}"
S3_STREAMS="${S3_STREAMS:-16}"
S3_CHUNK_SIZE="${S3_CHUNK_SIZE:-32M}"
S3_BUFFER="${S3_BUFFER:-128M}"

PUBLIC_DEFAULT=(
  debian-12 debian-13 ubuntu-22 ubuntu-24 alpine
  debian-12-desktop ubuntu-24-desktop
)
PRIVATE_DEFAULT=(
  windows-2022-desktop windows-10-desktop
)

mkdir -p "$CACHE_DIR"
exec >>"$LOG" 2>&1
echo "[$(date -Is)] prewarm start streams=${S3_STREAMS}"

valid_qcow() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 1048576 ]] || return 1
  qemu-img info "$f" >/dev/null 2>&1
}

rclone_get() {
  local os="$1" tmp="$2"
  [[ -x "$RCLONE_BIN" && -f "$RCLONE_CONFIG" ]] || return 1
  "$RCLONE_BIN" --config "$RCLONE_CONFIG" copyto \
    "${S3_REMOTE%/}/${os}.qcow2" "$tmp" \
    --multi-thread-streams "$S3_STREAMS" \
    --multi-thread-cutoff 64M \
    --multi-thread-chunk-size "$S3_CHUNK_SIZE" \
    --s3-chunk-size 64M \
    --buffer-size "$S3_BUFFER" \
    --transfers 1 --checkers 8 \
    --retries 5 --low-level-retries 10 \
    --stats 10s --stats-one-line
}

aria_get() {
  local url="$1" tmp="$2"
  local aria=""
  if [[ -x /opt/1vps/lumenvm-net/bin/aria2c ]]; then
    aria=/opt/1vps/lumenvm-net/bin/aria2c
  elif command -v aria2c >/dev/null 2>&1; then
    aria=$(command -v aria2c)
  else
    return 1
  fi
  "$aria" -c -x "$S3_STREAMS" -s "$S3_STREAMS" -k 1M \
    --file-allocation=none --summary-interval=10 \
    --max-tries=5 --retry-wait=2 \
    --allow-overwrite=true --auto-file-renaming=false \
    -d "$(dirname "$tmp")" -o "$(basename "$tmp")" "$url"
}

fetch_one() {
  local os="$1" dest tmp url
  dest="${CACHE_DIR}/${os}.qcow2"
  if valid_qcow "$dest"; then
    echo "cached: $os ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi
  tmp="${dest}.partial"
  rm -f "$tmp"
  echo "fetch $os (fast multi-stream)"
  if ! rclone_get "$os" "$tmp"; then
    url="${VM_IMAGE_BASE%/}/${os}.qcow2"
    aria_get "$url" "$tmp" || curl -4 -fL --retry 5 --retry-delay 2 -o "$tmp" "$url"
  fi
  qemu-img info "$tmp" >/dev/null
  mv -f "$tmp" "$dest"
  echo "ok: $os ($(du -h "$dest" | awk '{print $1}'))"
}

if [[ "$#" -gt 0 ]]; then
  for os in "$@"; do fetch_one "$os" || true; done
else
  for os in "${PUBLIC_DEFAULT[@]}" "${PRIVATE_DEFAULT[@]}"; do
    fetch_one "$os" || true
  done
fi

curl -4 -fsSL --connect-timeout 15 \
  -o "${CACHE_DIR}/SHA256SUMS.tmp" \
  "${VM_IMAGE_BASE%/}/SHA256SUMS" 2>/dev/null \
  && mv -f "${CACHE_DIR}/SHA256SUMS.tmp" "${CACHE_DIR}/SHA256SUMS" \
  || rm -f "${CACHE_DIR}/SHA256SUMS.tmp"

echo "[$(date -Is)] prewarm done"
ls -lh "$CACHE_DIR"/*.qcow2 2>/dev/null | awk '{print $5,$9}'
